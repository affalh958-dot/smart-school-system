import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/academic_repository.dart';
import '../../data/audit_repository.dart';
import '../../data/biometric_repository.dart';
import '../../data/database.dart';
import '../../data/models.dart';
import '../../data/repositories.dart';
import '../../data/student_columns_repository.dart';
import 'camera_utils.dart';

/// شاشة نموذج الطالب — تُستخدم للإضافة والتعديل، وتدعم الحقول المخصّصة.
/// تعيد معرّف الطالب عبر Navigator.pop عند الحفظ.
class StudentFormScreen extends StatefulWidget {
  final Student? existing;
  final String? presetSectionId;
  final bool keepOpenAfterSave;
  const StudentFormScreen({
    super.key,
    this.existing,
    this.presetSectionId,
    this.keepOpenAfterSave = false,
  });

  @override
  State<StudentFormScreen> createState() => _StudentFormScreenState();
}

class _StudentFormScreenState extends State<StudentFormScreen> {
  final _students = StudentRepository();
  final _acad = AcademicRepository();
  final _columnsRepo = StudentColumnsRepository();
  final _bio = BiometricRepository();

  final _number = TextEditingController();
  final _name = TextEditingController();
  final _nationalId = TextEditingController();
  final _studentPhone = TextEditingController();
  final _guardianName = TextEditingController();
  final _guardianPhone = TextEditingController();
  final _residence = TextEditingController();
  final _address = TextEditingController();
  final _health = TextEditingController();
  final _notes = TextEditingController();

  String? _gender;
  String _status = 'active';
  DateTime? _birthDate;
  String? _sectionId;
  String? _photoPath;
  /// تمثيل سمات الوجه المقروء من الصورة المرفوعة (يُحوَّل لبصمة عند الحفظ).
  Float32List? _photoEmbedding;
  /// المربّع النسبي للوجه داخل الصورة (لإظهار أنه قُرئ فعلاً).
  Rect? _photoFaceBox;
  bool _processingPhoto = false;
  String? _photoStatus;

