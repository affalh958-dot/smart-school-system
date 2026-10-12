import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../data/attendance_repository.dart';
import '../../data/database.dart';
import '../../data/repositories.dart';
import '../widgets/app_tile.dart';
import 'attendance_screen.dart';
import 'audit_screen.dart';
import 'backup_screen.dart';
import 'academic_screen.dart';
import 'classes_screen.dart';
import 'evaluations_screen.dart';
import 'face_enroll_screen.dart';
import 'grades_screen.dart';
import 'login_screen.dart';
import 'promotion_screen.dart';
import 'reports_screen.dart';
import 'settings_screen.dart';
import 'student_columns_screen.dart';
import 'students_screen.dart';
import 'users_screen.dart';

/// لوحة التحكم الرئيسية — شبكة مربّعات أنيقة حسب دور المستخدم وصلاحياته.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Map<String, int> _stats = {};
  int _totalStudents = 0;
  int _pending = 0;
  String _today = '';
  List<Map<String, dynamic>> _recentToday = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    try {
      final today = DateTime.now();
      final date = '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      final att = AttendanceRepository();
      final stats = await att.dailyStats(date, schoolId: state.schoolId);
      final pending = await att.pendingReviews(schoolId: state.schoolId);
      var total = 0;
      if (state.schoolId != null) {
        total = await StudentRepository().countAll(state.schoolId!);
      }
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _pending = pending;
        _totalStudents = total;
        _today = date;
      });
      await _loadRecent(date);
    } catch (_) {
      // نتجاهل أخطاء التحميل الأولي ولا نعطّل اللوحة
    }
  }

  Future<void> _loadRecent(String date) async {
    final state = context.read<AppState>();
    try {
      final db = await AppDatabase.instance.database;
      final rows = state.schoolId == null
          ? await db.rawQuery('''
              SELECT ar.recorded_at, ar.status, s.full_name, s.student_number
              FROM attendance_records ar JOIN students s ON s.id = ar.student_id
              WHERE ar.session_date = ? AND ar.deleted_at IS NULL
              ORDER BY ar.recorded_at DESC LIMIT 8
            ''', [date])
          : await db.rawQuery('''
              SELECT ar.recorded_at, ar.status, s.full_name, s.student_number
              FROM attendance_records ar JOIN students s ON s.id = ar.student_id
              WHERE ar.session_date = ? AND ar.deleted_at IS NULL AND s.school_id = ?
              ORDER BY ar.recorded_at DESC LIMIT 8
            ''', [date, state.schoolId]);
      if (!mounted) return;
      setState(() => _recentToday = rows);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tiles = _tilesFor(state);

    return Scaffold(
      appBar: AppBar(
        title: Text(state.schoolName.isEmpty ? 'لوحة التحكم' : state.schoolName),
        actions: [
          IconButton(
            tooltip: 'تسجيل الخروج',
            icon: const Icon(Icons.logout),
            onPressed: () {
              state.logout();
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
              );
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _welcomeCard(state),
            const SizedBox(height: 16),
            _statsGrid(),
            const SizedBox(height: 20),
            const Text('الوظائف المتاحة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            AppTileGrid(tiles: tiles),
            const SizedBox(height: 20),
            if (_recentToday.isNotEmpty) _recentCard(),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _welcomeCard(AppState state) {
    final name = state.user?['full_name'] ?? '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const CircleAvatar(radius: 26, backgroundColor: AppTheme.primary, child: Icon(Icons.person, color: Colors.white)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('مرحباً، $name', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(Roles.labels[state.primaryRole] ?? '', style: const TextStyle(color: AppTheme.textMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statsGrid() {
    final present = _stats['present'] ?? 0;
    final late = _stats['late'] ?? 0;
    final absent = _stats['absent'] ?? 0;
    final notRecorded = (_totalStudents - present - late - absent).clamp(0, _totalStudents);
    final rate = _totalStudents == 0 ? 0 : ((present + late) * 100 / _totalStudents).round();
    final cards = [
      _statCard('إجمالي الطلاب', '$_totalStudents', Icons.groups, AppTheme.accent),
      _statCard('الحاضرون اليوم', '$present', Icons.check_circle, AppTheme.success),
      _statCard('المتأخرون', '$late', Icons.schedule, AppTheme.warning),
      _statCard('الغائبون', '$absent', Icons.cancel, AppTheme.danger),
      _statCard('لم يسجّلوا بعد', '$notRecorded', Icons.hourglass_empty, AppTheme.textMuted),
      _statCard('تحتاج مراجعة', '$_pending', Icons.flag, AppTheme.warning),
      _statCard('نسبة الحضور', '$rate%', Icons.percent, AppTheme.primary),
      _statCard('التاريخ', _today, Icons.calendar_today, AppTheme.textMuted),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.1,
      children: cards,
    );
  }

  Widget _recentCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.recent_actors, color: AppTheme.primary, size: 20),
              SizedBox(width: 8),
              Text('آخر عمليات التسجيل اليوم', style: TextStyle(fontWeight: FontWeight.bold)),
            ]),
            const Divider(),
            ..._recentToday.map((r) {
              final status = r['status'] as String;
              final color = status == 'late'
                  ? AppTheme.warning
                  : status == 'absent'
                      ? AppTheme.danger
                      : AppTheme.success;
              final label = status == 'late' ? 'متأخر' : status == 'absent' ? 'غائب' : 'حاضر';
              return ListTile(
                dense: true,
                leading: Icon(Icons.person, color: color, size: 20),
                title: Text('${r['full_name']} (${r['student_number']})'),
                trailing: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _statCard(String title, String value, IconData icon, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(icon, color: color, size: 30),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
                  Text(title, style: const TextStyle(fontSize: 13, color: AppTheme.textMuted), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _tilesFor(AppState state) {
    final list = <Widget>[];
    void add(String title, String subtitle, IconData icon, Color color, VoidCallback onTap) =>
        list.add(AppTile(title: title, subtitle: subtitle, icon: icon, color: color, onTap: onTap));

    if (state.can(Perms.attendanceScreen)) {
      add('شاشة الحضور', 'تسجيل الحضور بالكاميرا تلقائياً', Icons.camera_alt, AppTheme.primary,
          () => _push(const AttendanceScreen()));
    }
    if (state.can(Perms.studentRead)) {
      add('إدارة الطلاب', 'إضافة وبحث وتعديل ملفات الطلاب', Icons.people, AppTheme.accent,
          () => _push(const StudentsScreen()));
    }
    if (state.can(Perms.studentRead)) {
      add('إدارة الصفوف', 'الصفوف والشعب وكشوف الطلاب', Icons.school, AppTheme.primary,
          () => _push(const ClassesScreen()));
    }
    if (state.can(Perms.biometricManage)) {
      add('بصمات الطلاب', 'تسجيل/تحديث وجه الطالب أو رفع صورته', Icons.face_retouching_natural,
          AppTheme.success, () => _push(const FaceEnrollScreen()));
    }
    if (state.can(Perms.userManage)) {
      add('إدارة المعلمين والمشرفين', 'إنشاء الحسابات والأدوار', Icons.manage_accounts, AppTheme.warning,
          () => _push(const UsersScreen()));
    }
    if (state.can(Perms.settingsManage)) {
      add('الهيكل المدرسي', 'المراحل والصفوف والشعب والمواد', Icons.account_tree, AppTheme.primary,
          () => _push(const AcademicScreen()));
    }
    if (state.can(Perms.gradeRead)) {
      add('الدرجات والامتحانات', 'إنشاء امتحانات وإدخال الدرجات', Icons.grade, AppTheme.accent,
          () => _push(const GradesScreen()));
    }
    if (state.can(Perms.evaluationWrite)) {
      add('التقييم الأسبوعي', 'تقييم تراكمي لكل مادة وأسبوع', Icons.insights, AppTheme.primary,
          () => _push(const EvaluationsScreen()));
    }
    if (state.can(Perms.studentWrite)) {
      add('ترحيل نهاية السنة', 'الناجحون لشعبة جديدة والراسبون يبقون', Icons.upgrade, AppTheme.warning,
          () => _push(const PromotionScreen()));
    }
    if (state.can(Perms.reportRead)) {
      add('الغيابات والتقارير', 'تقارير الحضور والغياب والتأخير', Icons.bar_chart, AppTheme.success,
          () => _push(const ReportsScreen()));
    }
    if (state.can(Perms.settingsManage)) {
      add('حقول ملف الطالب', 'إضافة حقول مخصّصة', Icons.edit_note, AppTheme.accent,
          () => _push(const StudentColumnsScreen()));
    }
    if (state.can(Perms.auditRead)) {
      add('سجل العمليات', 'آخر الإجراءات وتعديلات الحضور', Icons.history, AppTheme.textMuted,
          () => _push(const AuditScreen()));
    }
    if (state.can(Perms.settingsManage)) {
      add('الإعدادات', 'أوقات الدوام ونوافذ الحضور', Icons.settings, AppTheme.textMuted,
          () => _push(const SettingsScreen()));
    }
    if (state.can(Perms.backupManage)) {
      add('النسخ الاحتياطي', 'إنشاء نسخة واستعادة البيانات', Icons.backup, AppTheme.success,
          () => _push(const BackupScreen()));
    }
    return list;
  }

  void _push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
}
