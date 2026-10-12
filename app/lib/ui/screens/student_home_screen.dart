import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/database.dart';
import '../../data/evaluation_repository.dart';
import '../../data/repositories.dart';

/// بوابة الطالب: عرض ملفه الشخصي وتقييماته الأسبوعية التراكمية فقط (قراءة).
/// لا يمكنه تعديل أي شيء ولا رؤية بيانات طالب آخر.
class StudentHomeScreen extends StatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  State<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends State<StudentHomeScreen> {
  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>> _cumulative = [];
  double? _overall;
  String _className = '-';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final studentId = state.studentId;
    if (studentId == null) {
      setState(() => _loading = false);
      return;
    }
    final profile = await StudentRepository().fullProfile(studentId);
    final yearId = await _yearId(state.schoolId);
    final cumulative = await EvaluationRepository().cumulativeBySubject(studentId, yearId);
    final overall = await EvaluationRepository().overallAverage(studentId, yearId);
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _cumulative = cumulative;
      _overall = overall;
      _className = profile == null
          ? '-'
          : '${profile['stage_name'] ?? ''} / ${profile['grade_name'] ?? ''} / ${profile['section_name'] ?? ''}';
      _loading = false;
    });
  }

  Future<String?> _yearId(String? schoolId) async {
    if (schoolId == null) return null;
    final rows = await (await AppDatabase.instance.database).query('academic_years',
        where: 'school_id = ? AND deleted_at IS NULL',
        whereArgs: [schoolId],
        orderBy: 'is_current DESC, start_date DESC',
        limit: 1);
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('بوابة الطالب'),
        actions: [
          IconButton(
            tooltip: 'خروج',
            icon: const Icon(Icons.logout),
            onPressed: () {
              state.logout();
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _profile == null
              ? const Center(
                  child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('لم يتم ربط حسابك بأي ملف طالب. يرجى مراجعة إدارة المدرسة.',
                      textAlign: TextAlign.center),
                ))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(children: [
                          CircleAvatar(
                            radius: 40,
                            backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
                            child: Text(
                              (_profile!['full_name'] as String).characters.first,
                              style: const TextStyle(
                                  fontSize: 32, fontWeight: FontWeight.bold, color: AppTheme.primary),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(_profile!['full_name'] as String,
                              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                          Text('الرقم المدرسي: ${_profile!['student_number']}',
                              style: const TextStyle(color: AppTheme.textMuted)),
                          const SizedBox(height: 4),
                          Text(_className, style: const TextStyle(color: AppTheme.primary)),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            const Icon(Icons.insights, color: AppTheme.primary),
                            const SizedBox(width: 8),
                            const Text('تقييمي الأسبوعي التراكمي',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            const Spacer(),
                            if (_overall != null)
                              Text('${_overall!.toStringAsFixed(1)}%',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold, color: AppTheme.success)),
                          ]),
                          const Divider(),
                          if (_cumulative.isEmpty)
                            const Text('لا توجد تقييمات مسجّلة بعد',
                                style: TextStyle(color: AppTheme.textMuted)),
                          ..._cumulative.map((c) {
                            final avg = c['weighted_avg'];
                            final max = c['max_score'] ?? 10;
                            final val = avg == null ? '-' : '${(avg as num).toStringAsFixed(1)} / $max';
                            final passed = avg != null && (avg as num) >= (max as num) * 0.5;
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(children: [
                                Expanded(child: Text('${c['subject_name']}')),
                                Text('${c['weeks']} أسبوع',
                                    style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                                const SizedBox(width: 10),
                                Text(val,
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: passed ? AppTheme.success : AppTheme.danger)),
                              ]),
                            );
                          }),
                        ]),
                      ),
                    ),
                  ],
                ),
    );
  }
}
