import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/permissions.dart';
import '../../data/academic_repository.dart';
import '../../data/database.dart';
import '../../data/grade_repository.dart';
import '../../data/models.dart';
import '../../data/repositories.dart';

/// شاشة الدرجات والامتحانات: إنشاء امتحان، إدخال الدرجات، ومجاميع قابلة للضبط.
class GradesScreen extends StatefulWidget {
  const GradesScreen({super.key});

  @override
  State<GradesScreen> createState() => _GradesScreenState();
}

class _GradesScreenState extends State<GradesScreen> {
  final _repo = GradeRepository();
  bool _loading = true;
  List<Map<String, dynamic>> _sections = [];
  List<Map<String, dynamic>> _subjects = [];
  List<Map<String, dynamic>> _exams = [];
  String? _selectedSectionId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  String? get _schoolId => context.read<AppState>().schoolId;

  Future<String?> _currentYearId() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('academic_years',
        where: 'school_id = ? AND deleted_at IS NULL', whereArgs: [_schoolId], orderBy: 'is_current DESC, start_date DESC', limit: 1);
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  Future<void> _load() async {
    if (_schoolId == null) return;
    setState(() => _loading = true);
    final yearId = await _currentYearId();
    final acad = AcademicRepository();
    _sections = yearId != null ? await acad.sectionsWithNames(_schoolId!, yearId) : [];
    _subjects = await acad.subjects(_schoolId!);
    _selectedSectionId ??= _sections.isNotEmpty ? _sections.first['id'] as String : null;
    await _loadExams();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _loadExams() async {
    if (_selectedSectionId == null) {
      _exams = [];
      return;
    }
    final db = await AppDatabase.instance.database;
    _exams = await db.rawQuery('''
      SELECT e.id, e.exam_type, e.exam_date, e.max_score, e.pass_score, sub.name AS subject_name
      FROM exams e JOIN subjects sub ON sub.id = e.subject_id
      WHERE e.section_id = ? AND e.deleted_at IS NULL
      ORDER BY e.exam_date DESC
    ''', [_selectedSectionId]);
  }

  Future<void> _createExam() async {
    if (_selectedSectionId == null || _subjects.isEmpty) {
      _snack('تأكد من وجود شعبة ومادة');
      return;
    }
    final yearId = await _currentYearId();
    if (yearId == null) return;
    String subjectId = _subjects.first['id'] as String;
    final typeCtrl = TextEditingController(text: 'شهري');
    final maxCtrl = TextEditingController(text: '100');
    final passCtrl = TextEditingController(text: '50');
    DateTime date = DateTime.now();

    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        return AlertDialog(
          title: const Text('إنشاء امتحان'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                initialValue: subjectId,
                decoration: const InputDecoration(labelText: 'المادة'),
                items: _subjects.map((s) => DropdownMenuItem(value: s['id'] as String, child: Text(s['name'] as String))).toList(),
                onChanged: (v) => setDlg(() => subjectId = v!),
              ),
              const SizedBox(height: 10),
              TextField(controller: typeCtrl, decoration: const InputDecoration(labelText: 'نوع الامتحان')),
              const SizedBox(height: 10),
              TextField(controller: maxCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'الدرجة النهائية')),
              const SizedBox(height: 10),
              TextField(controller: passCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'درجة النجاح')),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text('${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}'),
                onPressed: () async {
                  final p = await showDatePicker(context: ctx, initialDate: date, firstDate: DateTime(2020), lastDate: DateTime(2100));
                  if (p != null) setDlg(() => date = p);
                },
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إنشاء')),
          ],
        );
      }),
    );
    if (ok != true) return;
    await _repo.createExam(
      subjectId: subjectId,
      sectionId: _selectedSectionId!,
      academicYearId: yearId,
      examType: typeCtrl.text.trim(),
      examDate: '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
      maxScore: double.tryParse(maxCtrl.text) ?? 100,
      passScore: double.tryParse(passCtrl.text),
    );
    await _load();
  }

  Future<void> _enterScores(Map<String, dynamic> exam) async {
    final state = context.read<AppState>();
    if (!state.can(Perms.gradeWrite)) {
      _snack('لا تملك صلاحية إدخال الدرجات');
      return;
    }
    final students = await StudentRepository().bySection(_selectedSectionId!);
    if (!mounted) return;
    if (students.isEmpty) {
      _snack('لا يوجد طلاب في هذه الشعبة');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _ScoreEntryScreen(exam: exam, students: students, repo: _repo, userId: state.user?['id'] as String?),
    ));
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الدرجات والامتحانات')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createExam,
        icon: const Icon(Icons.add),
        label: const Text('امتحان جديد'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              if (_sections.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedSectionId,
                    decoration: const InputDecoration(labelText: 'الشعبة', prefixIcon: Icon(Icons.meeting_room)),
                    items: _sections
                        .map((s) => DropdownMenuItem(
                            value: s['id'] as String, child: Text('${s['stage_name']} / ${s['grade_name']} / ${s['name']}')))
                        .toList(),
                    onChanged: (v) async {
                      setState(() => _selectedSectionId = v);
                      await _loadExams();
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              Expanded(
                child: _exams.isEmpty
                    ? const Center(child: Text('لا توجد امتحانات لهذه الشعبة'))
                    : ListView.builder(
                        itemCount: _exams.length,
                        itemBuilder: (ctx, i) {
                          final e = _exams[i];
                          return Card(
                            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            child: ListTile(
                              leading: const CircleAvatar(child: Icon(Icons.grade)),
                              title: Text('${e['subject_name']} — ${e['exam_type']}'),
                              subtitle: Text('التاريخ: ${e['exam_date'] ?? '-'}  •  النهائية: ${e['max_score']}'),
                              trailing: const Icon(Icons.chevron_left),
                              onTap: () => _enterScores(e),
                            ),
                          );
                        },
                      ),
              ),
            ]),
    );
  }
}

