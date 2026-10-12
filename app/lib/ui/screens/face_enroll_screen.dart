import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/repositories.dart';

/// شاشة تسجيل وجه الطالب — التقاط صورة، استخراج السمات، حفظها مشفّرة.
class FaceEnrollScreen extends StatefulWidget {
  const FaceEnrollScreen({super.key});

  @override
  State<FaceEnrollScreen> createState() => _FaceEnrollScreenState();
}

class _FaceEnrollScreenState extends State<FaceEnrollScreen> {
  CameraController? _camera;
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(performanceMode: FaceDetectorMode.fast, minFaceSize: 0.2),
  );
  String? _error;
  bool _busy = false;
  bool _cameraReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initCamera());
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error = 'لا توجد كاميرا متاحة');
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

  Future<void> _captureAndEnroll() async {
    if (_camera == null) return;
    setState(() => _busy = true);
    try {
      final state = context.read<AppState>();
      // اختيار الطالب أولاً
      final student = await _pickStudent(state);
      if (student == null) {
        setState(() => _busy = false);
        return;
      }

      final shot = await _camera!.takePicture();
      final bytes = await shot.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw StateError('تعذّر قراءة الصورة');

      // كشف الوجه والتحقق من الجودة
      final inputImage = InputImage.fromFilePath(shot.path);
      final faces = await _detector.processImage(inputImage);
      if (faces.isEmpty) {
        throw StateError('لم يتم كشف وجه واضح. اقترب من الكاميرا وأعد المحاولة.');
      }
      final face = faces.first;
      final box = face.boundingBox;
      final pad = box.width * 0.15;
      final left = (box.left - pad).clamp(0, decoded.width - 1).toInt();
      final top = (box.top - pad).clamp(0, decoded.height - 1).toInt();
      final w = (box.width + pad * 2).clamp(1, decoded.width - left).toInt();
      final h = (box.height + pad * 2).clamp(1, decoded.height - top).toInt();
      final crop = img.copyCrop(decoded, x: left, y: top, width: w, height: h);

      final embedding = state.faceEngine.embed(crop);
      if (embedding == null) throw StateError('تعذّر استخراج سمات الوجه');

      await state.biometrics.upsertTemplate(
        studentId: student.id,
        embedding: embedding,
        quality: _qualityScore(face),
        enrolledBy: state.user?['id'],
      );
      await state.rebuildFaceIndex();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم تسجيل وجه ${student.fullName} بنجاح')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: AppTheme.danger),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  double _qualityScore(Face face) {
    var score = 1.0;
    if (face.headEulerAngleY != null && face.headEulerAngleY!.abs() > 15) score -= 0.3;
    if (face.headEulerAngleZ != null && face.headEulerAngleZ!.abs() > 15) score -= 0.3;
    return score.clamp(0.0, 1.0);
  }

  Future<Student?> _pickStudent(AppState state) async {
    if (state.schoolId == null) return null;
    final list = await StudentRepository().search(state.schoolId!, '', limit: 500);
    if (!mounted) return null;
    final ctrl = TextEditingController();
    var filtered = list;
    return showDialog<Student>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        return AlertDialog(
          title: const Text('اختر الطالب'),
          content: SizedBox(
            width: 420,
            height: 420,
            child: Column(
              children: [
                TextField(
                  controller: ctrl,
                  decoration: const InputDecoration(hintText: 'ابحث...', prefixIcon: Icon(Icons.search)),
                  onChanged: (q) {
                    setDlg(() {
                      filtered = list
                          .where((s) => s.fullName.contains(q) || s.studentNumber.contains(q))
                          .toList();
                    });
                  },
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (ctx, i) => ListTile(
                      title: Text(filtered[i].fullName),
                      subtitle: Text(filtered[i].studentNumber),
                      onTap: () => Navigator.pop(ctx, filtered[i]),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء'))],
        );
      }),
    );
  }

  @override
  void dispose() {
    _camera?.dispose();
    _detector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تسجيل وجوه الطلاب')),
      body: Column(
        children: [
          Expanded(
            child: _error != null
                ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.danger)))
                : (_cameraReady && _camera != null)
                    ? CameraPreview(_camera!)
                    : const Center(child: CircularProgressIndicator()),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Column(
              children: [
                const Text(
                  'وجّه الكاميرا نحو وجه الطالب في إضاءة جيدة، ثم اضغط تسجيل.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textMuted),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: (_busy || !_cameraReady) ? null : _captureAndEnroll,
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.face_retouching_natural),
                  label: const Text('اختيار طالب وتسجيل وجهه'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
