import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../data/database.dart';
import '../../data/models.dart';
import '../../data/repositories.dart';

/// شاشة المستخدمين — إنشاء الحسابات وتحديد الأدوار (المالك/المدير/المعاون)،
/// مع الاسم ورقم الهاتف، وعرض بيانات الحساب وإعادة تعيين كلمة المرور.
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
    // عزل: المالك خارج مدرسة يرى الكل؛ من كان داخل مدرسة يرى مستخدميها فقط.
    final rows = (schoolId == null && state.can(Perms.tenantManage))
        ? await db.rawQuery('''
            SELECT u.id, u.username, u.full_name, u.phone, u.is_active, u.school_id,
                   GROUP_CONCAT(r.code) roles
            FROM users u
            LEFT JOIN user_roles ur ON ur.user_id = u.id
            LEFT JOIN roles r ON r.id = ur.role_id
            WHERE u.deleted_at IS NULL
            GROUP BY u.id
            ORDER BY u.full_name
          ''')
        : await db.rawQuery('''
            SELECT u.id, u.username, u.full_name, u.phone, u.is_active, u.school_id,
                   GROUP_CONCAT(r.code) roles
            FROM users u
            LEFT JOIN user_roles ur ON ur.user_id = u.id
            LEFT JOIN roles r ON r.id = ur.role_id
            WHERE u.deleted_at IS NULL AND u.school_id = ?
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
    final phoneCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    String role = Roles.teacher;
    String? linkedStudentId;
    String? linkedStudentName;
    var obscure = true;
    final canManageAll = state.can(Perms.tenantManage) || state.can(Perms.userManage);
    // المالك/المدير يضيف: مدير، معاون، معلم، مشرف حضور. (لا يُنشئ مالكاً آخر.)
    final roleOptions = Roles.labels.entries
        .where((e) =>
            e.key != Roles.owner &&
            (canManageAll
                ? (e.key != Roles.owner)
                : (e.key == Roles.teacher || e.key == Roles.attendance)))
        .toList();

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
                TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'رقم الهاتف')),
                const SizedBox(height: 10),
                TextField(controller: userCtrl, decoration: const InputDecoration(labelText: 'اسم المستخدم')),
                const SizedBox(height: 10),
                TextField(
                  controller: passCtrl,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    labelText: 'كلمة المرور',
                    suffixIcon: IconButton(
                      icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setDlg(() => obscure = !obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: role,
                  decoration: const InputDecoration(labelText: 'الدور'),
                  items: roleOptions
                      .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                      .toList(),
                  onChanged: (v) => setDlg(() => role = v ?? Roles.teacher),
                ),
                if (role == Roles.student || role == Roles.guardian) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.person_search),
                    label: Text(linkedStudentName == null
                        ? 'ربط الحساب بطالب (إلزامي)'
                        : 'الطالب: $linkedStudentName'),
                    onPressed: () async {
                      final picked = await _pickStudent();
                      if (picked != null) {
                        setDlg(() {
                          linkedStudentId = picked['id'] as String;
                          linkedStudentName = picked['full_name'] as String;
                          nameCtrl.text = nameCtrl.text.isEmpty
                              ? picked['full_name'] as String
                              : nameCtrl.text;
                        });
                      }
                    },
                  ),
                ],
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
    if ((role == Roles.student || role == Roles.guardian) && linkedStudentId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يجب ربط حساب الطالب/ولي الأمر بملف طالب')),
      );
      return;
    }
    try {
      await AuthRepository().createUser(
        username: userCtrl.text.trim(),
        password: passCtrl.text,
        fullName: nameCtrl.text.trim(),
        phone: phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
        schoolId: state.schoolId,
        roleCode: role,
        studentId: linkedStudentId,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذّر الإنشاء: $e')));
    }
  }

  /// نافذة اختيار طالب من المدرسة للربط بالحساب.
  Future<Map<String, dynamic>?> _pickStudent() async {
    final state = context.read<AppState>();
    final query = TextEditingController();
    var results = <Student>[];
    var searched = false;
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        Future<void> run() async {
          final list = await StudentRepository().search(state.schoolId ?? '', query.text.trim());
          setDlg(() {
            results = list.take(40).toList();
            searched = true;
          });
        }

        return AlertDialog(
          title: const Text('اختر الطالب'),
          content: SizedBox(
            width: 420,
            height: 420,
            child: Column(children: [
              TextField(
                controller: query,
                decoration: const InputDecoration(
                    labelText: 'ابحث بالاسم أو الرقم المدرسي',
                    suffixIcon: Icon(Icons.search)),
                onSubmitted: (_) => run(),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: !searched
                    ? const Center(child: Text('اكتب جزءاً من الاسم أو الرقم ثم ابحث'))
                    : results.isEmpty
                        ? const Center(child: Text('لا نتائج'))
                        : ListView(
                            children: results
                                .map((s) => ListTile(
                                      title: Text(s.fullName),
                                      subtitle: Text('الرقم: ${s.studentNumber}'),
                                      onTap: () => Navigator.pop(ctx, {
                                        'id': s.id,
                                        'full_name': s.fullName,
                                      }),
                                    ))
                                .toList(),
                          ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            ElevatedButton(onPressed: run, child: const Text('بحث')),
          ],
        );
      }),
    );
  }

  Future<void> _toggleActive(String id, bool active) async {
    final db = await AppDatabase.instance.database;
    await db.update('users', {'is_active': active ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
    await _load();
  }

  /// عرض بيانات الحساب (اسم المستخدم/الهاتف) — يطّلع عليها المدير/المالك،
  /// مع إمكانية إعادة تعيين كلمة المرور وتسليمها للمستخدم.
  Future<void> _accountInfo(Map<String, dynamic> u) async {
    final roles = (u['roles'] as String?)?.split(',').where((r) => r.isNotEmpty).toList() ?? [];
    final passCtrl = TextEditingController();
    var obscure = true;
    final reset = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        return AlertDialog(
          title: Text(u['full_name'] as String),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _infoRow('اسم المستخدم', '${u['username']}'),
              _infoRow('الهاتف', '${u['phone'] ?? '-'}'),
              _infoRow('الأدوار', roles.map((r) => Roles.labels[r] ?? r).join('، ')),
              const Divider(height: 24),
              const Text('إعادة تعيين كلمة المرور (اتركها فارغة للإلغاء):',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: passCtrl,
                obscureText: obscure,
                decoration: InputDecoration(
                  labelText: 'كلمة مرور جديدة',
                  suffixIcon: IconButton(
                    icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setDlg(() => obscure = !obscure),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: '${u['username']}'));
                ScaffoldMessenger.of(ctx)
                    .showSnackBar(const SnackBar(content: Text('تم نسخ اسم المستخدم')));
              },
              child: const Text('نسخ اسم المستخدم'),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إغلاق')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, passCtrl.text.length >= 6),
              child: const Text('حفظ كلمة المرور'),
            ),
          ],
        );
      }),
    );
    if (reset == true && passCtrl.text.length >= 6) {
      await AuthRepository().resetPassword(u['id'] as String, passCtrl.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم تحديث كلمة مرور ${u['username']}')));
    }
  }

  Widget _infoRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 90, child: Text(k, style: const TextStyle(color: AppTheme.textMuted))),
          Expanded(child: SelectableText(v, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );

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
                final roles = (u['roles'] as String?)?.split(',').where((r) => r.isNotEmpty) ?? [];
                final active = (u['is_active'] as int) == 1;
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: active ? AppTheme.primary : AppTheme.textMuted,
                      child: const Icon(Icons.person, color: Colors.white),
                    ),
                    title: Text(u['full_name'] as String),
                    subtitle: Text(
                        '${u['username']}  •  ${roles.map((r) => Roles.labels[r] ?? r).join('، ')}'
                        '${(u['phone'] ?? '').toString().isNotEmpty ? '\n📞 ${u['phone']}' : ''}'),
                    isThreeLine: (u['phone'] ?? '').toString().isNotEmpty,
                    trailing: Switch(
                      value: active,
                      onChanged: (v) => _toggleActive(u['id'] as String, v),
                    ),
                    onTap: () => _accountInfo(u),
                  ),
                );
              },
            ),
    );
  }
}
