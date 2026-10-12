import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/database.dart';
import '../../data/school_repository.dart';
import 'audit_screen.dart';
import 'dashboard_screen.dart';
import 'login_screen.dart';
import 'school_detail_screen.dart';
import 'school_form_screen.dart';

/// لوحة المالك (مدير المنصة): إدارة كل المدارس، إنشاء مدارس جديدة،
/// والدخول إلى مدرسة (وضع العمل) لإدارة بياناتها.
class PlatformDashboardScreen extends StatefulWidget {
  const PlatformDashboardScreen({super.key});

  @override
  State<PlatformDashboardScreen> createState() => _PlatformDashboardScreenState();
}

class _PlatformDashboardScreenState extends State<PlatformDashboardScreen> {
  final _repo = SchoolRepository();
  List<Map<String, dynamic>> _schools = [];
  Map<String, int> _totals = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final schools = await _repo.all();
    final db = await AppDatabase.instance.database;
    final students = await db.rawQuery('SELECT COUNT(*) c FROM students WHERE deleted_at IS NULL');
    final users = await db.rawQuery('SELECT COUNT(*) c FROM users WHERE deleted_at IS NULL');
    final active = await db.rawQuery('SELECT COUNT(*) c FROM schools WHERE deleted_at IS NULL AND is_active = 1');
    if (!mounted) return;
    setState(() {
      _schools = schools;
      _totals = {
        'students': students.first['c'] as int,
        'users': users.first['c'] as int,
        'schools': schools.length,
        'active': active.first['c'] as int,
      };
      _loading = false;
    });
  }

  Future<void> _enterSchool(Map<String, dynamic> school) async {
    final state = context.read<AppState>();
    state.setSchool(school['id'] as String, school['name'] as String);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DashboardScreen()));
    // عند الرجوع، ألغِ وضع المدرسة (المالك ليس مدير مدرسة)
    state.setSchool('', '');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('منصة إدارة المدارس'),
        actions: [
          IconButton(
              tooltip: 'سجل العمليات',
              icon: const Icon(Icons.history),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const AuditScreen()))),
          IconButton(
              tooltip: 'تسجيل الخروج',
              icon: const Icon(Icons.logout),
              onPressed: () {
                state.logout();
                Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const LoginScreen()));
              }),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const SchoolFormScreen()));
          await _load();
        },
        icon: const Icon(Icons.add_business),
        label: const Text('مدرسة جديدة'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _ownerCard(state),
                  const SizedBox(height: 16),
                  _statsRow(),
                  const SizedBox(height: 20),
                  const Text('المدارس', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  if (_schools.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                            child: Text('لا توجد مدارس بعد — اضغط «مدرسة جديدة» للبدء')),
                      ),
                    ),
                  ..._schools.map(_schoolTile),
                ],
              ),
            ),
    );
  }

  Widget _ownerCard(AppState state) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const CircleAvatar(
                radius: 26, backgroundColor: AppTheme.primary, child: Icon(Icons.verified_user, color: Colors.white)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('مرحباً، ${state.user?['full_name'] ?? ''}',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('مالك المنصة — يدير كل المدارس ومديريها',
                      style: TextStyle(color: AppTheme.textMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statsRow() {
    final cards = [
      _stat('المدارس', '${_totals['schools'] ?? 0}', Icons.apartment, AppTheme.primary),
      _stat('المدارس النشطة', '${_totals['active'] ?? 0}', Icons.check_circle, AppTheme.success),
      _stat('إجمالي الطلاب', '${_totals['students'] ?? 0}', Icons.groups, AppTheme.accent),
      _stat('إجمالي المستخدمين', '${_totals['users'] ?? 0}', Icons.manage_accounts, AppTheme.warning),
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

  Widget _stat(String title, String value, IconData icon, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
                Text(title,
                    style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _schoolTile(Map<String, dynamic> s) {
    final active = (s['is_active'] as int) == 1;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: active ? AppTheme.primary : AppTheme.textMuted,
          child: const Icon(Icons.apartment, color: Colors.white),
        ),
        title: Text(s['name'] as String),
        subtitle: Text(
            'الطلاب: ${s['students_count']}  •  المستخدمون: ${s['users_count']}  •  ${active ? 'نشطة' : 'معطّلة'}'),
        trailing: const Icon(Icons.chevron_left),
        onTap: () async {
          await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SchoolDetailScreen(school: s)));
          await _load();
        },
        onLongPress: () => _enterSchool(s),
      ),
    );
  }

  // ignore: unused_element
  void _noop() {}
}
