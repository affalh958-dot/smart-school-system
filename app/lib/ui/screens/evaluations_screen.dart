import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../core/whatsapp_helper.dart';
import '../../data/academic_repository.dart';
import '../../data/database.dart';
import '../../data/evaluation_repository.dart';
import '../../data/repositories.dart';

/// شاشة التقييم الأسبوعي التراكمي.
/// يختار المعلم/المدير الشعبة والمادة والأسبوع، ثم يُدخل تقييم كل طالب (0..10)
/// مع ملاحظة اختيارية. تُحتسب النسبة التراكمية لكل طالب وتظهر فوراً،
/// مع زر إرسال تقييم جاهز على واتساب لولي الأمر.
class EvaluationsScreen extends StatefulWidget {
  const EvaluationsScreen({super.key, this.initialSectionId});
  final String? initialSectionId;

  @override
  State<EvaluationsScreen> createState() => _EvaluationsScreenState();
}

class _EvaluationsScreenState extends State<EvaluationsScreen> {
  final _eval = EvaluationRepository();
  final _acad = AcademicRepository();
  final _students = StudentRepository();

  bool _loading = true;
  List<Map<String, dynamic>> _sections = [];
  List<Map<String, dynamic>> _subjects = [];
  String? _sectionId;
  String? _subjectId;
  int _week = 1;
  String? _yearId;

  List<Map<String, dynamic>> _rows = [];
  Map<String, TextEditingController> _scoreCtrls = {};
  Map<String, TextEditingController> _commentCtrls = {};
  Map<String, double?> _cumulative = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    for (final c in _scoreCtrls.values) {
      c.dispose();
    }
    for (final c in _commentCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<String?> _currentYear(String schoolId) async {
    final rows = await (await AppDatabase.instance.database).query('academic_years',
        where: 'school_id = ? AND deleted_at IS NULL',
        whereArgs: [schoolId],
        orderBy: 'is_current DESC, start_date DESC',
        limit: 1);
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  Future<String?> _teacherIdOf(String? userId) async {
    if (userId == null) return null;
    final db = await AppDatabase.instance.database;
    final rows = await db.query('users', columns: ['teacher_id'], where: 'id = ?', whereArgs: [userId], limit: 1);
    return rows.isEmpty ? null : rows.first['teacher_id'] as String?;
  }

  Future<void> _boot() async {
    final state = context.read<AppState>();
    final schoolId = state.schoolId;
    if (schoolId == null) {
      setState(() => _loading = false);
      return;
    }
    _yearId = await _currentYear(schoolId);
    final teacherId = await _teacherIdOf(state.user?['id'] as String?);
    List<Map<String, dynamic>> sections;
    // تقييد المعلم: الشعب المكلّف بها فقط (المدير/المالك: كل الشعب).
    final restrictToTeacher = teacherId != null && !state.can(Perms.userManage);
    if (restrictToTeacher && _yearId != null) {
      sections = await _acad.sectionsForTeacher(teacherId, _yearId!);
    } else if (_yearId != null) {
      sections = await _acad.sectionsWithNames(schoolId, _yearId!);
    } else {
      sections = [];
    }
    final subjects = await _acad.subjects(schoolId);
    final initial = widget.initialSectionId ??
        (sections.isNotEmpty ? sections.first['id'] as String : null);
    setState(() {
      _sections = sections;
      _subjects = subjects;
      _sectionId = initial;
      _subjectId = subjects.isNotEmpty ? subjects.first['id'] as String : null;
      _loading = false;
    });
    if (_sectionId != null && _subjectId != null) await _loadRows();
  }

  Future<void> _loadSubjectsForSection() async {
    final state = context.read<AppState>();
    final teacherId = await _teacherIdOf(state.user?['id'] as String?);
    if (teacherId != null && !state.can(Perms.userManage) && _sectionId != null && _yearId != null) {
      final subs = await _acad.subjectsForTeacher(teacherId, _sectionId!, _yearId!);
      if (subs.isNotEmpty) {
        setState(() {
          _subjects = subs;
          _subjectId = subs.first['id'] as String;
        });
      }
    }
  }

  Future<void> _loadRows() async {
    if (_sectionId == null || _subjectId == null) return;
    setState(() => _loading = true);
    final rows = await _eval.sectionSubjectWeek(_sectionId!, _subjectId!, _week, _yearId);
    for (final c in _scoreCtrls.values) {
      c.dispose();
    }
    for (final c in _commentCtrls.values) {
      c.dispose();
    }
    _scoreCtrls = {};
    _commentCtrls = {};
    final cumulative = <String, double?>{};
    for (final r in rows) {
      final sid = r['student_id'] as String;
      final score = r['score'];
      _scoreCtrls[sid] = TextEditingController(text: score == null ? '' : '$score');
      _commentCtrls[sid] = TextEditingController(text: '${r['comment'] ?? ''}');
      cumulative[sid] = await _eval.overallAverage(sid, _yearId);
    }
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _cumulative = cumulative;
      _loading = false;
    });
  }