/// شاشة إدخال درجات طلاب شعبة لامتحان معيّن.
class _ScoreEntryScreen extends StatefulWidget {
  final Map<String, dynamic> exam;
  final List<Student> students;
  final GradeRepository repo;
  final String? userId;
  const _ScoreEntryScreen({required this.exam, required this.students, required this.repo, this.userId});

  @override
  State<_ScoreEntryScreen> createState() => _ScoreEntryScreenState();
}

class _ScoreEntryScreenState extends State<_ScoreEntryScreen> {
  final _controllers = <String, TextEditingController>{};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    for (final s in widget.students) {
      _controllers[s.id] = TextEditingController();
    }
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('exam_grades', columns: ['student_id', 'score'],
        where: 'exam_id = ? AND deleted_at IS NULL', whereArgs: [widget.exam['id']]);
    for (final r in rows) {
      final sid = r['student_id'] as String;
      final score = (r['score'] as num?)?.toString() ?? '';
      _controllers[sid]?.text = score;
    }
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    final max = (widget.exam['max_score'] as num).toDouble();
    setState(() => _saving = true);
    try {
      for (final s in widget.students) {
        final text = _controllers[s.id]!.text.trim();
        if (text.isEmpty) continue;
        final value = double.tryParse(text);
        if (value == null) throw StateError('قيمة غير صحيحة للطالب ${s.fullName}');
        if (value < 0 || value > max) throw StateError('درجة ${s.fullName} خارج النطاق (0-$max)');
        await widget.repo.setScore(
          examId: widget.exam['id'] as String,
          studentId: s.id,
          score: value,
          enteredBy: widget.userId ?? '',
          isCorrection: false,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ الدرجات')));
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final max = widget.exam['max_score'];
    return Scaffold(
      appBar: AppBar(title: Text('درجات ${widget.exam['subject_name']} — ${widget.exam['exam_type']}')),
      body: Column(children: [
        Expanded(
          child: ListView.builder(
            itemCount: widget.students.length,
            itemBuilder: (ctx, i) {
              final s = widget.students[i];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(children: [
                    Expanded(child: Text('${s.fullName}  (${s.studentNumber})')),
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: _controllers[s.id],
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textAlign: TextAlign.center,
                        decoration: InputDecoration(hintText: '0-$max', isDense: true),
                      ),
                    ),
                  ]),
                ),
              );
            },
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save),
              label: const Text('حفظ الدرجات'),
            ),
          ),
        ),
      ]),
    );
  }
}
