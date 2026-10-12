import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/academic_repository.dart';
import '../../data/biometric_repository.dart';
import '../../data/database.dart';
import '../../data/models.dart';
import '../../data/repositories.dart';
import 'camera_utils.dart';

/// شاشة تسجيل وجوه الطلاب (للمدير/مسؤول النظام المخوّل).
///
/// التدفّق: اختر الشعبة → اختر الطالب → التقط وجهه → استخراج السمات وحفظها
/// مشفّرة. تُظهر حالة كل طالب (مُسجَّل / غير مُسجَّل) وتتيح تعطيل بصمة طالب.
class FaceEnrollScreen extends StatefulWidget {
  const FaceEnrollScreen({super.key});

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
  bool _busy = false;
  bool _cameraReady = false;

  List<Map<String, dynamic>> _sections = [];
  String? _sectionId;
  List<Student> _students = [];
  Set<String> _enrolled = {};
  Student? _selected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initCamera();
      await _loadSections();
    });
  }

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
      final controller = CameraController(front, ResolutionPreset.medium, enableAudio: false);
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

  String? get _schoolId => context.read<AppState>().schoolId;

  Future<String?> _currentYearId() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('academic_years',
        where: 'school_id = ? AND deleted_at IS NULL',
        whereArgs: [_schoolId],
        orderBy: 'is_current DESC, start_date DESC',
        limit: 1);
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  Future<void> _loadSections() async {
    if (_schoolId == null) return;
    final yearId = await _currentYearId();
    if (yearId == null) return;
    final sections = await _acad.sectionsWithNames(_schoolId!, yearId);
    if (!mounted) return;
    setState(() => _sections = sections);
    if (sections.isNotEmpty) {
      await _selectSection(sections.first['id'] as String);
    }
  }

  Future<void> _selectSection(String sectionId) async {
    setState(() {
      _sectionId = sectionId;
      _selected = null;
    });
    final students = await StudentRepository().bySection(sectionId);
    final enrolled = await _bio.enrolledStudentIds(schoolId: _schoolId, sectionId: sectionId);
    if (!mounted) return;
    setState(() {
      _students = students;
      _enrolled = enrolled;
    });
  }

  Future<void> _capture() async {
    final student = _selected;
    if (student == null || _camera == null) return;
    setState(() => _busy = true);
    try {
      final state = context.read<AppState>();
      final shot = await _camera!.takePicture();
      final bytes = await shot.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw StateError('تعذّر قراءة الصورة');

      final inputImage = InputImage.fromFilePath(shot.path);
      final faces = await _detector.processImage(inputImage);
      if (faces.isEmpty) {
        throw StateError('لم يُكشف وجه واضح. اقترب من الكاميرا، وحسّن الإضاءة، وأعد المحاولة.');
      }
      if (faces.length > 1) {
        throw StateError('يوجد أكثر من وجه في الصورة. تأكد من وجود طالب واحد فقط.');
      }
      final face = faces.first;
      final quality = _qualityScore(face);
      if (quality < 0.5) {
        throw StateError('جودة الصورة منخفضة (زاوية أو إضاءة غير مناسبة). أعد المحاولة.');
      }

      final crop = CameraUtils.cropBox(decoded, face.boundingBox.left, face.boundingBox.top,
          face.boundingBox.width, face.boundingBox.height);
      if (crop == null) throw StateError('تعذّر قصّ منطقة الوجه');

      final embedding = state.faceEngine.embed(crop);
      if (embedding == null) throw StateError('تعذّر استخراج سمات الوجه');

      await _bio.upsertTemplate(
        studentId: student.id,
        embedding: embedding,
        quality: quality,
        enrolledBy: state.user?['id'] as String?,
      );
      await state.rebuildFaceIndex();

      if (!mounted) return;
      setState(() => _enrolled = {..._enrolled, student.id});
      _snack('تم تسجيل وجه ${student.fullName} بنجاح (جودة ${(quality * 100).round()}%)', AppTheme.success);
    } catch (e) {
      _snack('$e', AppTheme.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke() async {
    final student = _selected;
    if (student == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تعطيل بصمة الوجه'),
        content: Text('سيتم تعطيل التعرّف على وجه ${student.fullName} دون حذف ملفه المدرسي. هل تريد المتابعة؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تعطيل')),
        ],
      ),
    );
    if (confirm != true) return;
    if (!mounted) return;
    final state = context.read<AppState>();
    await _bio.revokeForStudent(student.id);
    await state.rebuildFaceIndex();
    if (!mounted) return;
    setState(() => _enrolled = {..._enrolled}..remove(student.id));
    _snack('تم تعطيل بصمة وجه ${student.fullName}', AppTheme.warning);
  }

  double _qualityScore(Face face) {
    var score = 1.0;
    final yaw = face.headEulerAngleY?.abs() ?? 0;
    final roll = face.headEulerAngleZ?.abs() ?? 0;
    if (yaw > 15) score -= 0.3;
    if (roll > 15) score -= 0.3;
    if (face.boundingBox.width < 80) score -= 0.2;
    return score.clamp(0.0, 1.0);
  }

  void _snack(String m, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: color));
  }

  @override
  void dispose() {
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
          Expanded(child: _cameraArea()),
          _controls(total, done),
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
        Positioned(
          bottom: 12,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
              child: Text(
                _selected == null ? 'اختر طالباً من القائمة' : 'الطالب: ${_selected!.fullName}',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _controls(int total, int done) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_sections.isEmpty)
            const Text('لا توجد شعب. أنشئ الشعب من «الهيكل المدرسي» أولاً.',
                style: TextStyle(color: AppTheme.danger))
          else
            DropdownButtonFormField<String>(
              initialValue: _sectionId,
              decoration: const InputDecoration(labelText: 'الشعبة', prefixIcon: Icon(Icons.meeting_room)),
              items: _sections
                  .map((s) => DropdownMenuItem(
                        value: s['id'] as String,
                        child: Text('${s['stage_name']} / ${s['grade_name']} / ${s['name']}'),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v != null) _selectSection(v);
              },
            ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _pill('مُسجَّلون في الشعبة', '$done / $total', AppTheme.success)),
            const SizedBox(width: 8),
            Expanded(child: _pill('بانتظار التسجيل', '${total - done}', AppTheme.warning)),
          ]),
          const SizedBox(height: 8),
          if (_students.isNotEmpty)
            SizedBox(
              height: 46,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _students.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) {
                  final s = _students[i];
                  final enrolled = _enrolled.contains(s.id);
                  final selected = _selected?.id == s.id;
                  return ChoiceChip(
                    selected: selected,
                    label: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(enrolled ? Icons.check_circle : Icons.face,
                          size: 16, color: enrolled ? AppTheme.success : AppTheme.textMuted),
                      const SizedBox(width: 6),
                      Text(s.fullName),
                    ]),
                    onSelected: (_) => setState(() => _selected = s),
                  );
                },
              ),
            ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: (_busy || !_cameraReady || _selected == null) ? null : _capture,
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.face_retouching_natural),
                label: Text(_enrolled.contains(_selected?.id) ? 'تحديث بصمة الوجه' : 'تسجيل بصمة الوجه'),
              ),
            ),
            if (_selected != null && _enrolled.contains(_selected!.id)) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _revoke,
                icon: const Icon(Icons.block),
                label: const Text('تعطيل'),
              ),
            ],
          ]),
          const SizedBox(height: 6),
          const Text(
            'وجّه الكاميرا نحو وجه الطالب في إضاءة جيدة ونظرة مباشرة، ثم اضغط التسجيل.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ),
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
