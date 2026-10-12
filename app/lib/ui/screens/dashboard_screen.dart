import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../data/attendance_repository.dart';
import '../../data/repositories.dart';
import 'attendance_screen.dart';
import 'academic_screen.dart';
import 'classes_screen.dart';
import 'face_enroll_screen.dart';
import 'grades_screen.dart';
import 'login_screen.dart';
import 'reports_screen.dart';
import 'settings_screen.dart';
import 'student_columns_screen.dart';
import 'students_screen.dart';
import 'users_screen.dart';
import 'schools_screen.dart';

/// لوحة التحكم الرئيسية — قائمة بسيطة جداً حسب دور المستخدم.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Map<String, int> _stats = {};
  int _totalStudents = 0;
  int _pending = 0;

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
      });
    } catch (_) {
      // نتجاهل أخطاء التحميل الأولي ولا نعطّل اللوحة
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final items = _menuFor(state);

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
            const SizedBox(height: 16),
            const Text('الوظائف المتاحة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...items.map((e) => _menuTile(e)),
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
    final cards = [
      _statCard('إجمالي الطلاب', '$_totalStudents', Icons.groups, AppTheme.accent),
      _statCard('الحاضرون اليوم', '$present', Icons.check_circle, AppTheme.success),
      _statCard('المتأخرون', '$late', Icons.schedule, AppTheme.warning),
      _statCard('الغائبون', '$absent', Icons.cancel, AppTheme.danger),
      _statCard('لم يسجّلوا بعد', '$notRecorded', Icons.hourglass_empty, AppTheme.textMuted),
      _statCard('تحتاج مراجعة', '$_pending', Icons.flag, AppTheme.warning),
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

  Widget _menuTile(_MenuItem item) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(backgroundColor: item.color.withValues(alpha: 0.15), child: Icon(item.icon, color: item.color)),
        title: Text(item.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        subtitle: Text(item.subtitle),
        trailing: const Icon(Icons.chevron_left),
        onTap: item.onTap,
      ),
    );
  }

  List<_MenuItem> _menuFor(AppState state) {
    final list = <_MenuItem>[];
    if (state.can(Perms.attendanceScreen)) {
      list.add(_MenuItem('شاشة الحضور', 'تسجيل الحضور بالكاميرا تلقائياً', Icons.camera_alt, AppTheme.primary,
          () => _push(const AttendanceScreen())));
    }
    if (state.can(Perms.biometricManage)) {
      list.add(_MenuItem('تسجيل وجوه الطلاب', 'ربط وجه الطالب بملفه', Icons.face_retouching_natural, AppTheme.accent,
          () => _push(const FaceEnrollScreen())));
    }
    if (state.can(Perms.studentRead)) {
      list.add(_MenuItem('الطلاب', 'إضافة وبحث وتعديل ملفات الطلاب', Icons.people, AppTheme.accent,
          () => _push(const StudentsScreen())));
    }
    if (state.can(Perms.studentRead)) {
      list.add(_MenuItem('الصفوف والشعب', 'تصفح الصفوف، ولكل شعبة طلابها ووجوهها', Icons.school, AppTheme.primary,
          () => _push(const ClassesScreen())));
    }
    if (state.can(Perms.settingsManage)) {
      list.add(_MenuItem('حقول ملف الطالب', 'إضافة حقول مخصّصة (هوية، سكن، ملاحظات...)', Icons.edit_note, AppTheme.accent,
          () => _push(const StudentColumnsScreen())));
    }
    if (state.can(Perms.settingsManage)) {
      list.add(_MenuItem('الهيكل المدرسي', 'المراحل والصفوف والشعب والمدرسون والمواد', Icons.account_tree, AppTheme.primary,
          () => _push(const AcademicScreen())));
    }
    if (state.can(Perms.gradeRead)) {
      list.add(_MenuItem('الدرجات والامتحانات', 'إنشاء امتحانات وإدخال الدرجات', Icons.grade, AppTheme.accent,
          () => _push(const GradesScreen())));
    }
    if (state.can(Perms.reportRead)) {
      list.add(_MenuItem('التقارير', 'الحضور والغياب والتأخير', Icons.bar_chart, AppTheme.success,
          () => _push(const ReportsScreen())));
    }
    if (state.can(Perms.userManage)) {
      list.add(_MenuItem('المستخدمون', 'إنشاء الحسابات والأدوار', Icons.manage_accounts, AppTheme.warning,
          () => _push(const UsersScreen())));
    }
    if (state.can(Perms.settingsManage)) {
      list.add(_MenuItem('الإعدادات', 'أوقات الدوام ونوافذ الحضور', Icons.settings, AppTheme.textMuted,
          () => _push(const SettingsScreen())));
    }
    if (state.can(Perms.tenantManage)) {
      list.add(_MenuItem('المدارس', 'إنشاء مدارس مستقلة معزولة', Icons.apartment, AppTheme.danger,
          () => _push(const SchoolsScreen())));
    }
    return list;
  }

  void _push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
}

class _MenuItem {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  _MenuItem(this.title, this.subtitle, this.icon, this.color, this.onTap);
}
