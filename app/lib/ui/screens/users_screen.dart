import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../data/database.dart';
import '../../data/repositories.dart';

/// شاشة المستخدمين — إنشاء الحسابات وتحديد الأدوار (مسؤول النظام/المالك).
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final state = context.read<AppState>();
    final db = await AppDatabase.instance.database;
    final schoolId = state.schoolId;
    // عزل: يعرض المالك/مسؤول المنصة كل المستخدمين، وغيره المستخدمين ضمن مدرسته فقط.
    final rows = state.can(Perms.tenantManage) || schoolId == null
        ? await db.rawQuery('''
            SELECT u.id, u.username, u.full_name, u.is_active, u.school_id,
                   GROUP_CONCAT(r.code) roles
            FROM users u
            LEFT JOIN user_roles ur ON ur.user_id = u.id
            LEFT JOIN roles r ON r.id = ur.role_id
            WHERE u.deleted_at IS NULL
            GROUP BY u.id
            ORDER BY u.full_name
          ''')
        : await db.rawQuery('''
            SELECT u.id, u.username, u.full_name, u.is_active, u.school_id,
                   GROUP_CONCAT(r.code) roles
            FROM users u
            LEFT JOIN user_roles ur ON ur.user_id = u.id
            LEFT JOIN roles r ON r.id = ur.role_id
            WHERE u.deleted_at IS NULL AND (u.school_id = ? OR u.school_id IS NULL)
            GROUP BY u.id
            ORDER BY u.full_name
          ''', [schoolId]);
    if (!mounted) return;
    setState(() {
      _users = rows;
      _loading = false;
    });
  }

  Future<void> _addUser() async {
    final state = context.read<AppState>();
    final userCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    String role = Roles.attendance;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        return AlertDialog(
          title: const Text('مستخدم جديد'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'الاسم الكامل')),
                const SizedBox(height: 10),
                TextField(controller: userCtrl, decoration: const InputDecoration(labelText: 'اسم المستخدم')),
                const SizedBox(height: 10),
                TextField(controller: passCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: role,
                  decoration: const InputDecoration(labelText: 'الدور'),
                  items: Roles.labels.entries
                      .where((e) => e.key != Roles.owner)
                      .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                      .toList(),
                  onChanged: (v) => setDlg(() => role = v ?? Roles.attendance),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إنشاء')),
          ],
        );
      }),
    );
    if (ok != true) return;
    if (userCtrl.text.trim().isEmpty || passCtrl.text.length < 6) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اسم المستخدم مطلوب وكلمة المرور لا تقل عن 6 أحرف')),
      );
      return;
    }
    try {
      await AuthRepository().createUser(
        username: userCtrl.text.trim(),
        password: passCtrl.text,
        fullName: nameCtrl.text.trim(),
        schoolId: state.schoolId,
        roleCode: role,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذّر الإنشاء: $e')));
    }
  }

  Future<void> _toggleActive(String id, bool active) async {
    final db = await AppDatabase.instance.database;
    await db.update('users', {'is_active': active ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('المستخدمون')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addUser,
        icon: const Icon(Icons.person_add),
        label: const Text('مستخدم جديد'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _users.length,
              itemBuilder: (ctx, i) {
                final u = _users[i];
                final roles = (u['roles'] as String?)?.split(',') ?? [];
                final active = (u['is_active'] as int) == 1;
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: active ? AppTheme.primary : AppTheme.textMuted,
                      child: const Icon(Icons.person, color: Colors.white),
                    ),
                    title: Text(u['full_name'] as String),
                    subtitle: Text('${u['username']}  •  ${roles.map((r) => Roles.labels[r] ?? r).join('، ')}'),
                    trailing: Switch(
                      value: active,
                      onChanged: (v) => _toggleActive(u['id'] as String, v),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
