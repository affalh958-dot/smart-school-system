import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../data/academic_repository.dart';
import '../../data/database.dart';
import '../../data/models.dart';
import '../../data/repositories.dart';
import 'student_form_screen.dart';
import 'student_import_screen.dart';
import 'student_profile_screen.dart';

/// شاشة الطلاب — تنظيم على شكل «صفوف ← شعب ← طلاب»، مع بحث وإضافة سريعة
/// وملف شخصي أنيق لكل طالب.
class StudentsScreen extends StatefulWidget {
  const StudentsScreen({super.key});

  @override
  State<StudentsScreen> createState() => _StudentsScreenState();
}

class _StudentsScreenState extends State<StudentsScreen> {
  final _searchCtrl = TextEditingController();
  final _acad = AcademicRepository();
  final _students = StudentRepository();

  List<Map<String, dynamic>> _sections = [];
  String? _sectionId;
  List<Student> _list = [];
  bool _loading = true;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSections());
  }

  String? get _schoolId => context.read<AppState>().schoolId;

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
    setState(() {
      _sections = sections;
      _loading = false;
    });
    if (sections.isNotEmpty) {
      await _selectSection(sections.first['id'] as String);
    } else {
      setState(() => _list = []);
    }
  }

  Future<void> _selectSection(String id) async {
    setState(() {
      _sectionId = id;
      _searching = false;
      _searchCtrl.clear();
    });
    final list = await _students.bySection(id);
    if (!mounted) return;
    setState(() => _list = list);
  }

  Future<void> _search(String q) async {
    final schoolId = _schoolId;
    if (schoolId == null) return;
    if (q.trim().isEmpty) {
      if (_sectionId != null) await _selectSection(_sectionId!);
      return;
    }
    setState(() => _searching = true);
    final list = await _students.search(schoolId, q, limit: 200);
    if (!mounted) return;
    setState(() {
      _list = list;
      _searching = false;
    });
  }

  Future<void> _addStudent() async {
    final id = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => StudentFormScreen(presetSectionId: _sectionId)),
    );
    if (id != null) {
      if (_sectionId != null) await _selectSection(_sectionId!);
      await _refreshSections();
    }
  }

  Future<void> _refreshSections() async {
    final schoolId = _schoolId;
    if (schoolId == null) return;
    final yearId = await _currentYearId();
    if (yearId == null) return;
    final sections = await _acad.sectionsWithNames(schoolId, yearId);
    if (!mounted) return;
    setState(() => _sections = sections);
  }

  Future<void> _openProfile(Student s) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => StudentProfileScreen(studentId: s.id)),
    );
    if (_sectionId != null) await _selectSection(_sectionId!);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canWrite = context.watch<AppState>().can(Perms.studentWrite);
    return Scaffold(
      appBar: AppBar(
        title: const Text('الطلاب'),
        actions: [
          if (canWrite)
            IconButton(
              tooltip: 'استيراد من ملف',
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const StudentImportScreen())),
              icon: const Icon(Icons.upload_file),
            ),
        ],
      ),
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(
              onPressed: _addStudent,
              icon: const Icon(Icons.person_add),
              label: const Text('طالب جديد'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _header(),
                Expanded(
                  child: _list.isEmpty
                      ? const Center(child: Text('لا يوجد طلاب في هذه الشعبة'))
                      : ListView.builder(
                          itemCount: _list.length,
                          itemBuilder: (ctx, i) => _studentTile(_list[i]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _header() {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            if (_sections.isEmpty)
              const Text('لا توجد شعب. أنشئ الصفوف والشعب من «الهيكل المدرسي» أولاً.',
                  style: TextStyle(color: AppTheme.danger))
            else
              DropdownButtonFormField<String>(
                initialValue: _sectionId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'الشعبة', prefixIcon: Icon(Icons.meeting_room)),
                items: _sections
                    .map((s) => DropdownMenuItem(
                          value: s['id'] as String,
                          child: Text(
                            '${s['stage_name']} / ${s['grade_name']} / ${s['name']}  (${s['student_count']} طالب)',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) _selectSection(v);
                },
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                hintText: 'ابحث بالاسم أو الرقم المدرسي (كل المدرسة)',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _search,
            ),
            if (_searching) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }

  Widget _studentTile(Student s) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
          child: Text(
            s.fullName.characters.first,
            style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(s.fullName, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('الرقم: ${s.studentNumber}'
            '${s.guardianPhone != null ? '  •  ولي الأمر: ${s.guardianPhone}' : ''}'),
        trailing: const Icon(Icons.chevron_left),
        onTap: () => _openProfile(s),
      ),
    );
  }
}
