import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/academic_repository.dart';
import '../../data/biometric_repository.dart';
import '../../data/database.dart';
import '../../data/models.dart';
import '../../data/repositories.dart';
import 'camera_utils.dart';

/// شاشة تسجيل وجوه الطلاب (للمدير/مسؤول النظام المخوّل فقط — مقيّدة بصلاحية).
///
/// وضعان:
///  1) تسجيل فردي: اختر طالباً ثم سجّل وجهه.
///  2) **تسجيل متتابع سريع (الافتراضي):** الطالب التالي في القائمة تلقائياً؛
///     يكتشف النظام الوجه باستمرار، وبمجرد ثبات الوجه يسجّله وينتقل فوراً
///     للطالب التالي — دون أي ضغط زر. مناسب لتسجيل آلاف الطلاب بسرعة.
class FaceEnrollScreen extends StatefulWidget {
  const FaceEnrollScreen({super.key, this.initialSectionId, this.studentId});
  final String? initialSectionId;

  /// عند تمريره: تُفتح الشاشة على هذا الطالب مباشرةً (تسجيل/تحديث بصمته).
  final String? studentId;

  @override
  State<FaceEnrollScreen> createState() => _FaceEnrollScreenState();
}

class _FaceEnrollScreenState extends State<FaceEnrollScreen> {
  CameraController? _camera;
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true,
      performanceMode: FaceDetectorMode.fast,
      minFaceSize: 0.2,
    ),
  );
  final _acad = AcademicRepository();
  final _bio = BiometricRepository();

  String? _error;
  bool _cameraReady = false;
  bool _processing = false;

  List<Map<String, dynamic>> _sections = [];
  String? _sectionId;
  List<Student> _students = [];
  Set<String> _enrolled = {};
  int _index = 0;

  bool _sequential = true;
  bool _runningStream = false;
  bool _capturing = false;
  DateTime? _faceSeenSince;
  String _hint = 'وجّه وجهك نحو الكاميرا مباشرة';

  @override
  void initState() {
    super.initState();
    _sectionId = widget.initialSectionId;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initCamera();
      await _loadSections();
    });
  }

  String? get _schoolId => context.read<AppState>().schoolId;

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error = 'لا توجد كاميرا متاحة على هذا الجهاز');
        return;
      }
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _camera = controller;
        _cameraReady = true;
      });
    } catch (e) {
      setState(() => _error = 'تعذّر تشغيل الكاميرا: $e');
    }
  }

  Future<String?> _currentYearId() async {
    final schoolId = _schoolId;
    if (schoolId == null) return null;
    final rows = await (await AppDatabase.instance.database).query('academic_years',
        where: 'school_id = ? AND deleted_at IS NULL',
        whereArgs: [schoolId],
        orderBy: 'is_current DESC, start_date DESC',
        limit: 1);
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  Future<void> _loadSections() async {
    final schoolId = _schoolId;
    if (schoolId == null) return;
    final yearId = await _currentYearId();
    final sections = yearId == null ? <Map<String, dynamic>>[] : await _acad.sectionsWithNames(schoolId, yearId);
    if (!mounted) return;
    setState(() => _sections = sections);
    final target = _sectionId ?? (sections.isNotEmpty ? sections.first['id'] as String : null);
    if (target != null) await _selectSection(target);
  }

  Future<void> _selectSection(String sectionId) async {
    await _stopStream();
    setState(() {
      _sectionId = sectionId;
      _index = 0;
    });
    final students = await StudentRepository().bySection(sectionId);
    final enrolled = await _bio.enrolledStudentIds(schoolId: _schoolId, sectionId: sectionId);
    if (!mounted) return;
    setState(() {
      _students = students;
      _enrolled = enrolled;
      // عند تحديد طالبٍ ما (تسجيل/تحديث بصمته) نضعه أولاً.
      final target = widget.studentId;
      final idx = target == null ? -1 : students.indexWhere((s) => s.id == target);
      _index = idx >= 0 ? idx : _firstPendingIndex();
    });
  }

  int _firstPendingIndex() {
    for (var i = 0; i < _students.length; i++) {
      if (!_enrolled.contains(_students[i].id)) return i;
    }
    return 0;
  }

  Student? get _current => (_index >= 0 && _index < _students.length) ? _students[_index] : null;

  Future<void> _startStream() async {
    final cam = _camera;
    if (cam == null || _runningStream || _sequential == false) return;
    try {
      await cam.startImageStream(_onFrame);
      setState(() {
        _runningStream = true;
        _faceSeenSince = null;
      });
    } catch (e) {
      _snack('تعذّر تشغيل التسجيل المتتابع: $e', AppTheme.danger);
    }
  }

  Future<void> _stopStream() async {
    final cam = _camera;
    if (cam == null || !_runningStream) return;
    try {
      await cam.stopImageStream();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _runningStream = false;
        _faceSeenSince = null;
        _hint = 'اضغط «تشغيل التسجيل المتتابع» للبدء';
      });
    }
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_processing || !mounted || !_sequential || _capturing) return;
    final student = _current;
    if (student == null) {
      await _stopStream();
      _hint = 'اكتمل تسجيل جميع الطلاب في هذه الشعبة';
      return;
    }
    _processing = true;
    try {
      final crop = await _extractLargestFace(image);
      if (crop == null) {
        _faceSeenSince = null;
        _setHint('وجّه وجهك نحو الكاميرا مباشرة');
        return;
      }
      // نطلب ثباتاً ~0.8 ثانية لتفادي الالتقاط أثناء الحركة.
      final now = DateTime.now();
      _faceSeenSince ??= now;
      final stable = now.difference(_faceSeenSince!).inMilliseconds;
      if (stable < 800) {
        _setHint('ثبّت وجهك... ${(800 - stable) ~/ 100}');
        return;
      }
      _capturing = true;
      await _enrollCurrent(student, crop);
      _faceSeenSince = null;
    } catch (_) {
      // نتجاهل أخطاء الإطار الواحد
    } finally {
      _capturing = false;
      _processing = false;
    }
  }

  void _setHint(String h) {
    if (mounted && _hint != h) setState(() => _hint = h);
  }

  /// يستخرج أكبر وجه من الإطار ويعيد صورة RGB للوجه.
  Future<img.Image?> _extractLargestFace(CameraImage image) async {
    final rgb = CameraUtils.frameToRgb(image);
    if (rgb == null) return null;
    final input = _toInputImage(image);
    if (input == null) return null;
    final faces = await _detector.processImage(input);
    if (faces.isEmpty) return null;
    var best = faces.first;
    for (final f in faces) {
      if (f.boundingBox.width > best.boundingBox.width) best = f;
    }
    return CameraUtils.cropBox(rgb, best.boundingBox.left, best.boundingBox.top,
        best.boundingBox.width, best.boundingBox.height);
  }

  Future<void> _enrollCurrent(Student student, img.Image crop) async {
    final state = context.read<AppState>();
    final embedding = state.faceEngine.embed(crop);
    if (embedding == null) {
      _setHint('تعذّر استخراج سمات الوجه، أعد المحاولة');
      return;
    }
    await _bio.upsertTemplate(
      studentId: student.id,
      embedding: embedding,
      quality: 0.9,
      enrolledBy: state.user?['id'] as String?,
    );
    await state.rebuildFaceIndex();
    if (!mounted) return;
    setState(() {
      _enrolled = {..._enrolled, student.id};
      _index = _nextPendingIndex();
      _hint = 'تم تسجيل ${student.fullName} — الطالب التالي';
    });
    _snack('تم تسجيل وجه ${student.fullName}', AppTheme.success);
  }

  int _nextPendingIndex() {
    for (var i = _index + 1; i < _students.length; i++) {
      if (!_enrolled.contains(_students[i].id)) return i;
    }
    for (var i = 0; i < _index; i++) {
      if (!_enrolled.contains(_students[i].id)) return i;
    }
    return _students.length; // اكتمل
  }

  /// التقاط فردي احتياطي (زر).
  Future<void> _captureSingle() async {
    final student = _current;
    final cam = _camera;
    if (student == null || cam == null) return;
    setState(() => _capturing = true);
    try {
      final shot = await cam.takePicture();
      final bytes = await shot.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw StateError('تعذّر قراءة الصورة');
      final faces = await _detector.processImage(InputImage.fromFilePath(shot.path));
      if (faces.isEmpty) throw StateError('لم يُكشف وجه واضح. اقترب وحسّن الإضاءة.');
      final face = faces.first;
      final crop = CameraUtils.cropBox(decoded, face.boundingBox.left, face.boundingBox.top,
          face.boundingBox.width, face.boundingBox.height);
      if (crop == null) throw StateError('تعذّر قصّ منطقة الوجه');
      await _enrollCurrent(student, crop);
    } catch (e) {
      _snack('$e', AppTheme.danger);
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  /// تسجيل بصمة الطالب من صورة مرفوعة من المعرض (أو التقاط جديد)،
  /// مع كشف الوجه وقصّه واستخراج السمات — دون إنترنت.
  Future<void> _pickImageForCurrent() async {
    final student = _current;
    if (student == null) return;
    setState(() => _capturing = true);
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1600);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw StateError('تعذّر قراءة الصورة المرفوعة');
      final faces = await _detector.processImage(InputImage.fromFilePath(picked.path));
      if (faces.isEmpty) throw StateError('لم يُكشف وجه واضح في الصورة. اختر صورة أوضح للوجه.');
      var best = faces.first;
      for (final f in faces) {
        if (f.boundingBox.width > best.boundingBox.width) best = f;
      }
      final crop = CameraUtils.cropBox(decoded, best.boundingBox.left, best.boundingBox.top,
          best.boundingBox.width, best.boundingBox.height);
      if (crop == null) throw StateError('تعذّر قصّ منطقة الوجه');
      await _enrollCurrent(student, crop);
    } catch (e) {
      _snack('$e', AppTheme.danger);
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _revoke(Student student) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تعطيل بصمة الوجه'),
        content: Text('سيتم تعطيل التعرّف على وجه ${student.fullName} دون حذف ملفه المدرسي. متابعة؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تعطيل')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final state = context.read<AppState>();
    await _bio.revokeForStudent(student.id);
    await state.rebuildFaceIndex();
    if (!mounted) return;
    setState(() => _enrolled = {..._enrolled}..remove(student.id));
    _snack('تم تعطيل بصمة وجه ${student.fullName}', AppTheme.warning);
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

  void _snack(String m, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: color, duration: const Duration(seconds: 1)));
  }

  @override
  void dispose() {
    _camera?.stopImageStream().catchError((_) {});
    _camera?.dispose();
    _detector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _students.length;
    final done = _students.where((s) => _enrolled.contains(s.id)).length;
    return Scaffold(
      appBar: AppBar(title: const Text('تسجيل وجوه الطلاب')),
      body: Column(
        children: [
          Expanded(flex: 3, child: _cameraArea()),
          Expanded(flex: 3, child: _controls(total, done)),
        ],
      ),
    );
  }

  Widget _cameraArea() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.videocam_off, size: 56, color: AppTheme.danger),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.danger)),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _initCamera, child: const Text('إعادة المحاولة')),
          ]),
        ),
      );
    }
    if (!_cameraReady || _camera == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(_camera!),
        if (_current != null)
          Positioned(
            bottom: 12,
            left: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(14)),
              child: Column(children: [
                Text('الطالب الحالي: ${_current!.fullName}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                Text('الرقم: ${_current!.studentNumber}  •  $_hint',
                    style: const TextStyle(color: Colors.white70, fontSize: 12), textAlign: TextAlign.center),
              ]),
            ),
          ),
      ],
    );
  }

  Widget _controls(int total, int done) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(12),
      child: ListView(
        children: [
          if (_sections.isEmpty)
            const Text('لا توجد شعب. أنشئ الشعب من «الهيكل المدرسي» أولاً.',
                style: TextStyle(color: AppTheme.danger))
          else
            DropdownButtonFormField<String>(
              initialValue: _sectionId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'الشعبة', prefixIcon: Icon(Icons.meeting_room)),
              items: _sections
                  .map((s) => DropdownMenuItem(
                        value: s['id'] as String,
                        child: Text('${s['stage_name']} / ${s['grade_name']} / ${s['name']}',
                            overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v != null) _selectSection(v);
              },
            ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _pill('مُسجَّلون', '$done / $total', AppTheme.success)),
            const SizedBox(width: 8),
            Expanded(child: _pill('بانتظار التسجيل', '${total - done}', AppTheme.warning)),
          ]),
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _sequential,
            onChanged: (v) async {
              setState(() => _sequential = v);
              if (v) {
                await _startStream();
              } else {
                await _stopStream();
              }
            },
            title: const Text('التسجيل المتتابع السريع', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text('الطالب التالي تلقائياً — بدون أي ضغط زر (الأسرع لآلاف الطلاب)'),
          ),
          const SizedBox(height: 6),
          if (_sequential)
            Row(children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _runningStream ? _stopStream : _startStream,
                  icon: Icon(_runningStream ? Icons.pause : Icons.play_arrow),
                  label: Text(_runningStream ? 'إيقاف مؤقت' : 'تشغيل التسجيل المتتابع'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () {
                  setState(() => _index = _firstPendingIndex());
                },
                child: const Text('التالي'),
              ),
            ])
          else
            Row(children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (_capturing || _current == null) ? null : _captureSingle,
                  icon: _capturing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.face_retouching_natural),
                  label: const Text('تسجيل بصمة الوجه'),
                ),
              ),
            ]),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: (_current == null) ? null : _pickImageForCurrent,
            icon: const Icon(Icons.photo_library),
            label: const Text('رفع صورة الطالب لتسجيل البصمة'),
          ),
          const SizedBox(height: 8),
          if (_current != null && _enrolled.contains(_current!.id))
            OutlinedButton.icon(
              onPressed: () => _revoke(_current!),
              icon: const Icon(Icons.block),
              label: Text('تعطيل بصمة ${_current!.fullName}'),
            ),
          if (_students.isNotEmpty) ...[
            const Divider(),
            SizedBox(
              height: 46,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _students.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) {
                  final s = _students[i];
                  final enrolled = _enrolled.contains(s.id);
                  final selected = _index == i;
                  return ChoiceChip(
                    selected: selected,
                    label: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(enrolled ? Icons.check_circle : Icons.face,
                          size: 16, color: enrolled ? AppTheme.success : AppTheme.textMuted),
                      const SizedBox(width: 6),
                      Text(s.fullName),
                    ]),
                    onSelected: (_) => setState(() => _index = i),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pill(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(value, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
        const SizedBox(width: 6),
        Flexible(child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted))),
      ]),
    );
  }
}
