import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/biometric_repository.dart';
import '../../data/database.dart';
import '../../data/repositories.dart';
import '../../data/student_columns_repository.dart';
import '../../data/models.dart';
import 'student_form_screen.dart';

/// الملف الشخصي للطالب — أنيق ومتناسق، يعرض كل المعلومات والسمات المخصّصة،
/// وحالة بصمة الوجه، وملخص الحضور.
class StudentProfileScreen extends StatefulWidget {
  final String studentId;
  const StudentProfileScreen({super.key, required this.studentId});

  @override
  State<StudentProfileScreen> createState() => _StudentProfileScreenState();
}

class _StudentProfileScreenState extends State<StudentProfileScreen> {
  Map<String, dynamic>? _profile;
  Map<String, String> _customLabels = {};
  Map<String, String> _attendance = {};
  bool _enrolled = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final schoolId = context.read<AppState>().schoolId;
    final profile = await StudentRepository().fullProfile(widget.studentId);
    final columns = schoolId == null ? <dynamic>[] : await StudentColumnsRepository().columns(schoolId);
    final values = await StudentColumnsRepository().valuesForStudent(widget.studentId);
    final labels = <String, String>{};
    for (final c in columns) {
      if (values.containsKey(c.id)) labels[c.label] = values[c.id]!;
    }
    final db = await AppDatabase.instance.database;
    final attRows = await db.rawQuery('''
      SELECT status, COUNT(*) c FROM attendance_records
      WHERE student_id = ? AND deleted_at IS NULL GROUP BY status
    ''', [widget.studentId]);
    final enrolledIds = await BiometricRepository().enrolledStudentIds();
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _customLabels = labels;
      _attendance = {for (final r in attRows) r['status'] as String: '${r['c']}'};
      _enrolled = enrolledIds.contains(widget.studentId);
      _loading = false;
    });
  }

  Future<void> _edit() async {
    final id = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => StudentFormScreen(existing: Student.fromMap(_profile!))),
    );
    if (id != null) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ملف الطالب'),
        actions: [
          IconButton(onPressed: _edit, icon: const Icon(Icons.edit), tooltip: 'تعديل'),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _profile == null
              ? const Center(child: Text('لم يتم العثور على الطالب'))
              : RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    final p = _profile!;
    final photo = p['photo_path'] as String?;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: Column(children: [
            CircleAvatar(
              radius: 52,
              backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
              backgroundImage: (photo != null && File(photo).existsSync()) ? FileImage(File(photo)) : null,
              child: (photo == null || !File(photo).existsSync())
                  ? Text(
                      (p['full_name'] as String).characters.first,
                      style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: AppTheme.primary),
                    )
                  : null,
            ),
            const SizedBox(height: 12),
            Text(p['full_name'] as String, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            Text('الرقم المدرسي: ${p['student_number']}',
                style: const TextStyle(color: AppTheme.textMuted)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              _badge('${p['stage_name'] ?? '-'} / ${p['grade_name'] ?? '-'}', AppTheme.accent),
              _badge(p['section_name'] == null ? 'بدون شعبة' : 'شعبة ${p['section_name']}', AppTheme.primary),
              _badge(_enrolled ? 'بصمة الوجه مسجّلة' : 'بصمة الوجه غير مسجّلة',
                  _enrolled ? AppTheme.success : AppTheme.warning),
            ]),
          ]),
        ),
        const SizedBox(height: 18),
        _card('ملخص الحضور', Icons.bar_chart, [
          _row('حاضر', _attendance['present'] ?? '0'),
          _row('متأخر', _attendance['late'] ?? '0'),
          _row('غائب', _attendance['absent'] ?? '0'),
          _row('غياب بعذر', _attendance['excused'] ?? '0'),
        ]),
        _card('البيانات الشخصية', Icons.person_outline, [
          _row('الجنس', p['gender'] == 'male' ? 'ذكر' : (p['gender'] == 'female' ? 'أنثى' : '-')),
          _row('تاريخ الميلاد', p['birth_date'] ?? '-'),
          _row('رقم الهوية', p['national_id'] ?? '-'),
        ]),
        _card('التواصل والسكن', Icons.contact_phone, [
          _row('هاتف الطالب', p['student_phone'] ?? '-'),
          _row('ولي الأمر', p['guardian_name'] ?? '-'),
          _row('هاتف ولي الأمر', p['guardian_phone'] ?? '-'),
          _row('السكن', p['residence'] ?? '-'),
          _row('العنوان', p['address'] ?? '-'),
        ]),
        if (_customLabels.isNotEmpty)
          _card('حقول إضافية', Icons.edit_note,
              _customLabels.entries.map((e) => _row(e.key, e.value)).toList()),
        _card('ملاحظات', Icons.notes, [_row('ملاحظات', p['notes'] ?? '-')]),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      );

  Widget _card(String title, IconData icon, List<Widget> children) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: AppTheme.primary, size: 20),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          ]),
          const Divider(),
          ...children,
        ]),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 130, child: Text(label, style: const TextStyle(color: AppTheme.textMuted))),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w500))),
        ]),
      );
}
