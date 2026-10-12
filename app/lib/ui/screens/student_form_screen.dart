import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/academic_repository.dart';
import '../../data/audit_repository.dart';
import '../../data/database.dart';
import '../../data/models.dart';
import '../../data/repositories.dart';
import '../../data/student_columns_repository.dart';

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

  final _number = TextEditingController();
  final _name = TextEditingController();
  final _nationalId = TextEditingController();
  final _studentPhone = TextEditingController();
  final _guardianName = TextEditingController();
  final _guardianPhone = TextEditingController();
  final _residence = TextEditingController();
  final _address = TextEditingController();
  final _notes = TextEditingController();

  String? _gender;
  String _status = 'active';
  DateTime? _birthDate;
  String? _sectionId;

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
      _notes.text = e.notes ?? '';
      _gender = e.gender;
      _status = e.status;
      _birthDate = e.birthDate == null ? null : DateTime.tryParse(e.birthDate!);
      _sectionId = e.sectionId;
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

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _save() async {
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
        photoPath: f?.photoPath,
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        nationalId: _nationalId.text.trim().isEmpty ? null : _nationalId.text.trim(),
        studentPhone: _studentPhone.text.trim().isEmpty ? null : _studentPhone.text.trim(),
        guardianName: _guardianName.text.trim().isEmpty ? null : _guardianName.text.trim(),
        guardianPhone: _guardianPhone.text.trim().isEmpty ? null : _guardianPhone.text.trim(),
        residence: _residence.text.trim().isEmpty ? null : _residence.text.trim(),
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

      await AuditRepository().log(
        userId: _currentUserId,
        action: f == null ? 'student.create' : 'student.update',
        entityType: 'student',
        entityId: id,
        newValue: '${student.fullName} (${student.studentNumber})',
      );

      if (!mounted) return;
      _snack(f == null ? 'تمت إضافة الطالب بنجاح' : 'تم حفظ التعديلات', AppTheme.success);
      if (!widget.keepOpenAfterSave) {
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
    _notes.clear();
    _gender = null;
    _birthDate = null;
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
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save),
                  label: Text(isEdit ? 'حفظ التعديلات' : 'إضافة الطالب'),
                ),
                const SizedBox(height: 30),
              ],
            ),
    );
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
