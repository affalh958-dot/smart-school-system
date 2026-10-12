import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/academic_repository.dart';
import '../../data/database.dart';

/// شاشة الهيكل المدرسي: المراحل والصفوف والشعب والمدرسون والمواد والتكليفات.
/// كل شيء يُدار من هنا دون تعديل الكود.
class AcademicScreen extends StatefulWidget {
  const AcademicScreen({super.key});

  @override
  State<AcademicScreen> createState() => _AcademicScreenState();
}

class _AcademicScreenState extends State<AcademicScreen> with SingleTickerProviderStateMixin {
  late TabController _tabs;
  final _repo = AcademicRepository();
  bool _loading = true;

  List<Map<String, dynamic>> _stages = [];
  String? _selectedStageId;
  List<Map<String, dynamic>> _grades = [];
  String? _selectedGradeId;
  List<Map<String, dynamic>> _sections = [];
  List<Map<String, dynamic>> _teachers = [];
  List<Map<String, dynamic>> _subjects = [];
  List<Map<String, dynamic>> _assignments = [];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  String? get _schoolId => context.read<AppState>().schoolId;

  Future<String?> _currentYearId() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('academic_years',
        where: 'school_id = ? AND deleted_at IS NULL', whereArgs: [_schoolId], orderBy: 'is_current DESC, start_date DESC', limit: 1);
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  Future<void> _loadAll() async {
    if (_schoolId == null) return;
    setState(() => _loading = true);
    _stages = await _repo.stages(_schoolId!);
    _selectedStageId = _stages.isNotEmpty ? _stages.first['id'] as String : null;
    _grades = _selectedStageId != null ? await _repo.grades(_selectedStageId!) : [];
    _selectedGradeId = _grades.isNotEmpty ? _grades.first['id'] as String : null;
    final yearId = await _currentYearId();
    _sections = yearId != null ? await _repo.sectionsWithNames(_schoolId!, yearId) : [];
    _teachers = await _repo.teachers(_schoolId!);
    _subjects = await _repo.subjects(_schoolId!);
    _assignments = yearId != null ? await _repo.assignments(_schoolId!, yearId) : [];
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _loadGrades() async {
    if (_selectedStageId == null) return;
    _grades = await _repo.grades(_selectedStageId!);
    _selectedGradeId = _grades.isNotEmpty ? _grades.first['id'] as String : null;
    if (mounted) setState(() {});
  }

  // ------------------------- حوارات الإضافة -------------------------
  Future<String?> _promptText(String title, String label, {String? hint}) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: label, hintText: hint),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حفظ')),
        ],
      ),
    );
    return ok == true && ctrl.text.trim().isNotEmpty ? ctrl.text.trim() : null;
  }

  Future<void> _addStage() async {
    final name = await _promptText('إضافة مرحلة', 'اسم المرحلة', hint: 'مثال: المرحلة الابتدائية');
    if (name == null) return;
    try {
      await _repo.addStage(schoolId: _schoolId!, name: name, order: _stages.length);
      await _loadAll();
    } catch (e) {
      _snack('تعذّر الإضافة: اسم المرحلة مستخدم مسبقاً');
    }
  }

  Future<void> _addGrade() async {
    if (_selectedStageId == null) {
      _snack('أضف مرحلة أولاً');
      return;
    }
    final name = await _promptText('إضافة صف', 'اسم الصف', hint: 'مثال: الأول');
    if (name == null) return;
    try {
      await _repo.addGrade(stageId: _selectedStageId!, name: name, order: _grades.length);
      await _loadGrades();
    } catch (e) {
      _snack('تعذّر الإضافة: اسم الصف مستخدم في هذه المرحلة');
    }
  }

  Future<void> _addSection() async {
    if (_selectedGradeId == null) {
      _snack('اختر صفاً أولاً');
      return;
    }
    final yearId = await _currentYearId();
    if (yearId == null) {
      _snack('لا توجد سنة دراسية');
      return;
    }
    final name = await _promptText('إضافة شعبة', 'اسم الشعبة', hint: 'مثال: أ');
    if (name == null) return;
    try {
      await _repo.addSection(gradeId: _selectedGradeId!, academicYearId: yearId, name: name);
      await _loadAll();
    } catch (e) {
      _snack('تعذّر الإضافة');
    }
  }

  Future<void> _addTeacher() async {
    final nameCtrl = TextEditingController();
    final noCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة مدرّس'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: noCtrl, decoration: const InputDecoration(labelText: 'الرقم الوظيفي')),
            const SizedBox(height: 10),
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'الاسم الكامل')),
            const SizedBox(height: 10),
            TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'الهاتف (اختياري)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حفظ')),
        ],
      ),
    );
    if (ok != true || nameCtrl.text.trim().isEmpty || noCtrl.text.trim().isEmpty) return;
    try {
      await _repo.addTeacher(
        schoolId: _schoolId!,
        employeeNo: noCtrl.text.trim(),
        fullName: nameCtrl.text.trim(),
        phone: phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
      );
      await _loadAll();
    } catch (e) {
      _snack('تعذّر الإضافة: الرقم الوظيفي مستخدم');
    }
  }

  Future<void> _addSubject() async {
    final name = await _promptText('إضافة مادة', 'اسم المادة', hint: 'مثال: الرياضيات');
    if (name == null) return;
    try {
      await _repo.addSubject(schoolId: _schoolId!, name: name);
      await _loadAll();
    } catch (e) {
      _snack('تعذّر الإضافة: المادة مستخدمة');
    }
  }

  Future<void> _assignTeacher() async {
    final yearId = await _currentYearId();
    if (yearId == null || _teachers.isEmpty || _subjects.isEmpty || _sections.isEmpty) {
      _snack('تأكد من وجود مدرّس، مادة، وشعبة');
      return;
    }
    String teacherId = _teachers.first['id'] as String;
    String subjectId = _subjects.first['id'] as String;
    String sectionId = _sections.first['id'] as String;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        return AlertDialog(
          title: const Text('تكليف مدرّس بمادة وشعبة'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              initialValue: teacherId,
              decoration: const InputDecoration(labelText: 'المدرّس'),
              items: _teachers.map((t) => DropdownMenuItem(value: t['id'] as String, child: Text(t['full_name'] as String))).toList(),
              onChanged: (v) => setDlg(() => teacherId = v!),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: subjectId,
              decoration: const InputDecoration(labelText: 'المادة'),
              items: _subjects.map((s) => DropdownMenuItem(value: s['id'] as String, child: Text(s['name'] as String))).toList(),
              onChanged: (v) => setDlg(() => subjectId = v!),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: sectionId,
              decoration: const InputDecoration(labelText: 'الشعبة'),
              items: _sections
                  .map((s) => DropdownMenuItem(value: s['id'] as String, child: Text('${s['stage_name']} / ${s['grade_name']} / ${s['name']}')))
                  .toList(),
              onChanged: (v) => setDlg(() => sectionId = v!),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تكليف')),
          ],
        );
      }),
    );
    if (ok != true) return;
    await _repo.assignTeacher(teacherId: teacherId, subjectId: subjectId, sectionId: sectionId, academicYearId: yearId);
    await _loadAll();
    _snack('تم التكليف');
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('الهيكل المدرسي'),
        bottom: TabBar(controller: _tabs, isScrollable: true, tabs: const [
          Tab(text: 'المراحل والصفوف'),
          Tab(text: 'الشعب'),
          Tab(text: 'المدرسون'),
          Tab(text: 'المواد'),
          Tab(text: 'التكليفات'),
        ]),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(controller: _tabs, children: [
              _stagesGradesTab(),
              _sectionsTab(),
              _teachersTab(),
              _subjectsTab(),
              _assignmentsTab(),
            ]),
    );
  }

  // ------------------------- تبويب المراحل والصفوف -------------------------
  Widget _stagesGradesTab() {
    return Row(children: [
      Expanded(
        child: Column(children: [
          _header('المراحل', _addStage),
          Expanded(
            child: _stages.isEmpty
                ? const _Empty('لا توجد مراحل')
                : ListView.builder(
                    itemCount: _stages.length,
                    itemBuilder: (ctx, i) {
                      final s = _stages[i];
                      final selected = s['id'] == _selectedStageId;
                      return ListTile(
                        selected: selected,
                        selectedTileColor: AppTheme.primary.withValues(alpha: 0.1),
                        leading: const Icon(Icons.layers),
                        title: Text(s['name'] as String),
                        onTap: () {
                          setState(() => _selectedStageId = s['id'] as String);
                          _loadGrades();
                        },
                      );
                    },
                  ),
          ),
        ]),
      ),
      const VerticalDivider(width: 1),
      Expanded(
        child: Column(children: [
          _header('الصفوف', _addGrade),
          Expanded(
            child: _grades.isEmpty
                ? const _Empty('لا توجد صفوف')
                : ListView.builder(
                    itemCount: _grades.length,
                    itemBuilder: (ctx, i) {
                      final g = _grades[i];
                      return ListTile(
                        selected: g['id'] == _selectedGradeId,
                        selectedTileColor: AppTheme.accent.withValues(alpha: 0.1),
                        leading: const Icon(Icons.class_),
                        title: Text(g['name'] as String),
                        onTap: () => setState(() => _selectedGradeId = g['id'] as String),
                      );
                    },
                  ),
          ),
        ]),
      ),
    ]);
  }

  Widget _header(String title, VoidCallback onAdd) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(children: [
        Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
        IconButton.filledTonal(onPressed: onAdd, icon: const Icon(Icons.add), tooltip: 'إضافة'),
      ]),
    );
  }

  // ------------------------- تبويب الشعب -------------------------
  Widget _sectionsTab() {
    return Column(children: [
      _header('الشعب الدراسية', _addSection),
      Expanded(
        child: _sections.isEmpty
            ? const _Empty('لا توجد شعب — اختر صفاً ثم أضف شعبة')
            : ListView.builder(
                itemCount: _sections.length,
                itemBuilder: (ctx, i) {
                  final s = _sections[i];
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.meeting_room)),
                      title: Text('${s['stage_name']} / ${s['grade_name']} / ${s['name']}'),
                      subtitle: Text('عدد الطلاب: ${s['student_count']}${s['capacity'] != null ? '  •  السعة: ${s['capacity']}' : ''}'),
                      trailing: IconButton(
                        tooltip: 'أرشفة الشعبة',
                        icon: const Icon(Icons.archive_outlined),
                        onPressed: () async {
                          final has = await _repo.sectionHasRecords(s['id'] as String);
                          if (has) {
                            _snack('لا يمكن حذف شعبة مرتبطة بطلاب');
                            return;
                          }
                          await _repo.archiveSection(s['id'] as String);
                          await _loadAll();
                        },
                      ),
                    ),
                  );
                },
              ),
      ),
    ]);
  }

  // ------------------------- تبويب المدرسين -------------------------
  Widget _teachersTab() {
    return Column(children: [
      _header('المدرسون', _addTeacher),
      Expanded(
        child: _teachers.isEmpty
            ? const _Empty('لا يوجد مدرسون')
            : ListView.builder(
                itemCount: _teachers.length,
                itemBuilder: (ctx, i) {
                  final t = _teachers[i];
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.person)),
                      title: Text(t['full_name'] as String),
                      subtitle: Text('الرقم الوظيفي: ${t['employee_no']}${t['phone'] != null ? '  •  ${t['phone']}' : ''}'),
                    ),
                  );
                },
              ),
      ),
    ]);
  }

  // ------------------------- تبويب المواد -------------------------
  Widget _subjectsTab() {
    return Column(children: [
      _header('المواد الدراسية', _addSubject),
      Expanded(
        child: _subjects.isEmpty
            ? const _Empty('لا توجد مواد')
            : ListView.builder(
                itemCount: _subjects.length,
                itemBuilder: (ctx, i) {
                  final s = _subjects[i];
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.menu_book)),
                      title: Text(s['name'] as String),
                    ),
                  );
                },
              ),
      ),
    ]);
  }

  // ------------------------- تبويب التكليفات -------------------------
  Widget _assignmentsTab() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: ElevatedButton.icon(
          onPressed: _assignTeacher,
          icon: const Icon(Icons.assignment_ind),
          label: const Text('تكليف مدرّس بمادة وشعبة'),
        ),
      ),
      Expanded(
        child: _assignments.isEmpty
            ? const _Empty('لا توجد تكليفات')
            : ListView.builder(
                itemCount: _assignments.length,
                itemBuilder: (ctx, i) {
                  final a = _assignments[i];
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.link)),
                      title: Text('${a['teacher_name']} — ${a['subject_name']}'),
                      subtitle: Text('الشعبة: ${a['section_name']}'),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.inbox, size: 48, color: AppTheme.textMuted),
          const SizedBox(height: 8),
          Text(text, style: const TextStyle(color: AppTheme.textMuted)),
        ]),
      );
}