  List<Map<String, dynamic>> _sections = [];
  List<StudentColumn> _columns = [];
  final Map<String, TextEditingController> _custom = {};
  final Map<String, String> _customValues = {};

  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _number.text = e.studentNumber;
      _name.text = e.fullName;
      _nationalId.text = e.nationalId ?? '';
      _studentPhone.text = e.studentPhone ?? '';
      _guardianName.text = e.guardianName ?? '';
      _guardianPhone.text = e.guardianPhone ?? '';
      _residence.text = e.residence ?? '';
      _address.text = e.address ?? '';
      _health.text = e.healthStatus ?? '';
      _notes.text = e.notes ?? '';
      _gender = e.gender;
      _status = e.status;
      _birthDate = e.birthDate == null ? null : DateTime.tryParse(e.birthDate!);
      _sectionId = e.sectionId;
      _photoPath = e.photoPath;
    } else {
      _sectionId = widget.presetSectionId;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  String? get _schoolId => context.read<AppState>().schoolId;

  String? get _currentUserId => context.read<AppState>().user?['id'] as String?;

  Future<void> _load() async {
    final schoolId = _schoolId;
    if (schoolId == null) return;
    final yearRows = await (await AppDatabase.instance.database).query('academic_years',
        where: 'school_id = ? AND deleted_at IS NULL',
        whereArgs: [schoolId],
        orderBy: 'is_current DESC, start_date DESC',
        limit: 1);
    final yearId = yearRows.isEmpty ? null : yearRows.first['id'] as String;
    final sections = yearId == null ? <Map<String, dynamic>>[] : await _acad.sectionsWithNames(schoolId, yearId);
    final columns = await _columnsRepo.columns(schoolId);
    final values = widget.existing == null ? <String, String>{} : await _columnsRepo.valuesForStudent(widget.existing!.id);
    if (!mounted) return;
    setState(() {
      _sections = sections;
      _columns = columns;
      _customValues.addAll(values);
      for (final c in columns) {
        _custom[c.id] = TextEditingController(text: values[c.id] ?? '');
      }
      _loading = false;
    });
  }

  Future<void> _pickBirth() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(2012),
      firstDate: DateTime(1990),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _birthDate = picked);
  }

  /// التقاط/اختيار صورة شخصية، وتُقرأ بالكاميرا/المعرض، **ويُتحقّق من الوجه
  /// بالنموذج**: إن لم يُقرأ وجه واضح يُرفض رفع الصورة ولا تُثبّت البصمة.
  Future<void> _pickPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text('التقاط صورة بالكاميرا'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('اختيار صورة من المعرض'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (source == null) return;
    final picker = ImagePicker();
    final shot = await picker.pickImage(source: source, imageQuality: 90, maxWidth: 1200);
    if (shot == null) return;
    if (!mounted) return;
    final state = context.read<AppState>();
    final engineReady = state.faceEngine.isReady;
    final green = 'تم قراءة الوجه ✓ — سيُسجَّل كبصمة عند الحفظ';
    final red = 'لم يُقرأ وجه واضح في الصورة';
    setState(() {
      _processingPhoto = true;
      _photoEmbedding = null;
      _photoFaceBox = null;
      _photoStatus = engineReady ? 'جارٍ قراءة الوجه…' : 'معالجة الصورة…';
    });
    try {
      // 1) كشف الوجه بالكاميرا (نموذج ML Kit الحقيقي).
      final detector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          performanceMode: FaceDetectorMode.accurate,
          minFaceSize: 0.08,
        ),
      );
      final faces = await detector.processImage(InputImage.fromFilePath(shot.path));
      await detector.close();
      if (faces.isEmpty) {
        if (mounted) {
          setState(() {
            _processingPhoto = false;
            _photoStatus = red;
            _photoPath = null;
          });
          _snack('$red — أعد الالتقاط بوجه واضح ومضاء مباشرة.', AppTheme.danger);
        }
        return;
      }
      var best = faces.first;
      for (final f in faces) {
        if (f.boundingBox.width > best.boundingBox.width) best = f;
      }
      final decoded = img.decodeImage(await File(shot.path).readAsBytes());
      if (decoded == null) throw StateError('تعذّر قراءة ملف الصورة');
      final crop = CameraUtils.cropBox(
          decoded, best.boundingBox.left, best.boundingBox.top, best.boundingBox.width, best.boundingBox.height);
      if (crop == null) throw StateError('تعذّر قصّ منطقة الوجه');
      // 2) استخراج السمات بالنموذج (MobileFaceNet). على الحاسوب دون نموذج
      //    نحفظ الصورة فقط ولا نمنع الإضافة.
      final emb = engineReady ? state.faceEngine.embed(crop) : null;
      if (engineReady && emb == null) throw StateError('تعذّر استخراج سمات الوجه من الصورة');

      // 3) حفظ الصورة الشخصية في مجلد دعم التطبيق.
      final dir = await getApplicationSupportDirectory();
      final photoDir = Directory(p.join(dir.path, 'student_photos'));
      if (!photoDir.existsSync()) photoDir.createSync(recursive: true);
      final dest = p.join(photoDir.path, '${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(shot.path).copy(dest);
      if (!mounted) return;
      setState(() {
        _photoPath = dest;
        _photoEmbedding = emb;
        _photoFaceBox = Rect.fromLTWH(
          best.boundingBox.left / decoded.width,
          best.boundingBox.top / decoded.height,
          best.boundingBox.width / decoded.width,
          best.boundingBox.height / decoded.height,
        );
        _processingPhoto = false;
        _photoStatus = engineReady ? green : 'حُفظت الصورة (قراءة الوجه تتطلّب تطبيق الأندرويد)';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _processingPhoto = false;
          _photoStatus = red;
          _photoPath = null;
          _photoEmbedding = null;
        });
        _snack('$red: $e', AppTheme.danger);
      }
    }
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _save({bool addAnother = false}) async {
    final schoolId = _schoolId;
    if (schoolId == null) return;
    if (_number.text.trim().isEmpty || _name.text.trim().isEmpty) {
      _snack('الرقم المدرسي والاسم الكامل مطلوبان', AppTheme.danger);
      return;
    }
    // تحقق من الحقول المخصّصة الإلزامية
    for (final c in _columns) {
      if (c.isRequired && (_custom[c.id]?.text.trim().isEmpty ?? true)) {
        _snack('الحقل «${c.label}» مطلوب', AppTheme.danger);
        return;
      }
    }
    setState(() => _saving = true);
    try {
      final f = widget.existing;
      final student = Student(
        id: f?.id ?? '',
        schoolId: schoolId,
        studentNumber: _number.text.trim(),
        fullName: _name.text.trim(),
        gender: _gender,
        birthDate: _birthDate == null ? null : _iso(_birthDate!),
        address: _address.text.trim().isEmpty ? null : _address.text.trim(),
        sectionId: _sectionId,
        academicYearId: f?.academicYearId,
        status: _status,
        photoPath: _photoPath,
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        nationalId: _nationalId.text.trim().isEmpty ? null : _nationalId.text.trim(),
        studentPhone: _studentPhone.text.trim().isEmpty ? null : _studentPhone.text.trim(),
        guardianName: _guardianName.text.trim().isEmpty ? null : _guardianName.text.trim(),
        guardianPhone: _guardianPhone.text.trim().isEmpty ? null : _guardianPhone.text.trim(),
        residence: _residence.text.trim().isEmpty ? null : _residence.text.trim(),
        healthStatus: _health.text.trim().isEmpty ? null : _health.text.trim(),
        enrollmentDate: f?.enrollmentDate,
      );

      String id;
      if (f == null) {
        // منع تكرار الرقم المدرسي
        final dup = await _students.byNumber(schoolId, student.studentNumber);
        if (dup != null) {
          _snack('الرقم المدرسي مستخدم مسبقاً للطالب ${dup.fullName}', AppTheme.danger);
          return;
        }
        id = await _students.create(student);
      } else {
        await _students.update(student);
        id = f.id;
      }

      final customValues = {for (final c in _columns) c.id: _custom[c.id]?.text.trim() ?? ''};
      if (customValues.isNotEmpty) await _columnsRepo.setValues(id, customValues);

      // تسجيل بصمة الوجه من الصورة المرفوعة (إن قرأها النموذج).
      bool faceRegistered = false;
      final emb = _photoEmbedding;
      if (emb != null) {
        if (!mounted) return;
        final state = context.read<AppState>();
        await _bio.upsertTemplate(
          studentId: id,
          embedding: emb,
          quality: 0.85,
          enrolledBy: _currentUserId,
        );
        await state.rebuildFaceIndex();
        faceRegistered = true;
      }

      await AuditRepository().log(
        userId: _currentUserId,
        action: f == null ? 'student.create' : 'student.update',
        entityType: 'student',
        entityId: id,
        newValue: '${student.fullName} (${student.studentNumber})',
      );

      if (!mounted) return;
      final base = addAnother
          ? 'تمت الإضافة — أضف الطالب التالي'
          : (f == null ? 'تمت إضافة الطالب بنجاح' : 'تم حفظ التعديلات');
      _snack(faceRegistered ? '$base • تم تسجيل بصمة الوجه ✓' : base, AppTheme.success);
      if (addAnother) {
        _number.clear();
        _name.clear();
        _resetForm();
      } else if (!widget.keepOpenAfterSave) {
        Navigator.pop(context, id);
      } else {
        _number.clear();
        _name.clear();
        _resetForm();
      }
    } catch (e) {
      _snack('تعذّر الحفظ: $e', AppTheme.danger);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _resetForm() {
    _nationalId.clear();
    _studentPhone.clear();
    _guardianName.clear();
    _guardianPhone.clear();
    _residence.clear();
    _address.clear();
    _health.clear();
    _notes.clear();
    _gender = null;
    _birthDate = null;
    _photoPath = null;
    _photoEmbedding = null;
    _photoFaceBox = null;
    _photoStatus = null;
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  @override
  void dispose() {
    for (final c in _custom.values) {
      c.dispose();
    }
    _number.dispose();
    _name.dispose();
    _nationalId.dispose();
    _studentPhone.dispose();
    _guardianName.dispose();
    _guardianPhone.dispose();
    _residence.dispose();
    _address.dispose();
    _health.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'تعديل ملف الطالب' : 'طالب جديد')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(child: _photoPicker()),
                const SizedBox(height: 8),
                _sectionTitle('البيانات الأساسية'),
                _field(_number, 'الرقم المدرسي *', Icons.tag, keyboard: TextInputType.number),
                _field(_name, 'الاسم الكامل *', Icons.person),
                Row(children: [
                  Expanded(child: _genderField()),
                  const SizedBox(width: 8),
                  Expanded(child: _birthField()),
                ]),
                _field(_nationalId, 'رقم الهوية / الجنسية', Icons.badge),
                const SizedBox(height: 8),
                _sectionTitle('بيانات التواصل والسكن'),
                _field(_studentPhone, 'هاتف الطالب', Icons.phone_android, keyboard: TextInputType.phone),
                _field(_guardianName, 'اسم ولي الأمر', Icons.family_restroom),
                _field(_guardianPhone, 'هاتف ولي الأمر', Icons.phone, keyboard: TextInputType.phone),
                _field(_residence, 'السكن', Icons.home),
                _field(_address, 'العنوان', Icons.location_on),
                _field(_health, 'الحالة الصحية', Icons.medical_information),
                const SizedBox(height: 8),
                _sectionTitle('الصف والشعبة'),
                _sectionField(),
                const SizedBox(height: 8),
                _statusField(),
                const SizedBox(height: 8),
                _sectionTitle('ملاحظات'),
                _field(_notes, 'ملاحظات إدارية', Icons.notes, maxLines: 3),
                if (_columns.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _sectionTitle('حقول إضافية'),
                  for (final c in _columns) _customField(c),
                ],
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: _saving ? null : () => _save(),
                  icon: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save),
                  label: Text(isEdit ? 'حفظ التعديلات' : 'إضافة الطالب'),
                ),
                if (!isEdit) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : () => _save(addAnother: true),
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('إضافة وحفظ وطالب آخر'),
                  ),
                ],
                const SizedBox(height: 30),
              ],
            ),
    );
  }

  Widget _photoPicker() {
    final hasPhoto = _photoPath != null && File(_photoPath!).existsSync();
    final readOk = _photoEmbedding != null;
    return Column(children: [
      Stack(
        alignment: Alignment.center,
        children: [
          GestureDetector(
            onTap: _processingPhoto ? null : _pickPhoto,
            child: SizedBox(
              width: 104,
              height: 104,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipOval(
                    child: hasPhoto
                        ? Image.file(File(_photoPath!), fit: BoxFit.cover)
                        : Container(
                            color: AppTheme.primary.withValues(alpha: 0.12),
                            child: const Icon(Icons.add_a_photo, size: 32, color: AppTheme.primary),
                          ),
                  ),
                  // مربّع أخضر حول الوجه المقروء (دليل أن النموذج قرأه فعلاً).
                  if (readOk && _photoFaceBox != null)
                    CustomPaint(painter: _PhotoFacePainter(_photoFaceBox!)),
                  if (readOk)
                    const Positioned(
                      bottom: 2,
                      right: 2,
                      child: Icon(Icons.check_circle, color: AppTheme.success, size: 22),
                    ),
                ],
              ),
            ),
          ),
          if (_processingPhoto)
            const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
        ],
      ),
      TextButton.icon(
        onPressed: _processingPhoto ? null : _pickPhoto,
        icon: const Icon(Icons.photo_camera, size: 18),
        label: Text(hasPhoto ? 'تغيير الصورة' : 'التقاط صورة شخصية'),
      ),
      if (_photoStatus != null)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            _photoStatus!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: readOk ? AppTheme.success : (_processingPhoto ? AppTheme.textMuted : AppTheme.danger),
            ),
          ),
        ),
    ]);
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.primary)),
      );

  Widget _field(TextEditingController c, String label, IconData icon,
      {TextInputType? keyboard, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: c,
        keyboardType: keyboard,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
      ),
    );
  }

  Widget _genderField() => DropdownButtonFormField<String>(
        initialValue: _gender,
        decoration: const InputDecoration(labelText: 'الجنس', prefixIcon: Icon(Icons.wc)),
        items: const [
          DropdownMenuItem(value: 'male', child: Text('ذكر')),
          DropdownMenuItem(value: 'female', child: Text('أنثى')),
        ],
        onChanged: (v) => setState(() => _gender = v),
      );

  Widget _birthField() => InkWell(
        onTap: _pickBirth,
        child: InputDecorator(
          decoration: const InputDecoration(labelText: 'تاريخ الميلاد', prefixIcon: Icon(Icons.cake)),
          child: Text(_birthDate == null ? 'اختر' : _iso(_birthDate!)),
        ),
      );

  Widget _sectionField() => DropdownButtonFormField<String>(
        initialValue: _sectionId,
        decoration: const InputDecoration(labelText: 'الشعبة', prefixIcon: Icon(Icons.meeting_room)),
        items: [
          const DropdownMenuItem(value: null, child: Text('بدون شعبة')),
          ..._sections.map((s) => DropdownMenuItem(
                value: s['id'] as String,
                child: Text('${s['stage_name']} / ${s['grade_name']} / ${s['name']}'),
              )),
        ],
        onChanged: (v) => setState(() => _sectionId = v),
      );

  Widget _statusField() => DropdownButtonFormField<String>(
        initialValue: _status,
        decoration: const InputDecoration(labelText: 'الحالة', prefixIcon: Icon(Icons.flag)),
        items: const [
          DropdownMenuItem(value: 'active', child: Text('مستمر')),
          DropdownMenuItem(value: 'transferred', child: Text('منقول')),
          DropdownMenuItem(value: 'graduated', child: Text('متخرج')),
          DropdownMenuItem(value: 'withdrawn', child: Text('منسحب')),
        ],
        onChanged: (v) => setState(() => _status = v ?? 'active'),
      );

  Widget _customField(StudentColumn c) {
    final ctrl = _custom[c.id]!;
    return _field(ctrl, c.isRequired ? '${c.label} *' : c.label,
        c.dataType == 'number' ? Icons.numbers : Icons.edit_note,
        keyboard: c.dataType == 'number' ? TextInputType.number : null);
  }
}

/// يرسم مربّعاً أخضر حول الوجه المقروء داخل الصورة الشخصية الدائرية.
class _PhotoFacePainter extends CustomPainter {
  _PhotoFacePainter(this.fraction);
  final Rect fraction;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(
      fraction.left * size.width,
      fraction.top * size.height,
      fraction.width * size.width,
      fraction.height * size.height,
    );
    final paint = Paint()
      ..color = AppTheme.success
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)), paint);
  }

  @override
  bool shouldRepaint(covariant _PhotoFacePainter old) => old.fraction != fraction;
}
