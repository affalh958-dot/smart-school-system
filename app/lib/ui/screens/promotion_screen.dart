import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../data/academic_repository.dart';
import '../../data/database.dart';
import '../../data/repositories.dart';

/// ترحيل نهاية السنة: اختيار الشعبة الحالية، ثم لكل طالب تحديد «نجح → شعبة جديدة»
/// أو «راسب → البقاء في مكانه». يعمل كمعاملة واحدة ويوثّق الحركات.
class PromotionScreen extends StatefulWidget {
  const PromotionScreen({super.key});

  @override
  State<PromotionScreen> createState() => _PromotionScreenState();
}

class _PromotionScreenState extends State<PromotionScreen> {
  final _acad = AcademicRepository();
  final _students = StudentRepository();

  bool _loading = true;
  List<Map<String, dynamic>> _sections = [];
  String? _fromSectionId;
  String? _defaultTargetSectionId;
  String? _yearId;

  List<Map<String, dynamic>> _studentsList = [];
  // studentId -> 'promote' | 'repeat' | 'skip'
  final Map<String, String> _decisions = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    final schoolId = context.read<AppState>().schoolId;
    if (schoolId == null) {
      setState(() => _loading = false);
      return;
    }
    final rows = await (await AppDatabase.instance.database).query('academic_years',
        where: 'school_id = ? AND deleted_at IS NULL',
        whereArgs: [schoolId],
        orderBy: 'is_current DESC, start_date DESC',
        limit: 1);
    _yearId = rows.isEmpty ? null : rows.first['id'] as String;
    final sections = _yearId == null ? <Map<String, dynamic>>[] : await _acad.sectionsWithNames(schoolId, _yearId!);
    setState(() {
      _sections = sections;
      _fromSectionId = sections.isNotEmpty ? sections.first['id'] as String : null;
      _loading = false;
    });
    if (_fromSectionId != null) await _loadStudents();
  }

  Future<void> _loadStudents() async {
    if (_fromSectionId == null) return;
    setState(() => _loading = true);
    final list = await _students.activeBySection(_fromSectionId!);
    _decisions.clear();
    for (final s in list) {
      _decisions[s['id'] as String] = 'promote';
    }
    if (!mounted) return;
    setState(() {
      _studentsList = list;
      _loading = false;
    });
  }

  Future<void> _apply() async {
    final state = context.read<AppState>();
    final schoolId = state.schoolId;
    if (schoolId == null || _yearId == null || _fromSectionId == null) return;
    final movedToRepeat = _decisions.entries.where((e) => e.value == 'repeat').length;
    final toPromote = _decisions.entries.where((e) => e.value == 'promote').toList();
    if (toPromote.isNotEmpty && _defaultTargetSectionId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('اختر الشعبة الهدف للطلاب الناجحين أولاً')));
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد الترحيل'),
        content: Text('سيُنقل ${toPromote.length} طالباً ناجحاً إلى الشعبة المحدّدة، '
            'ويبقى $movedToRepeat طالباً راسباً في مكانه. هل أنت متأكد؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تنفيذ')),
        ],
      ),
    );
    if (confirm != true) return;

    final moves = <String, String>{};
    for (final s in _studentsList) {
      final sid = s['id'] as String;
      final target = _decisions[sid];
      if (target == 'promote') {
        moves[sid] = _defaultTargetSectionId!;
      } else {
        moves[sid] = _fromSectionId!; // البقاء مكانه (يُسجّل حركة توثيق فقط)
      }
    }
    await _students.promoteForNewYear(
      schoolId: schoolId,
      newAcademicYearId: _yearId!,
      moves: moves,
      movedBy: state.user?['id'] as String?,
      reason: 'ترحيل نهاية السنة: ${toPromote.length} ناجح / $movedToRepeat راسب',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('تم الترحيل: ${toPromote.length} ناجح، $movedToRepeat راسب بقي في مكانه')));
    await _loadStudents();
  }

  String _sectionLabel(Map<String, dynamic> s) =>
      '${s['stage_name'] ?? ''} / ${s['grade_name'] ?? ''} / ${s['name']}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ترحيل نهاية السنة')),
      floatingActionButton: _studentsList.isEmpty
          ? null
          : FloatingActionButton.extended(onPressed: _apply, icon: const Icon(Icons.done_all), label: const Text('تنفيذ')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  DropdownButtonFormField<String>(
                    initialValue: _fromSectionId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'الشعبة الحالية'),
                    items: _sections
                        .map((s) => DropdownMenuItem(value: s['id'] as String, child: Text(_sectionLabel(s))))
                        .toList(),
                    onChanged: (v) {
                      setState(() => _fromSectionId = v);
                      _loadStudents();
                    },
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _defaultTargetSectionId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'الشعبة الهدف (للناجحين)'),
                    items: _sections
                        .map((s) => DropdownMenuItem(value: s['id'] as String, child: Text(_sectionLabel(s))))
                        .toList(),
                    onChanged: (v) => setState(() => _defaultTargetSectionId = v),
                  ),
                ]),
              ),
              const Divider(height: 1),
              Expanded(
                child: _studentsList.isEmpty
                    ? const Center(child: Text('لا يوجد طلاب نشطون في هذه الشعبة'))
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 90),
                        itemCount: _studentsList.length,
                        itemBuilder: (ctx, i) {
                          final s = _studentsList[i];
                          final sid = s['id'] as String;
                          final d = _decisions[sid] ?? 'promote';
                          return Card(
                            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            child: ListTile(
                              title: Text(s['full_name'] as String),
                              subtitle: Text('${s['student_number']}'),
                              trailing: SegmentedButton<String>(
                                segments: const [
                                  ButtonSegment(value: 'promote', label: Text('ناجح'), icon: Icon(Icons.arrow_upward)),
                                  ButtonSegment(value: 'repeat', label: Text('راسب'), icon: Icon(Icons.replay)),
                                ],
                                selected: {d},
                                onSelectionChanged: (v) => setState(() => _decisions[sid] = v.first),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ]),
    );
  }
}
