import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/academic_repository.dart';
import '../../data/database.dart';
import 'students_screen.dart';
import 'face_enroll_screen.dart';

/// شاشة «الصفوف» — كل صف بطاقة؛ عند الضغط تُعرض شعبه، ولكل شعبة طلابها.
/// تُبرز عدد الطلاب وعدد المسجّلين ببصمة الوجه، مع أزرار سريعة للطلاب والوجوه.
class ClassesScreen extends StatefulWidget {
  const ClassesScreen({super.key});

  @override
  State<ClassesScreen> createState() => _ClassesScreenState();
}

class _ClassesScreenState extends State<ClassesScreen> {
  final _acad = AcademicRepository();
  List<Map<String, dynamic>> _sections = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  String? get _schoolId => context.read<AppState>().schoolId;

  Future<String?> _yearId() async {
    final schoolId = _schoolId;
    if (schoolId == null) return null;
    final rows = await (await AppDatabase.instance.database).query('academic_years',
        where: 'school_id = ? AND deleted_at IS NULL',
        whereArgs: [schoolId],
        orderBy: 'is_current DESC, start_date DESC',
        limit: 1);
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  Future<void> _load() async {
    final schoolId = _schoolId;
    if (schoolId == null) return;
    final yearId = await _yearId();
    final sections = yearId == null ? <Map<String, dynamic>>[] : await _acad.sectionsWithNames(schoolId, yearId);
    if (!mounted) return;
    setState(() {
      _sections = sections;
      _loading = false;
    });
  }

  Map<String, List<Map<String, dynamic>>> get _byGrade {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final s in _sections) {
      final key = '${s['stage_name']} / ${s['grade_name']}';
      map.putIfAbsent(key, () => []).add(s);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الصفوف والشعب')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sections.isEmpty
              ? const Center(child: Text('لا توجد صفوف/شعب بعد. أنشئها من «الهيكل المدرسي».'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: _byGrade.entries
                        .map((e) => _gradeCard(e.key, e.value))
                        .toList(),
                  ),
                ),
    );
  }

  Widget _gradeCard(String gradeName, List<Map<String, dynamic>> sections) {
    final totalStudents = sections.fold<int>(0, (a, s) => a + ((s['student_count'] as int?) ?? 0));
    return Card(
      child: ExpansionTile(
        initiallyExpanded: true,
        leading: const CircleAvatar(backgroundColor: AppTheme.primary, child: Icon(Icons.school, color: Colors.white)),
        title: Text(gradeName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        subtitle: Text('${sections.length} شعبة  •  $totalStudents طالب'),
        children: sections.map(_sectionTile).toList(),
      ),
    );
  }

  Widget _sectionTile(Map<String, dynamic> sec) {
    final count = (sec['student_count'] as int?) ?? 0;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.meeting_room, color: AppTheme.accent),
      title: Text('شعبة ${sec['name']}'),
      subtitle: Text('$count طالب'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: 'الطلاب',
          icon: const Icon(Icons.people, color: AppTheme.primary),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const StudentsScreen()),
          ),
        ),
        IconButton(
          tooltip: 'تسجيل الوجوه',
          icon: const Icon(Icons.face_retouching_natural, color: AppTheme.accent),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => FaceEnrollScreen(initialSectionId: sec['id'] as String)),
          ),
        ),
      ]),
    );
  }
}
