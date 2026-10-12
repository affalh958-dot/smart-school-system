import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../data/academic_repository.dart';
import '../../data/biometric_repository.dart';
import '../../data/database.dart';
import '../../data/models.dart';
import '../../data/repositories.dart';
import 'camera_utils.dart';

/// شاشة تسجيل وجوه الطلاب (للمدير/مسؤول النظام المخوّل فقط — مقيّدة بصلاحية).
///
/// **تكشف الوجه تلقائياً وتعرض مربّعاً فوقه، وتقرأ المعلومات بلا اختيار صف:**
///  - إن كان الطالب **مسجّلاً** يظهر اسمه وصفه وشعبته وبصمته «مسجّلة».
///  - إن لم يكن مسجّلاً يظهر «غير مسجّل» ويمكن تسجيله فوراً من نفس الشاشة.
///  - يمكن أيضاً البحث عن طالب بالاسم/الرقم ثم تسجيل وجهه.
///
/// التسجيل يأخذ عدة عينات ويتحقّق من جودتها واتساقها، ويرفض العينة الضعيفة
/// ويطلب إعادة الالتقاط بدل تسجيل بصمة رديئة.
class FaceEnrollScreen extends StatefulWidget {
  const FaceEnrollScreen({super.key, this.initialSectionId, this.studentId});
  final String? initialSectionId;

  /// عند تمريره: يُثبّت الشاشة على هذا الطالب (لتسجيل/تحديث بصمته).
  final String? studentId;

  @override
  State<FaceEnrollScreen> createState() => _FaceEnrollScreenState();
}

class _FaceEnrollScreenState extends State<FaceEnrollScreen> {
  CameraController? _camera;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  int _deviceOrientation = 0;
  FaceDetector? _detector;
  final _acad = AcademicRepository();
  final _bio = BiometricRepository();
  final _studentRepo = StudentRepository();

  String? _error;
  bool _cameraReady = false;
  bool _processing = false;

  List<Map<String, dynamic>> _sections = [];
  final Map<String, String> _sectionLabels = {};
  String? _sectionFilter; // null = كل الطلاب
  List<Student> _students = [];
  Set<String> _enrolled = {};
  int _index = 0;
  bool _sequential = true;
  bool _runningStream = false;
  bool _capturing = false;
  DateTime? _faceSeenSince;
  String _hint = 'وجّه وجهك نحو الكاميرا مباشرة';

  /// آخر وجه كُشف (للاقتصاص عند التسجيل) ووقته.
  img.Image? _lastCrop;
  DateTime? _lastCropAt;
  Rect? _lastFaceFraction; // لعرض المربّع
  _Detected? _detected; // نتيجة التعرّف على أكبر وجه

