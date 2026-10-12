import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/database.dart';
import '../../data/evaluation_repository.dart';
import '../../data/repositories.dart';

/// بوابة ولي الأمر — عرض قراءة فقط: ملف الطالب المرتبط، حضور آخر ٣٠ يوم، والدرجات والتقييمات.
/// لا يستطيع الوصول إلى أي طالب آخر ولا تعديل أي بيانات.
class GuardianHomeScreen extends StatefulWidget {
  const GuardianHomeScreen({super.key});

  @override
  State<GuardianHomeScreen> createState() => _GuardianHomeScreenState();
}

class _GuardianHomeScreenState extends State<GuardianHomeScreen> {
  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>> _attendance = [];
  List<Map<String, dynamic>> _cumulative = [];
  double? _overall;
  int _present = 0, _late = 0, _absent = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final studentId = state.studentId ?? state.linkedStudentId;
    if (studentId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final profile = await StudentRepository().fullProfile(studentId);
    final yearId = await _yearId(state.schoolId);
    final cumulative = await EvaluationRepository().cumulativeBySubject(studentId, yearId);
    final overall = await EvaluationRepository().overallAverage(studentId, yearId);
    final attendance = await _recentAttendance(studentId);
    if (!mounted) return;
    var present = 0, late = 0, absent = 0;
    for (final a in attendance) {
      switch (a['status']) {
        case 'present':
          present++;
        case 'late':
          late++;
        case 'absent':
          absent++;
      }
    }
    setState(() {
      _profile = profile;
      _cumulative = cumulative;
      _overall = overall;
      _attendance = attendance;
      _present = present;
      _late = late;
      _absent = absent;
      _loading = false;
    });
  }

  Future<List<Map<String, dynamic>>> _recentAttendance(String studentId) async {
    final db = await AppDatabase.instance.database;
    return db.rawQuery('''
      SELECT session_date, session_type, status, recorded_at
      FROM attendance_records
      WHERE student_id = ? AND deleted_at IS NULL
      ORDER BY session_date DESC, recorded_at DESC
      LIMIT 40
    ''', [studentId]);
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

  String _statusAr(String s) => const {
        'present': 'حاضر',
        'late': 'متأخر',
        'absent': 'غائب',
        'excused': 'غياب بعذر',
        'early_leave': 'انصراف مبكر',
      }[s] ?? s;

  Color _statusColor(String s) {
    switch (s) {
      case 'present':
        return AppTheme.success;
      case 'late':
      case 'early_leave':
        return AppTheme.warning;
      case 'absent':
        return AppTheme.danger;
      default:
        return AppTheme.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('بوابة ولي الأمر'),
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
                  child: Text('لم يتم ربط حسابك بأي طالب. يرجى مراجعة إدارة المدرسة.', textAlign: TextAlign.center),
                ))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(children: [
                          CircleAvatar(
                            radius: 32,
                            backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
                            child: const Icon(Icons.family_restroom, color: AppTheme.primary, size: 32),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(_profile!['full_name'] as String,
                                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
                              Text('الرقم المدرسي: ${_profile!['student_number']}',
                                  style: const TextStyle(color: AppTheme.textMuted)),
                              Text(
                                  '${_profile!['grade_name'] ?? ''} / ${_profile!['section_name'] ?? ''}',
                                  style: const TextStyle(color: AppTheme.primary)),
                            ]),
                          ),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: _stat('حضور', '$_present', AppTheme.success)),
                      const SizedBox(width: 8),
                      Expanded(child: _stat('تأخير', '$_late', AppTheme.warning)),
                      const SizedBox(width: 8),
                      Expanded(child: _stat('غياب', '$_absent', AppTheme.danger)),
                    ]),
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            const Icon(Icons.insights, color: AppTheme.primary),
                            const SizedBox(width: 8),
                            const Text('التقييم الأسبوعي التراكمي',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            const Spacer(),
                            if (_overall != null)
                              Text('${_overall!.toStringAsFixed(1)}%',
                                  style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.success)),
                          ]),
                          const Divider(),
                          if (_cumulative.isEmpty)
                            const Text('لا توجد تقييمات مسجّلة بعد', style: TextStyle(color: AppTheme.textMuted)),
                          ..._cumulative.map((c) {
                            final avg = c['weighted_avg'];
                            final max = c['max_score'] ?? 10;
                            final val = avg == null ? '-' : '${(avg as num).toStringAsFixed(1)} / $max';
                            final passed = avg != null && (avg as num) >= (max as num) * 0.5;
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(children: [
                                Expanded(child: Text('${c['subject_name']}')),
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
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Row(children: [
                            Icon(Icons.event_note, color: AppTheme.primary),
                            SizedBox(width: 8),
                            Text('سجل الحضور الأخير', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          ]),
                          const Divider(),
                          if (_attendance.isEmpty)
                            const Text('لا توجد سجلات حضور', style: TextStyle(color: AppTheme.textMuted)),
                          ..._attendance.take(15).map((a) => Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: Row(children: [
                                  Expanded(child: Text('${a['session_date']}')),
                                  Text(a['session_type'] == 'checkout' ? 'انصراف' : 'حضور',
                                      style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                                  const SizedBox(width: 10),
                                  Text(_statusAr(a['status'] as String),
                                      style: TextStyle(fontWeight: FontWeight.bold, color: _statusColor(a['status'] as String))),
                                ]),
                              )),
                        ]),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _stat(String label, String value, Color color) => Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
          Text(label, style: const TextStyle(color: AppTheme.textMuted)),
        ]),
      );
}
