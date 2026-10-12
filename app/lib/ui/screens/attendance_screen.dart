import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/config.dart';
import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../data/attendance_repository.dart';
import '../../data/database.dart';
import '../../data/device_repository.dart';
import '../../data/models.dart';
import '../../data/repositories.dart';
import '../../data/school_settings_repository.dart';
import '../../data/sync_queue_repository.dart';
import 'camera_utils.dart';
import 'student_profile_screen.dart';

/// شاشة الحضور المستمرة — أهم ميزة في النظام.
///
/// - الكاميرا مفتوحة باستمرار، واكتشاف الوجه تلقائي دون أي زر.
/// - استخراج السمات والمطابقة محلياً على الجهاز.
/// - منع التكرار: قيد القاعدة + مهلة لكل طالب.
/// - معالجة متعددة الوجوه في الإطار الواحد.
/// - لا تُجمَّد الواجهة: المعالجة في مسار منفصل مع تجاهل الإطارات المتزاحمة.
class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  CameraController? _camera;
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true,
      performanceMode: FaceDetectorMode.fast,
      minFaceSize: 0.15,
    ),
  );
  final AttendanceRepository _attendance = AttendanceRepository();
  final StudentRepository _students = StudentRepository();

  bool _processing = false;
  bool _running = false;
  String? _initError;
  int _successCount = 0;
  int _pendingSync = 0;
  int _failedSync = 0;

  /// نوع الجلسة: حضور صباحي أو انصراف. يُمنع خلط الانصراف مع الحضور الصباحي.
  String _sessionType = 'morning';

  /// هل اليوم عطلة/راحة؟ يُمنع التسجيل التلقائي عندها.
  bool _isWorkingDay = true;
  String? _holidayTitle;

  final SchoolSettingsRepository _settings = SchoolSettingsRepository();

  /// وقت اعتبار التأخير من إعدادات المدرسة (افتراضي 07:30).
  int _lateHour = 7;
  int _lateMinute = 30;

  /// شروط الانصراف: أدنى وقت للانصراف قبل نهاية الدوام + حد الانصراف المبكر.
  int _earlyLeaveMinutes = 12 * 60; // 12:00 افتراضي

  /// مهلة لكل طالب لمنع الاحتساب المتكرر أثناء بقائه أمام الكاميرا.
  final Map<String, DateTime> _cooldown = {};
  final Map<String, Student> _studentCache = {};

  _LastResult? _last;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (kIsWeb) {
      setState(() => _initError = 'الكاميرا غير مدعومة في متصفح الويب — ثبّت التطبيق على أندرويد');
      return;
    }
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      setState(() => _initError =
          'التعرّف على الوجه بالكاميرا يعمل على تطبيق الأندرويد المثبّت عند المدخل.\n'
          'على الحاسوب يمكنك التسجيل اليدوي أو مراجعة السجلات والتقارير.');
      return;
    }
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _initError = 'لا توجد كاميرا متاحة على هذا الجهاز');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await controller.initialize();
      await controller.startImageStream(_onFrame);
      if (!mounted) return;
      final state = context.read<AppState>();
      await _loadSettings(state.schoolId);
      await _refreshSyncCounters(state.schoolId);
      await DeviceRepository().ensureRegistered(deviceId: state.ensureDeviceId(), schoolId: state.schoolId ?? '');
      await state.rebuildFaceIndex();
      if (!mounted) return;
      setState(() {
        _camera = controller;
        _running = true;
      });
    } catch (e) {
      setState(() => _initError = 'تعذّر تشغيل الكاميرا: $e');
    }
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_processing || !mounted) return;
    _processing = true;
    try {
      await _processFrame(image);
    } catch (_) {
      // نتجاهل أخطاء الإطار الواحد ولا نوقف الشاشة
    } finally {
      _processing = false;
    }
  }

  Future<void> _processFrame(CameraImage image) async {
    final state = context.read<AppState>();
    if (!state.faceIndex.isBuilt) return;

    // منع التسجيل التلقائي في يوم عطلة أو يوم راحة أسبوعية.
    if (!_isWorkingDay) return;

    final inputImage = _toInputImage(image);
    if (inputImage == null) return;

    final faces = await _detector.processImage(inputImage);
    if (faces.isEmpty) return;

    // معالجة كل وجه في الإطار (لا نفترض وجود طالب واحد فقط)
    for (final face in faces) {
      final cropped = _cropFace(image, face);
      if (cropped == null) continue;

      // كشف الحيوية (اختياري)
      final spoof = state.faceEngine.spoofScore(cropped);
      if (spoof != null && spoof > AppConfig.spoofThreshold) {
        await state.biometrics.logAttempt(result: 'spoof', deviceId: state.deviceId, schoolId: state.schoolId);
        continue;
      }

      final embedding = state.faceEngine.embed(cropped);
      if (embedding == null) continue;

      final match = state.faceIndex.identify(embedding);
      if (!match.accepted || match.studentId == null) {
        if (match.result != 'no_match') {
          await state.biometrics.logAttempt(
              result: match.result, deviceId: state.deviceId, confidence: match.score, schoolId: state.schoolId);
        }
        continue;
      }

      final studentId = match.studentId!;
      // منع التكرار عبر المهلة
      final now = DateTime.now();
      final last = _cooldown[studentId];
      if (last != null && now.difference(last).inSeconds < AppConfig.cooldownSeconds) {
        continue;
      }
      _cooldown[studentId] = now;

      final student = await _studentById(studentId);
      if (student == null) continue;

      final result = await _attendance.record(
        studentId: studentId,
        sessionType: _sessionType,
        status: _sessionType == 'morning' ? _statusFor(now) : _checkoutStatus(now),
        source: 'face',
        deviceId: state.deviceId,
        confidence: match.score,
        schoolId: state.schoolId,
      );

      if (result.outcome == RecordOutcome.recorded) {
        _successCount++;
        await _refreshSyncCounters(state.schoolId);
        if (mounted) {
          final profile = await _students.fullProfile(studentId);
          if (!mounted) return;
          setState(() {
            _last = _LastResult(
              studentId: studentId,
              name: student.fullName,
              number: student.studentNumber,
              section: _sectionLabel(profile),
              guardianPhone: profile?['guardian_phone'] as String?,
              residence: profile?['residence'] as String?,
              notes: profile?['notes'] as String?,
              status: _sessionType == 'morning' ? _statusFor(now) : _checkoutStatus(now),
              time: now,
              confidence: match.score,
            );
          });
        }
      } else if (result.outcome == RecordOutcome.duplicate) {
        if (mounted) {
          setState(() {
            _last = _LastResult(
              studentId: studentId,
              name: student.fullName,
              number: student.studentNumber,
              status: 'duplicate',
              time: now,
              confidence: match.score,
            );
          });
        }
      }
    }
  }

  /// يقرأ إعدادات الدوام (التأخير، الانصراف، العطل) من قاعدة البيانات.
  Future<void> _loadSettings(String? schoolId) async {
    if (schoolId == null) return;
    final db = await AppDatabase.instance.database;
    final rows = await db.query('attendance_settings',
        where: 'school_id = ? AND scope = ?', whereArgs: [schoolId, 'school'], limit: 1);
    if (rows.isNotEmpty) {
      final late = rows.first['late_after'] as String?;
      if (late != null) {
        final parts = late.split(':');
        if (parts.length >= 2) {
          _lateHour = int.tryParse(parts[0]) ?? _lateHour;
          _lateMinute = int.tryParse(parts[1]) ?? _lateMinute;
        }
      }
    }
    final rules = await _settings.checkoutRules(schoolId);
    final early = rules['early_leave_before'] as String?;
    if (early != null) {
      final p = early.split(':');
      if (p.length >= 2) {
        _earlyLeaveMinutes = (int.tryParse(p[0]) ?? 12) * 60 + (int.tryParse(p[1]) ?? 0);
      }
    }
    // فحص يوم الدوام/العطلة لليوم الحالي.
    final today = SchoolSettingsRepository.dateOnly(DateTime.now());
    try {
      final working = await _settings.isWorkingDay(schoolId, today);
      final holiday = await _settings.holidayFor(schoolId, today);
      if (mounted) {
        setState(() {
          _isWorkingDay = working;
          _holidayTitle = holiday?.title;
        });
      }
    } catch (_) {}
  }

  Future<void> _refreshSyncCounters(String? schoolId) async {
    final repo = SyncQueueRepository();
    final pending = await repo.pendingCount(schoolId: schoolId);
    final failed = (await repo.failed(schoolId: schoolId)).length;
    if (mounted) {
      setState(() {
        _pendingSync = pending;
        _failedSync = failed;
      });
    }
  }

  String _statusFor(DateTime now) {
    final minutes = now.hour * 60 + now.minute;
    return minutes > (_lateHour * 60 + _lateMinute) ? 'late' : 'present';
  }

  /// حالة سجل الانصراف: انصراف مبكر إن كان قبل الحد، وإلا حاضر/منصرف.
  String _checkoutStatus(DateTime now) {
    final minutes = now.hour * 60 + now.minute;
    return minutes < _earlyLeaveMinutes ? 'early_leave' : 'present';
  }

  Future<Student?> _studentById(String id) async {
    if (_studentCache.containsKey(id)) return _studentCache[id];
    final s = await _students.byId(id);
    if (s != null) _studentCache[id] = s;
    return s;
  }

  InputImage? _toInputImage(CameraImage image) {
    try {
      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      if (format == null) return null;
      final plane = image.planes.first;
      return InputImage.fromBytes(
        bytes: plane.bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: InputImageRotation.rotation90deg,
          format: format,
          bytesPerRow: plane.bytesPerRow,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// قصّ منطقة الوجه من الإطار وتحويلها إلى صورة RGB.
  img.Image? _cropFace(CameraImage image, Face face) {
    try {
      final full = CameraUtils.frameToRgb(image);
      if (full == null) return null;
      final box = face.boundingBox;
      return CameraUtils.cropBox(full, box.left, box.top, box.width, box.height);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _camera?.stopImageStream();
    _camera?.dispose();
    _detector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isCheckout = _sessionType == 'checkout';
    return Scaffold(
      appBar: AppBar(
        title: Text(isCheckout ? 'شاشة الانصراف' : 'شاشة الحضور'),
        actions: [
          if (context.read<AppState>().can(Perms.attendanceWrite))
            IconButton(
              tooltip: 'تسجيل يدوي',
              icon: const Icon(Icons.edit_note),
              onPressed: _manualEntry,
            ),
          if (context.read<AppState>().can(Perms.attendanceWrite))
            IconButton(
              tooltip: isCheckout ? 'التبديل إلى الحضور الصباحي' : 'التبديل إلى الانصراف',
              icon: Icon(isCheckout ? Icons.login : Icons.logout),
              onPressed: _toggleSession,
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: Text('مسجّل: $_successCount', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_isWorkingDay) _holidayBanner(),
          Expanded(
            flex: 3,
            child: _cameraView(),
          ),
          Expanded(
            flex: 2,
            child: Container(
              width: double.infinity,
              color: Colors.white,
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _statusBar(state),
                  const SizedBox(height: 12),
                  Expanded(child: _resultView()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _toggleSession() {
    setState(() {
      _sessionType = _sessionType == 'morning' ? 'checkout' : 'morning';
      _successCount = 0;
      _last = null;
      _cooldown.clear();
    });
    _snack(_sessionType == 'morning' ? 'وضع الحضور الصباحي' : 'وضع الانصراف');
  }

  Widget _holidayBanner() {
    return Container(
      width: double.infinity,
      color: AppTheme.warning.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.event_busy, color: AppTheme.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _holidayTitle != null ? 'عطلة: $_holidayTitle — التسجيل التلقائي متوقف' : 'اليوم ليس يوم دوام — التسجيل التلقائي متوقف',
              style: const TextStyle(color: AppTheme.warning, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cameraView() {
    if (_initError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off, size: 56, color: AppTheme.danger),
              const SizedBox(height: 12),
              Text(_initError!, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.danger)),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _start, child: const Text('إعادة المحاولة')),
            ],
          ),
        ),
      );
    }
    if (_camera == null || !_running) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(_camera!),
        Positioned(
          top: 12,
          right: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
            child: Row(children: [
              const Icon(Icons.circle, size: 10, color: AppTheme.success),
              const SizedBox(width: 6),
              Text('يعمل تلقائياً • ${context.watch<AppState>().faceIndex.size} وجه مسجّل',
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _statusBar(AppState state) {
    final syncColor = _pendingSync == 0 ? AppTheme.success : AppTheme.warning;
    return Row(
      children: [
        Expanded(child: _chip('مسجّل الجلسة', '$_successCount', AppTheme.success)),
        const SizedBox(width: 8),
        Expanded(child: _chip('غير متزامن', '$_pendingSync', syncColor)),
        const SizedBox(width: 8),
        Expanded(child: _chip('فشل مزامنة', '$_failedSync', _failedSync == 0 ? AppTheme.textMuted : AppTheme.danger)),
      ],
    );
  }

  Widget _chip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
      child: Column(children: [
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
      ]),
    );
  }

  Widget _resultView() {
    if (_last == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.face, size: 48, color: AppTheme.textMuted),
            SizedBox(height: 8),
            Text('بانتظار مرور الطالب أمام الكاميرا...', style: TextStyle(color: AppTheme.textMuted)),
          ],
        ),
      );
    }
    final r = _last!;
    final isDup = r.status == 'duplicate';
    final isEarly = r.status == 'early_leave';
    final color = isDup ? AppTheme.warning : (r.status == 'late' || isEarly ? AppTheme.warning : AppTheme.success);
    final label = isDup
        ? 'مسجَّل مسبقاً'
        : _sessionType == 'checkout'
            ? (isEarly ? 'انصراف مبكر' : 'تم تسجيل الانصراف')
            : (r.status == 'late' ? 'حضور متأخر' : 'تم تسجيل الحضور');
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color, width: 2),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(isDup ? Icons.info : Icons.check_circle, color: color, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 2),
                Text(r.name, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
                Text('الرقم: ${r.number}${r.section != null ? '  •  ${r.section}' : ''}',
                    style: const TextStyle(color: AppTheme.textMuted, fontSize: 13)),
                if (r.guardianPhone != null || r.residence != null)
                  Text(
                    'ولي الأمر: ${r.guardianPhone ?? '-'}  •  السكن: ${r.residence ?? '-'}',
                    style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
                  ),
                Text('الوقت: ${_fmt(r.time)}  •  الثقة: ${(r.confidence * 100).round()}%',
                    style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
              ],
            ),
          ),
          if (r.studentId != null)
            IconButton(
              tooltip: 'ملف الطالب',
              icon: const Icon(Icons.open_in_new, color: AppTheme.primary),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => StudentProfileScreen(studentId: r.studentId!)),
              ),
            ),
        ],
      ),
    );
  }

  String? _sectionLabel(Map<String, dynamic>? p) {
    if (p == null) return null;
    final parts = [p['grade_name'], p['section_name']].where((e) => e != null).toList();
    return parts.isEmpty ? null : parts.join(' / ');
  }

  /// وضع يدوي بديل: تسجيل حضور طالب بحثاً بالرقم المدرسي.
  Future<void> _manualEntry() async {
    final state = context.read<AppState>();
    if (state.schoolId == null) return;
    final ctrl = TextEditingController();
    final student = await showDialog<Student>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تسجيل حضور يدوي'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'الرقم المدرسي', prefixIcon: Icon(Icons.tag)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(
            onPressed: () async {
              final s = await _students.byNumber(state.schoolId!, ctrl.text.trim());
              if (ctx.mounted) Navigator.pop(ctx, s);
            },
            child: const Text('بحث'),
          ),
        ],
      ),
    );
    if (student == null) {
      _snack('لم يتم العثور على الطالب بهذا الرقم');
      return;
    }
    final now = DateTime.now();
    final result = await _attendance.record(
      studentId: student.id,
      sessionType: _sessionType,
      status: _sessionType == 'morning' ? _statusFor(now) : _checkoutStatus(now),
      source: 'manual',
      deviceId: state.deviceId,
      schoolId: state.schoolId,
    );
    if (!mounted) return;
    if (result.outcome == RecordOutcome.recorded) {
      _successCount++;
      await _refreshSyncCounters(state.schoolId);
      setState(() {
        _last = _LastResult(
          studentId: student.id,
          name: student.fullName,
          number: student.studentNumber,
          status: _sessionType == 'morning' ? _statusFor(now) : _checkoutStatus(now),
          time: now,
          confidence: 1.0,
        );
      });
    } else {
      _snack(result.message);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  String _fmt(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

class _LastResult {
  final String? studentId;
  final String name;
  final String number;
  final String? section;
  final String? guardianPhone;
  final String? residence;
  final String? notes;
  final String status;
  final DateTime time;
  final double confidence;
  _LastResult({
    this.studentId,
    required this.name,
    required this.number,
    this.section,
    this.guardianPhone,
    this.residence,
    this.notes,
    required this.status,
    required this.time,
    required this.confidence,
  });
}