  @override
  void initState() {
    super.initState();
    _sectionFilter = widget.initialSectionId;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initCamera();
      await _loadData();
    });
  }

  String? get _schoolId => context.read<AppState>().schoolId;

  Future<void> _initCamera() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      setState(() => _error =
          'تسجيل الوجه بالكاميرا يتم على تطبيق الأندرويد المثبّت عند المدخل.\n'
          'على الحاسوب يمكنك رفع صورة الطالب لتسجيل السمات.');
      return;
    }
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error = 'لا توجد كاميرا متاحة على هذا الجهاز');
        return;
      }
      _cameras = cameras;
      _cameraIndex = cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      if (_cameraIndex < 0) _cameraIndex = 0;
      _startOrientationTracking();
      _detector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          enableTracking: true,
          minFaceSize: 0.15,
          performanceMode: FaceDetectorMode.fast,
        ),
      );
      await _openCamera(_cameras[_cameraIndex]);
      if (mounted) setState(() => _cameraReady = true);
      await _startStream();
    } catch (e) {
      setState(() => _error = 'تعذّر تشغيل الكاميرا: $e');
    }
  }

  void _startOrientationTracking() {
    void update(Size size) {
      final o = size.width > size.height ? 90 : 0;
      if (o != _deviceOrientation) _deviceOrientation = o;
    }

    if (WidgetsBinding.instance.platformDispatcher.views.isNotEmpty) {
      update(WidgetsBinding.instance.platformDispatcher.views.first.physicalSize);
    }
    WidgetsBinding.instance.platformDispatcher.onMetricsChanged = () {
      if (WidgetsBinding.instance.platformDispatcher.views.isEmpty) return;
      update(WidgetsBinding.instance.platformDispatcher.views.first.physicalSize);
    };
  }

  Future<void> _openCamera(CameraDescription description) async {
    final controller = CameraController(
      description,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await controller.initialize();
    if (!mounted) return;
    setState(() => _camera = controller);
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) {
      _snack('لا توجد كاميرا أخرى على هذا الجهاز', AppTheme.warning);
      return;
    }
    try {
      setState(() => _runningStream = false);
      await _camera?.stopImageStream().catchError((_) {});
      await _camera?.dispose();
      _cameraIndex = (_cameraIndex + 1) % _cameras.length;
      await _openCamera(_cameras[_cameraIndex]);
      await _startStream();
      final dir = _cameras[_cameraIndex].lensDirection == CameraLensDirection.front ? 'الأمامية' : 'الخلفية';
      _snack('تم التبديل إلى الكاميرا $dir', AppTheme.primary);
    } catch (e) {
      _snack('تعذّر تبديل الكاميرا: $e', AppTheme.danger);
    }
  }

  int _rotDegrees() {
    if (_cameras.isEmpty) return 0;
    return CameraUtils.rotationDegrees(_cameras[_cameraIndex], _deviceOrientation);
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

  Future<void> _loadData() async {
    final schoolId = _schoolId;
    if (schoolId == null) return;
    final yearId = await _currentYearId();
    final sections = yearId == null ? <Map<String, dynamic>>[] : await _acad.sectionsWithNames(schoolId, yearId);
    final labels = {
      for (final s in sections)
        s['id'] as String: '${s['stage_name']} / ${s['grade_name']} / ${s['name']}'
    };
    final students = await _studentRepo.allBySchool(schoolId);
    final enrolled = await _bio.enrolledStudentIds(schoolId: schoolId);
    if (!mounted) return;
    setState(() {
      _sections = sections;
      _sectionLabels
        ..clear()
        ..addAll(labels);
      _students = students;
      _enrolled = enrolled;
      final target = widget.studentId;
      final idx = target == null ? -1 : students.indexWhere((s) => s.id == target);
      _index = idx >= 0 ? idx : _firstPendingIndex();
    });
  }

  int _firstPendingIndex() {
    final list = _visibleStudents;
    for (var i = 0; i < list.length; i++) {
      if (!_enrolled.contains(list[i].id)) return i;
    }
    return 0;
  }

  /// الطلاب المعروضون حسب الفلتر (شعبة محددة أو الكل).
  List<Student> get _visibleStudents {
    if (_sectionFilter == null) return _students;
    return _students.where((s) => s.sectionId == _sectionFilter).toList();
  }

  Student? get _current {
    final list = _visibleStudents;
    return (_index >= 0 && _index < list.length) ? list[_index] : null;
  }

  String _labelFor(Student s) => _sectionLabels[s.sectionId] ?? '';

  Future<void> _startStream() async {
    final cam = _camera;
    if (cam == null || _runningStream || !_sequential) return;
    try {
      await cam.startImageStream(_onFrame);
      if (mounted) setState(() => _runningStream = true);
    } catch (e) {
      _snack('تعذّر تشغيل الكاميرا: $e', AppTheme.danger);
    }
  }

  Future<void> _stopStream() async {
    final cam = _camera;
    if (cam == null || !_runningStream) return;
    try {
      await cam.stopImageStream();
    } catch (_) {}
    if (mounted) setState(() => _runningStream = false);
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_processing || !mounted || !_sequential || _capturing) return;
    final detector = _detector;
    if (detector == null || _cameras.isEmpty) return;
    _processing = true;
    try {
      final rot = _rotDegrees();
      final input = CameraUtils.toInputImage(image, _cameras[_cameraIndex], _deviceOrientation);
      if (input == null) return;
      final faces = await detector.processImage(input);
      if (faces.isEmpty) {
        _faceSeenSince = null;
        if (mounted) {
          setState(() {
            _lastFaceFraction = null;
            _lastCrop = null;
            _detected = null;
            _hint = 'لا يوجد وجه في الكاميرا';
          });
        }
        return;
      }
      // أكبر وجه = الطالب المقابل للكاميرا.
      var best = faces.first;
      for (final f in faces) {
        if (f.boundingBox.width > best.boundingBox.width) best = f;
      }
      final crop = CameraUtils.cropFaceRotated(image, best, rot);
      final fraction = CameraUtils.boxToFraction(
          best, Size(image.width.toDouble(), image.height.toDouble()), rot);

      // التعرّف على الوجه وعرض هويته تلقائياً.
      final detected = await _identifyCrop(crop);

      if (!mounted) return;
      setState(() {
        _lastCrop = crop;
        _lastCropAt = DateTime.now();
        _lastFaceFraction = fraction;
        _detected = detected;
      });

      // التسجيل المتتابع: ننتظر ثباتاً ~0.8ث ثم نسجّل للطالب الحالي.
      final student = _current;
      if (_sequential && student != null && crop != null) {
        final now = DateTime.now();
        _faceSeenSince ??= now;
        final stable = now.difference(_faceSeenSince!).inMilliseconds;
        if (stable >= 800) {
          _capturing = true;
          await _enrollStudent(student, allowRetry: false);
          _faceSeenSince = null;
        }
      }
    } catch (_) {
      // نتجاهل أخطاء الإطار الواحد
    } finally {
      _capturing = false;
      _processing = false;
    }
  }

  /// يتعرّف على وجه مقتصّ: يعيد معلومات الطالب إن وُجد في البصمات المسجّلة.
  Future<_Detected?> _identifyCrop(img.Image? crop) async {
    if (crop == null) return null;
    final state = context.read<AppState>();
    if (!state.faceIndex.isBuilt) return null;
    final emb = state.faceEngine.embed(crop);
    if (emb == null) return null;
    final match = state.faceIndex.identify(emb);
    if (!match.accepted || match.studentId == null) {
      return _Detected(recognized: false, ambiguous: match.result == 'ambiguous', confidence: match.score);
    }
    final student = await _studentRepo.byId(match.studentId!);
    if (student == null) return _Detected(recognized: false, confidence: match.score);
    return _Detected(
      recognized: true,
      student: student,
      confidence: match.score,
      enrolled: _enrolled.contains(student.id),
    );
  }

  Future<void> _enrollStudent(Student student, {bool allowRetry = true}) async {
    final state = context.read<AppState>();
    final crop = _lastCrop;
    final fresh = _lastCropAt != null && DateTime.now().difference(_lastCropAt!).inMilliseconds < 1200;
    if (crop == null || !fresh) {
      _setHint('لا يوجد وجه واضح الآن. وجّه الوجه نحو الكاميرا ثم أعد المحاولة');
      if (allowRetry) _snack('لم يُكشف وجه واضح — أعد المحاولة', AppTheme.warning);
      return;
    }
    final first = state.faceEngine.embed(crop);
    if (first == null) {
      _setHint('تعذّر استخراج سمات الوجه، أعد المحاولة');
      return;
    }
    // نأخذ عيّنات محسّنة (سطوع/انعكاس) ونطلب اتساقها لتفادي تسجيل بصمة رديئة.
    final embeddings = <List<double>>[first.toList()];
    for (var i = 0; i < 2; i++) {
      final e = state.faceEngine.embed(_augment(crop, i));
      if (e != null) embeddings.add(e.toList());
    }
    if (!_consistent(embeddings)) {
      _setHint('الالتقاط غير متّسق — ثبّت وجهك وحسّن الإضاءة وأعد المحاولة');
      if (allowRetry) _snack('تعذّر التسجيل: حركة أو إضاءة غير مناسبة', AppTheme.warning);
      return;
    }
    final fused = _averageNormalized(embeddings);
    await _bio.upsertTemplate(
      studentId: student.id,
      embedding: Float32List.fromList(fused),
      quality: 0.95,
      enrolledBy: state.user?['id'] as String?,
    );
    await state.rebuildFaceIndex();
    if (!mounted) return;
    setState(() {
      _enrolled = {..._enrolled, student.id};
      if (_sequential) _index = _nextPendingIndex();
      _hint = 'تم تسجيل ${student.fullName}';
    });
    _snack('تم تسجيل وجه ${student.fullName}', AppTheme.success);
  }

  /// نسخ محسّنة بسيطة (سطوع/انعكاس) لتقوية متانة القالب.
  img.Image _augment(img.Image src, int i) {
    final out = img.Image.from(src);
    if (i == 0) {
      return img.adjustColor(out, brightness: 1.12);
    }
    return img.flipHorizontal(out);
  }

  bool _consistent(List<List<double>> vecs) {
    for (var a = 0; a < vecs.length; a++) {
      for (var b = a + 1; b < vecs.length; b++) {
        if (_cosine(vecs[a], vecs[b]) < 0.55) return false;
      }
    }
    return true;
  }

  double _cosine(List<double> a, List<double> b) {
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length && i < b.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  List<double> _averageNormalized(List<List<double>> vecs) {
    final dim = vecs.first.length;
    final acc = List.filled(dim, 0.0);
    for (final v in vecs) {
      for (var i = 0; i < dim; i++) {
        acc[i] += v[i];
      }
    }
    var norm = 0.0;
    for (final x in acc) {
      norm += x * x;
    }
    norm = math.sqrt(norm);
    if (norm > 0) {
      for (var i = 0; i < dim; i++) {
        acc[i] /= norm;
      }
    }
    return acc;
  }

  int _nextPendingIndex() {
    final list = _visibleStudents;
    for (var i = _index + 1; i < list.length; i++) {
      if (!_enrolled.contains(list[i].id)) return i;
    }
    for (var i = 0; i < _index; i++) {
      if (!_enrolled.contains(list[i].id)) return i;
    }
    return list.length;
  }

  void _setHint(String h) {
    if (mounted && _hint != h) setState(() => _hint = h);
  }

  /// التقاط فردي احتياطي (زر) للطالب الحالي: يستخدم آخر وجه مكتشف.
  Future<void> _captureSingle() async {
    final student = _current;
    if (student == null) return;
    if (!_runningStream) await _startStream();
    await Future.delayed(const Duration(milliseconds: 600));
    await _enrollStudent(student);
  }

  /// تسجيل البصمة من صورة مرفوعة من المعرض، مع كشف الوجه وقصّه واستخراج السمات.
  Future<void> _pickImageForStudent(Student student) async {
    setState(() => _capturing = true);
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1600);
      if (picked == null) return;
      final decoded = img.decodeImage(await picked.readAsBytes());
      if (decoded == null) throw StateError('تعذّر قراءة الصورة المرفوعة');
      final faces = await _detector?.processImage(InputImage.fromFilePath(picked.path));
      if (faces == null || faces.isEmpty) {
        throw StateError('لم يُكشف وجه واضح في الصورة. اختر صورة أوضح للوجه.');
      }
      var best = faces.first;
      for (final f in faces) {
        if (f.boundingBox.width > best.boundingBox.width) best = f;
      }
      final crop = CameraUtils.cropBox(
          decoded, best.boundingBox.left, best.boundingBox.top, best.boundingBox.width, best.boundingBox.height);
      if (crop == null) throw StateError('تعذّر قصّ منطقة الوجه');
      if (!mounted) return;
      final state = context.read<AppState>();
      final emb = state.faceEngine.embed(crop);
      if (emb == null) throw StateError('تعذّر استخراج سمات الوجه من الصورة');
      await _bio.upsertTemplate(
        studentId: student.id,
        embedding: emb,
        quality: 0.85,
        enrolledBy: state.user?['id'] as String?,
      );
      await state.rebuildFaceIndex();
      if (!mounted) return;
      setState(() => _enrolled = {..._enrolled, student.id});
      _snack('تم تسجيل وجه ${student.fullName} من الصورة', AppTheme.success);
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

  void _snack(String m, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), backgroundColor: color, duration: const Duration(seconds: 2)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.platformDispatcher.onMetricsChanged = null;
    _camera?.stopImageStream().catchError((_) {});
    _camera?.dispose();
    _detector?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!context.watch<AppState>().can(Perms.biometricManage)) {
      return Scaffold(
        appBar: AppBar(title: const Text('تسجيل وجوه الطلاب')),
        body: const Center(child: Text('لا تملك صلاحية إدارة البصمات', style: TextStyle(color: AppTheme.danger))),
      );
    }
    final list = _visibleStudents;
    final done = list.where((s) => _enrolled.contains(s.id)).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('تسجيل وجوه الطلاب'),
        actions: [
          IconButton(
            tooltip: 'تبديل الكاميرا (أمامية/خلفية)',
            icon: const Icon(Icons.cameraswitch),
            onPressed: _switchCamera,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(flex: 4, child: _cameraArea()),
          Expanded(flex: 5, child: _controls(list, done)),
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
            ElevatedButton(
              onPressed: () async {
                setState(() => _error = null);
                await _initCamera();
              },
              child: const Text('إعادة المحاولة'),
            ),
          ]),
        ),
      );
    }
    final cam = _camera;
    if (!_cameraReady || cam == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final isFront = _cameras.isNotEmpty &&
        _cameras[_cameraIndex].lensDirection == CameraLensDirection.front;
    return LayoutBuilder(
      builder: (context, constraints) {
        final view = constraints.biggest;
        double scale = 1;
        var previewSize = view;
        final pvSize = cam.value.previewSize;
        if (pvSize != null) {
          previewSize = Size(pvSize.height, pvSize.width);
          scale = math.max(view.width / previewSize.width, view.height / previewSize.height);
        }
        final detected = _detected;
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              OverflowBox(
                maxWidth: previewSize.width * scale,
                maxHeight: previewSize.height * scale,
                alignment: Alignment.center,
                child: Transform.scale(scaleX: isFront ? -1 : 1, child: CameraPreview(cam)),
              ),
              if (_lastFaceFraction != null)
                CustomPaint(
                  painter: _OneBoxPainter(
                    _lastFaceFraction!,
                    color: _boxColor(detected),
                    label: _boxLabel(detected),
                    mirrored: isFront,
                  ),
                ),
              Positioned(
                bottom: 10,
                left: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(12)),
                  child: Text(_hint,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Color _boxColor(_Detected? d) {
    if (d == null) return Colors.orange;
    if (d.ambiguous) return AppTheme.warning;
    if (d.recognized && d.enrolled) return AppTheme.success;
    if (d.recognized) return AppTheme.primary; // معروف لكن بصمته غير مسجّلة
    return Colors.orange; // غير معروف
  }

  String _boxLabel(_Detected? d) {
    if (d == null) return '';
    if (d.ambiguous) return 'التباس';
    if (d.recognized && d.enrolled) return d.student?.fullName ?? 'معروف';
    if (d.recognized) return 'معروف — البصمة غير مسجّلة';
    return 'غير مسجّل';
  }

  IconData _detectedIcon(_Detected? d) {
    if (d == null) return Icons.face;
    if (d.ambiguous) return Icons.help_outline;
    if (d.recognized && d.enrolled) return Icons.verified_user;
    if (d.recognized) return Icons.person_search;
    return Icons.person_off;
  }

  Widget _controls(List<Student> list, int done) {
    final detected = _detected;
    final current = _current;
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(12),
      child: ListView(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _boxColor(detected).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _boxColor(detected)),
            ),
            child: Row(children: [
              Icon(_detectedIcon(detected), color: _boxColor(detected), size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (detected?.recognized == true && detected?.student != null) ...[
                    Text(detected!.student!.fullName,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                    Text('الرقم: ${detected.student!.studentNumber}  •  ${_labelFor(detected.student!)}',
                        style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                    Text(detected.enrolled ? 'بصمة الوجه: مسجّلة ✓' : 'بصمة الوجه: غير مسجّلة',
                        style: TextStyle(
                            color: detected.enrolled ? AppTheme.success : AppTheme.warning,
                            fontWeight: FontWeight.bold,
                            fontSize: 12)),
                  ] else if (detected?.ambiguous == true)
                    const Text('التباس بين أكثر من طالب — وجّه الكاميرا لطالب واحد',
                        style: TextStyle(color: AppTheme.warning, fontWeight: FontWeight.bold))
                  else
                    const Text('وجه غير مسجّل — اختر الطالب من البحث ثم اضغط «تسجيل الوجه»',
                        style: TextStyle(color: AppTheme.textMuted)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 10),
          Autocomplete<Student>(
            displayStringForOption: (s) => '${s.fullName} — ${s.studentNumber}',
            optionsBuilder: (value) {
              final q = value.text.trim();
              if (q.isEmpty) return const Iterable<Student>.empty();
              return _students.where((s) => s.fullName.contains(q) || s.studentNumber.contains(q));
            },
            onSelected: (s) {
              final i = _visibleStudents.indexWhere((e) => e.id == s.id);
              setState(() => _index = i >= 0 ? i : _index);
            },
            fieldViewBuilder: (ctx, controller, focus, onSubmit) => TextField(
              controller: controller,
              focusNode: focus,
              decoration: const InputDecoration(
                labelText: 'ابحث عن طالب بالاسم أو الرقم المدرسي',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (current != null) ...[
            Row(children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _capturing ? null : () => _enrollStudent(current),
                  icon: _capturing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.face_retouching_natural),
                  label: Text(_enrolled.contains(current.id) ? 'إعادة تسجيل الوجه' : 'تسجيل الوجه'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _capturing ? null : () => _pickImageForStudent(current),
                icon: const Icon(Icons.photo_library),
                label: const Text('من صورة'),
              ),
              if (_enrolled.contains(current.id))
                IconButton(
                  tooltip: 'تعطيل البصمة',
                  onPressed: () => _revoke(current),
                  icon: const Icon(Icons.block, color: AppTheme.danger),
                ),
            ]),
            const SizedBox(height: 6),
            Text('الطالب المحدّد: ${current.fullName} — ${_labelFor(current)}',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          ],
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _pill('مسجّلون', '$done / ${list.length}', AppTheme.success)),
            const SizedBox(width: 8),
            Expanded(child: _pill('بانتظار التسجيل', '${list.length - done}', AppTheme.warning)),
          ]),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            initialValue: _sectionFilter,
            isExpanded: true,
            decoration:
                const InputDecoration(labelText: 'تصفية حسب الشعبة (اختياري)', prefixIcon: Icon(Icons.filter_alt)),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('كل الطلاب (كل الصفوف)')),
              ..._sections.map((s) => DropdownMenuItem<String?>(
                    value: s['id'] as String,
                    child: Text('${s['stage_name']} / ${s['grade_name']} / ${s['name']}',
                        overflow: TextOverflow.ellipsis),
                  )),
            ],
            onChanged: (v) async {
              await _stopStream();
              setState(() {
                _sectionFilter = v;
                _index = _firstPendingIndex();
              });
              if (_sequential) await _startStream();
            },
          ),
          const SizedBox(height: 8),
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
            subtitle: const Text('يثبّت وجه الطالب فيسجّله تلقائياً ثم ينتقل للتالي — بدون ضغط'),
          ),
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
                onPressed: () => setState(() => _index = _firstPendingIndex()),
                child: const Text('التالي'),
              ),
            ])
          else
            Row(children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (_capturing || current == null) ? null : _captureSingle,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('التقاط الوجه الآن'),
                ),
              ),
            ]),
          if (list.isNotEmpty) ...[
            const Divider(),
            SizedBox(
              height: 46,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) {
                  final s = list[i];
                  final enrolled = _enrolled.contains(s.id);
                  final isSelected = _index == i;
                  return ChoiceChip(
                    selected: isSelected,
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

/// نتيجة التعرّف على وجه واحد أثناء التسجيل.
class _Detected {
  final bool recognized;
  final bool ambiguous;
  final Student? student;
  final double confidence;
  final bool enrolled;
  _Detected({
    required this.recognized,
    this.ambiguous = false,
    this.student,
    this.confidence = 0,
    this.enrolled = false,
  });
}

/// يرسم مربّعاً واحداً فوق الوجه مع تسمية ملوّنة.
class _OneBoxPainter extends CustomPainter {
  _OneBoxPainter(this.fraction, {required this.color, required this.label, required this.mirrored});
  final Rect fraction;
  final Color color;
  final String label;
  final bool mirrored;

  @override
  void paint(Canvas canvas, Size size) {
    var r = Rect.fromLTWH(
      fraction.left * size.width,
      fraction.top * size.height,
      fraction.width * size.width,
      fraction.height * size.height,
    );
    if (mirrored) {
      r = Rect.fromLTWH(size.width - r.right, r.top, r.width, r.height);
    }
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(10)), paint);
    if (label.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.rtl,
      )..layout(maxWidth: r.width + 80);
      final top = (r.top - tp.height - 8).clamp(0.0, size.height);
      final bg = Rect.fromLTWH(r.left, top, tp.width + 12, tp.height + 4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(bg, const Radius.circular(6)),
        Paint()..color = color.withValues(alpha: 0.85),
      );
      tp.paint(canvas, Offset(bg.left + 6, bg.top + 2));
    }
  }

  @override
  bool shouldRepaint(covariant _OneBoxPainter old) =>
      old.fraction != fraction || old.color != color || old.label != label || old.mirrored != mirrored;
}
