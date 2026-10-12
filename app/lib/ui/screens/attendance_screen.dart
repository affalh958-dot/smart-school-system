import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

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
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  int _deviceOrientation = 0;
  FaceDetector? _detector;
  final AttendanceRepository _attendance = AttendanceRepository();
  final StudentRepository _students = StudentRepository();

  bool _processing = false;
  bool _running = false;
  String? _initError;
  int _successCount = 0;
  int _pendingSync = 0;
  int _failedSync = 0;
  int _unrecognizedCount = 0;

  /// مؤشّر السرعة الحقيقي: زمن آخر تعرّفٍ (كشف+مطابقة) وعدد الإطارات/الثانية.
  int _fpsCount = 0;
  DateTime _fpsWindow = DateTime.now();
  double _fps = 0;
  int _lastLatencyMs = 0;

  /// آخر نتائج الكشف لعرض المربّعات فوق الوجه لحظياً (يتحدّث مع كل إطار).
  List<_FaceBox> _boxes = [];
  DateTime? _boxesAt;

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
      _cameras = cameras;
      // الكاميرا الخلفية افتراضياً للبوابة (أدق وأسرع للوجوه البعيدة).
      _cameraIndex = cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      if (_cameraIndex < 0) _cameraIndex = 0;
      _startOrientationTracking();
      await _openCamera(_cameras[_cameraIndex]);
      if (!mounted) return;
      final state = context.read<AppState>();
      _detector = FaceDetector(
        options: FaceDetectorOptions(
          // وضع الوجه الواحد أسرع كثيراً. مجال الدخول عادةً طالب واحد يتقدّم،
          // ومعالجة كل الوجوه كانت تُبطئ التسجيل وتسبب تجمّد الإطارات.
          enableClassification: true,
          enableTracking: true,
          performanceMode: FaceDetectorMode.fast,
          minFaceSize: 0.12,
        ),
      );
      await _loadSettings(state.schoolId);
      await _refreshSyncCounters(state.schoolId);
      await DeviceRepository().ensureRegistered(deviceId: state.ensureDeviceId(), schoolId: state.schoolId ?? '');
      await state.rebuildFaceIndex();
      if (!mounted) return;
      setState(() => _running = true);
    } catch (e) {
      setState(() => _initError = 'تعذّر تشغيل الكاميرا: $e');
    }
  }

  /// يتتبّع اتجاه الجهاز (شاشة عمودية/أفقية) لضبط دوران الصورة نحو ML Kit.
  void _startOrientationTracking() {
    void update(Size size) {
      final o = size.width > size.height ? 90 : 0;
      if (o != _deviceOrientation) _deviceOrientation = o;
    }

    final view = WidgetsBinding.instance.platformDispatcher.views.isNotEmpty
        ? WidgetsBinding.instance.platformDispatcher.views.first
        : null;
    if (view != null) update(view.physicalSize);
    WidgetsBinding.instance.platformDispatcher.onMetricsChanged = () {
      final v = WidgetsBinding.instance.platformDispatcher.views.first;
      update(v.physicalSize);
    };
  }

  /// فتح الكاميرا المحددة وبدء بثّ الصور.
  Future<void> _openCamera(CameraDescription description) async {
    final controller = CameraController(
      description,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await controller.initialize();
    await controller.startImageStream(_onFrame);
    if (!mounted) return;
    setState(() {
      _camera = controller;
    });
  }

  /// التبديل بين الكاميرا الأمامية والخلفية دون مغادرة الشاشة.
  Future<void> _switchCamera() async {
    if (_cameras.length < 2) {
      _snack('لا توجد كاميرا أخرى على هذا الجهاز');
      return;
    }
    try {
      final wasRunning = _running;
      setState(() => _running = false);
      await _camera?.stopImageStream().catchError((_) {});
      await _camera?.dispose();
      _cameraIndex = (_cameraIndex + 1) % _cameras.length;
      await _openCamera(_cameras[_cameraIndex]);
      if (mounted) setState(() => _running = wasRunning);
      final dir = _cameras[_cameraIndex].lensDirection == CameraLensDirection.front ? 'الأمامية' : 'الخلفية';
      _snack('تم التبديل إلى الكاميرا $dir');
    } catch (e) {
      _snack('تعذّر تبديل الكاميرا: $e');
    }
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_processing || !mounted) return;
    _processing = true;
    final sw = Stopwatch()..start();
    try {
      await _processFrame(image);
    } catch (_) {
      // نتجاهل أخطاء الإطار الواحد ولا نوقف الشاشة
    } finally {
      _processing = false;
      sw.stop();
      _lastLatencyMs = sw.elapsedMilliseconds;
      _fpsCount++;
      final now = DateTime.now();
      if (now.difference(_fpsWindow).inMilliseconds >= 1000) {
        final fps = _fpsCount * 1000 / now.difference(_fpsWindow).inMilliseconds;
        _fpsCount = 0;
        _fpsWindow = now;
        if (mounted) setState(() => _fps = fps);
      }
    }
  }

  Future<void> _processFrame(CameraImage image) async {
    final state = context.read<AppState>();

    // منع التسجيل التلقائي في يوم عطلة أو يوم راحة أسبوعية.
    if (!_isWorkingDay) return;

    final inputImage = _toInputImage(image);
    if (inputImage == null) return;

    final detector = _detector;
    if (detector == null) return;
    final faces = await detector.processImage(inputImage);

    final sensor = Size(image.width.toDouble(), image.height.toDouble());
    final boxes = <_FaceBox>[];
    var sawUnknown = false;

    if (faces.isEmpty) {
      if (mounted && (_boxes.isNotEmpty || _boxesAt == null)) {
        setState(() {
          _boxes = [];
          _boxesAt = DateTime.now();
        });
      }
      return;
    }

    // معالجة كل وجه في الإطار (لا نفترض وجود طالب واحد فقط)
    for (final face in faces) {
      final fraction = _boxToFraction(face, sensor);
      var matchedBox = false;
      final cropped = _cropFace(image, face);
      if (cropped != null) {
        // كشف الحيوية: استرشادي افتراضياً (لا يمنع التعرّف) حتى معايرته،
        // لأن عتبة خاطئة ترفض وجوهاً حقيقية فتعطّل التسجيل.
        final spoof = state.faceEngine.spoofScore(cropped);
        if (AppConfig.enforceLiveness &&
            spoof != null &&
            spoof > AppConfig.spoofThreshold) {
          await state.biometrics.logAttempt(result: 'spoof', deviceId: state.deviceId, schoolId: state.schoolId);
          if (fraction != null) {
            boxes.add(_FaceBox(fraction, _BoxState.spoof, 'محاولة انتحال', face.trackingId));
          }
          continue;
        }

        final embedding = state.faceEngine.embed(cropped);
        if (embedding != null) {
          final match = state.faceIndex.identify(embedding);
          if (match.accepted && match.studentId != null) {
            matchedBox = true;
            final studentId = match.studentId!;
            final now = DateTime.now();
            final last = _cooldown[studentId];
            final inCooldown =
                last != null && now.difference(last).inSeconds < AppConfig.cooldownSeconds;

            final student = await _studentById(studentId);
            final name = student?.fullName ?? '';
            if (fraction != null) {
              boxes.add(_FaceBox(fraction, _BoxState.matched, name, face.trackingId));
            }
            if (inCooldown) continue;
            _cooldown[studentId] = now;
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
          } else {
            // لم يُطابَق: نعرض "غير معروف" ونمنع التخمين (لا تسجيل تلقائي).
            if (match.result == 'ambiguous') {
              await state.biometrics.logAttempt(
                  result: match.result, deviceId: state.deviceId, confidence: match.score, schoolId: state.schoolId);
              if (fraction != null) {
                boxes.add(_FaceBox(fraction, _BoxState.ambiguous, 'التباس', face.trackingId));
              }
            } else {
              sawUnknown = true;
              if (fraction != null) {
                boxes.add(_FaceBox(fraction, _BoxState.unknown, 'غير معروف', face.trackingId));
              }
            }
          }
        }
      }
      if (!matchedBox && fraction != null && !boxes.any((b) => b.trackingId == face.trackingId)) {
        boxes.add(_FaceBox(fraction, _BoxState.unknown, 'غير معروف', face.trackingId));
        sawUnknown = true;
      }
    }

    if (sawUnknown) _unrecognizedCount++;
    if (mounted) {
      setState(() {
        _boxes = boxes;
        _boxesAt = DateTime.now();
      });
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

  /// زاوية دوران الإطار من مستشعر الكاميرا إلى الصورة التي يحلّلها ML Kit.
  int _rotDegrees() {
    if (_cameras.isEmpty) return 0;
    final cam = _cameras[_cameraIndex];
    final sensor = cam.sensorOrientation;
    final comp = _deviceOrientation;
    if (cam.lensDirection == CameraLensDirection.front) {
      return (sensor + comp) % 360;
    }
    return (sensor - comp + 360) % 360;
  }

  InputImage? _toInputImage(CameraImage image) {
    if (_cameras.isEmpty) return null;
    return CameraUtils.toInputImage(image, _cameras[_cameraIndex], _deviceOrientation);
  }

  /// قصّ منطقة الوجه مع مراعاة الدوران الصحيح (إحداثيات الصورة المدوّرة).
  img.Image? _cropFace(CameraImage image, Face face) =>
      CameraUtils.cropFaceRotated(image, face, _rotDegrees());

  /// يحوّل صندوق ML Kit إلى مستطيل نسبي (0..1) داخل الصورة المدوّرة.
  Rect? _boxToFraction(Face face, Size sensor) =>
      CameraUtils.boxToFraction(face, sensor, _rotDegrees());

  @override
  void dispose() {
    WidgetsBinding.instance.platformDispatcher.onMetricsChanged = null;
    _camera?.stopImageStream();
    _camera?.dispose();
    _detector?.close();
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
              tooltip: 'تبديل الكاميرا (أمامية/خلفية)',
              icon: const Icon(Icons.cameraswitch),
              onPressed: _switchCamera,
            ),
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
    final cam = _camera;
    if (cam == null || !_running) {
      return const Center(child: CircularProgressIndicator());
    }
    final isFront = _cameras.isNotEmpty &&
        _cameras[_cameraIndex].lensDirection == CameraLensDirection.front;
    return LayoutBuilder(
      builder: (context, constraints) {
        final view = constraints.biggest;
        // نغطّي المساحة كاملةً (cover) مع مرآة للكاميرا الأمامية، ونرسم
        // مربّعات الوجوه بإحداثيات نسبية مضروبة بأبعاد العرض نفسها.
        double scale = 1;
        var previewSize = view;
        final pvSize = cam.value.previewSize;
        if (pvSize != null) {
          previewSize = Size(pvSize.height, pvSize.width); // عمودي
          scale = math.max(view.width / previewSize.width, view.height / previewSize.height);
        }
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              OverflowBox(
                maxWidth: previewSize.width * scale,
                maxHeight: previewSize.height * scale,
                alignment: Alignment.center,
                child: Transform.scale(
                  scaleX: isFront ? -1 : 1,
                  child: CameraPreview(cam),
                ),
              ),
              // المربّعات فوق الوجوه
              CustomPaint(
                painter: _FaceBoxPainter(_boxes, view, mirrored: isFront),
              ),
              Positioned(
                top: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                  child: Row(children: [
                    const Icon(Icons.circle, size: 10, color: AppTheme.success),
                    const SizedBox(width: 6),
                    Text(
                      'يعمل تلقائياً • ${context.watch<AppState>().faceIndex.size} وجه مسجّل'
                      ' • ${_fps.toStringAsFixed(0)} إطار/ث • $_lastLatencyMsم.ث'
                      '${_unrecognizedCount > 0 ? ' • غير معروف: $_unrecognizedCount' : ''}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ]),
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                  child: Row(children: [
                    Icon(isFront ? Icons.camera_front : Icons.camera_rear, size: 14, color: Colors.white),
                    const SizedBox(width: 4),
                    Text(isFront ? 'أمامية' : 'خلفية', style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ]),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _statusBar(AppState state) {
    final syncColor = _pendingSync == 0 ? AppTheme.success : AppTheme.warning;
    return Row(
      children: [
        Expanded(child: _chip('مسجّل الجلسة', '$_successCount', AppTheme.success)),
        const SizedBox(width: 8),
        Expanded(child: _chip('سرعة الكشف', '$_lastLatencyMsم.ث', AppTheme.primary)),
        const SizedBox(width: 8),
        Expanded(child: _chip('إطارات/ث', _fps.toStringAsFixed(0), AppTheme.primary)),
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

enum _BoxState { matched, ambiguous, unknown, spoof }

/// مربّع وجه نسبي (0..1) مع حالته واسم صاحبه إن عُرف.
class _FaceBox {
  final Rect rect;
  final _BoxState state;
  final String label;
  final int? trackingId;
  _FaceBox(this.rect, this.state, this.label, this.trackingId);
}

/// يرسم مربّعات الوجوه فوق البثّ: أخضر=تم التعرّف، أصفر=التباس،
/// برتقالي=غير معروف، أحمر=محاولة انتحال. يعطي تغذية بصرية فورية.
class _FaceBoxPainter extends CustomPainter {
  _FaceBoxPainter(this.boxes, this.viewSize, {required this.mirrored});
  final List<_FaceBox> boxes;
  final Size viewSize;
  final bool mirrored;

  @override
  void paint(Canvas canvas, Size size) {
    if (boxes.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final fill = Paint()..style = PaintingStyle.fill;
    for (final b in boxes) {
      final color = switch (b.state) {
        _BoxState.matched => AppTheme.success,
        _BoxState.ambiguous => AppTheme.warning,
        _BoxState.spoof => AppTheme.danger,
        _BoxState.unknown => Colors.orange,
      };
      var r = Rect.fromLTWH(
        b.rect.left * size.width,
        b.rect.top * size.height,
        b.rect.width * size.width,
        b.rect.height * size.height,
      );
      if (mirrored) {
        r = Rect.fromLTWH(size.width - r.right, r.top, r.width, r.height);
      }
      paint.color = color;
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(10)), paint);

      if (b.label.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: b.label,
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
          ),
          textDirection: TextDirection.rtl,
        )..layout(maxWidth: r.width + 60);
        final top = (r.top - tp.height - 8).clamp(0.0, size.height);
        final bg = Rect.fromLTWH(r.left, top, tp.width + 12, tp.height + 4);
        fill.color = color.withValues(alpha: 0.85);
        canvas.drawRRect(RRect.fromRectAndRadius(bg, const Radius.circular(6)), fill);
        tp.paint(canvas, Offset(bg.left + 6, bg.top + 2));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FaceBoxPainter old) =>
      old.boxes != boxes || old.viewSize != viewSize || old.mirrored != mirrored;
}