  Future<void> _saveAll() async {
    final state = context.read<AppState>();
    final schoolId = state.schoolId;
    if (schoolId == null || _sectionId == null || _subjectId == null) return;
    final teacherId = await _teacherIdOf(state.user?['id'] as String?);
    var saved = 0;
    var invalid = 0;
    for (final r in _rows) {
      final sid = r['student_id'] as String;
      final raw = _scoreCtrls[sid]!.text.trim();
      if (raw.isEmpty) continue;
      final value = double.tryParse(raw);
      if (value == null || value < 0 || value > 10) {
        invalid++;
        continue;
      }
      await _eval.setEvaluation(
        schoolId: schoolId,
        studentId: sid,
        subjectId: _subjectId!,
        sectionId: _sectionId,
        academicYearId: _yearId,
        teacherId: teacherId,
        weekNo: _week,
        score: value,
        maxScore: 10,
        comment: _commentCtrls[sid]!.text.trim().isEmpty ? null : _commentCtrls[sid]!.text.trim(),
        evaluatedBy: state.user?['id'] as String?,
      );
      saved++;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('تم حفظ $saved تقييماً${invalid > 0 ? ' — $invalid قيمة غير صحيحة تجاهُل' : ''}')));
    await _loadRows();
  }

  Future<void> _sendWhatsapp(Map<String, dynamic> row) async {
    final sid = row['student_id'] as String;
    final schoolName = context.read<AppState>().schoolName;
    final all = await _eval.cumulativeBySubject(sid, _yearId);
    final overall = await _eval.overallAverage(sid, _yearId);
    final profile = await _students.fullProfile(sid);
    final phone = (profile?['guardian_phone'] ?? profile?['student_phone'] ?? '').toString();
    if (phone.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('لا يوجد رقم هاتف مسجّل لهذا الطالب')));
      return;
    }
    final className = '${profile?['stage_name'] ?? ''} / ${profile?['grade_name'] ?? ''} / ${profile?['section_name'] ?? ''}';
    final msg = WhatsappHelper.evaluationMessage(
      schoolName: schoolName,
      studentName: row['full_name'] as String,
      className: className,
      subjects: all,
      overall: overall,
    );
    final ok = await WhatsappHelper.send(phone: phone, message: msg);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('تعذّر فتح واتساب — تحقق من الرقم')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('التقييم الأسبوعي'),
        actions: [
          if (_rows.isNotEmpty)
            IconButton(
              tooltip: 'حفظ الكل',
              icon: const Icon(Icons.save),
              onPressed: _saveAll,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _filters(),
                const Divider(height: 1),
                Expanded(child: _rows.isEmpty ? _empty() : _list()),
              ],
            ),
      floatingActionButton: _rows.isEmpty
          ? null
          : FloatingActionButton.extended(onPressed: _saveAll, icon: const Icon(Icons.save), label: const Text('حفظ')),
    );
  }

  Widget _filters() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _sectionId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'الشعبة'),
              items: _sections
                  .map((s) => DropdownMenuItem(
                      value: s['id'] as String,
                      child: Text('${s['stage_name'] ?? ''} / ${s['grade_name'] ?? ''} / ${s['name']}')))
                  .toList(),
              onChanged: (v) async {
                setState(() => _sectionId = v);
                await _loadSubjectsForSection();
                await _loadRows();
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _subjectId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'المادة'),
              items: _subjects
                  .map((s) => DropdownMenuItem(value: s['id'] as String, child: Text('${s['name']}')))
                  .toList(),
              onChanged: (v) {
                setState(() => _subjectId = v);
                _loadRows();
              },
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          const Text('الأسبوع: ', style: TextStyle(fontWeight: FontWeight.bold)),
          IconButton(
              onPressed: _week > 1 ? () { setState(() => _week--); _loadRows(); } : null,
              icon: const Icon(Icons.remove_circle_outline)),
          Text('$_week', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          IconButton(
              onPressed: _week < 40 ? () { setState(() => _week++); _loadRows(); } : null,
              icon: const Icon(Icons.add_circle_outline)),
        ]),
      ]),
    );
  }

  Widget _empty() => const Center(child: Text('لا يوجد طلاب في هذه الشعبة'));

  Widget _list() {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 90),
      itemCount: _rows.length,
      itemBuilder: (ctx, i) {
        final r = _rows[i];
        final sid = r['student_id'] as String;
        final cum = _cumulative[sid];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              Expanded(
                flex: 3,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r['full_name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('${r['student_number']}', style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                  if (cum != null)
                    Text('تراكمي: ${cum.toStringAsFixed(1)}%',
                        style: const TextStyle(fontSize: 12, color: AppTheme.success, fontWeight: FontWeight.bold)),
                ]),
              ),
              SizedBox(
                width: 62,
                child: TextField(
                  controller: _scoreCtrls[sid],
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(hintText: '0-10', isDense: true, border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _commentCtrls[sid],
                  decoration: const InputDecoration(hintText: 'ملاحظة', isDense: true, border: OutlineInputBorder()),
                ),
              ),
              IconButton(
                tooltip: 'إرسال التقييم على واتساب',
                icon: const Icon(Icons.chat, color: AppTheme.success),
                onPressed: () => _sendWhatsapp(r),
              ),
            ]),
          ),
        );
      },
    );
  }
}
