import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../data/audit_repository.dart';
import '../../data/repositories.dart';
import '../../data/school_repository.dart';
import 'dashboard_screen.dart';

/// تفاصيل مدرسة (للمالك): الإحصاءات، المستخدمون، تفعيل/تعطيل، أرشفة، ودخول المدرسة.
class SchoolDetailScreen extends StatefulWidget {
  final Map<String, dynamic> school;
  const SchoolDetailScreen({super.key, required this.school});

  @override
  State<SchoolDetailScreen> createState() => _SchoolDetailScreenState();
}

class _SchoolDetailScreenState extends State<SchoolDetailScreen> {
  final _repo = SchoolRepository();
  late Map<String, dynamic> _school;
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _school = widget.school;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final fresh = await _repo.byId(_school['id'] as String);
    final users = await _repo.usersOf(_school['id'] as String);
    if (!mounted) return;
    setState(() {
      if (fresh != null) _school = {..._school, ...fresh};
      _users = users;
      _loading = false;
    });
  }

  Future<void> _toggleActive(bool active) async {
    final uid = context.read<AppState>().user?['id'] as String?;
    await _repo.setActive(_school['id'] as String, active);
    await AuditRepository().log(
      userId: uid,
      action: active ? 'school.activate' : 'school.deactivate',
      entityType: 'school',
      entityId: _school['id'] as String,
    );
    await _load();
  }

  Future<void> _archive() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('أرشفة المدرسة'),
        content: const Text(
            'سيتم تعطيل المدرسة وحساباتها مع الاحتفاظ بكل السجلات التاريخية. هل أنت متأكد؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('أرشفة')),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final uid = context.read<AppState>().user?['id'] as String?;
    await _repo.archive(_school['id'] as String);
    await AuditRepository().log(
      userId: uid,
      action: 'school.archive',
      entityType: 'school',
      entityId: _school['id'] as String,
    );
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _enter() async {
    final state = context.read<AppState>();
    state.setSchool(_school['id'] as String, _school['name'] as String);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DashboardScreen()));
    state.setSchool('', '');
  }

  /// المالك ينشئ حساب مدير المدرسة ثم يسلّمه بيانات الدخول.
  Future<void> _createManager() async {
    final uid = context.read<AppState>().user?['id'] as String?;
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController(text: _suggestPassword());
    var obscure = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) => AlertDialog(
            title: const Text('إنشاء حساب مدير المدرسة'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'اسم المدير الكامل')),
                const SizedBox(height: 8),
                TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'رقم هاتف المدير')),
                const SizedBox(height: 8),
                TextField(controller: userCtrl, decoration: const InputDecoration(labelText: 'اسم المستخدم')),
                const SizedBox(height: 8),
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
                const SizedBox(height: 6),
                const Text('سلّم هذه البيانات للمدير ليدخل بها إلى مدرسته.',
                    style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
              ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إنشاء وتسليم')),
            ],
          )),
    );
    if (ok != true) return;
    if (userCtrl.text.trim().isEmpty || passCtrl.text.length < 6 || nameCtrl.text.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('الاسم واسم المستخدم مطلوبان وكلمة المرور لا تقل عن 6 أحرف')));
      return;
    }
    try {
      await AuthRepository().createUser(
        username: userCtrl.text.trim(),
        password: passCtrl.text,
        fullName: nameCtrl.text.trim(),
        phone: phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
        schoolId: _school['id'] as String,
        roleCode: Roles.manager,
      );
      await AuditRepository().log(
        userId: uid,
        action: 'user.create_manager',
        entityType: 'school',
        entityId: _school['id'] as String,
      );
      await _load();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('بيانات دخول المدير'),
          content: SelectableText(
              'اسم المستخدم: ${userCtrl.text.trim()}\nكلمة المرور: ${passCtrl.text}\n\n'
              'سلّمها للمدير ليتمكن من الدخول إلى مدرسته.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('تم')),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذّر الإنشاء: $e')));
    }
  }

  String _suggestPassword() {
    final r = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    return 'Sch${r.substring(r.length - 5)}';
  }

  @override
  Widget build(BuildContext context) {
    final active = (_school['is_active'] as int?) == 1;
    return Scaffold(
      appBar: AppBar(title: Text(_school['name'] as String)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Column(children: [
                    ListTile(
                      leading: const Icon(Icons.apartment, color: AppTheme.primary),
                      title: const Text('حالة المدرسة'),
                      subtitle: Text(active ? 'نشطة' : 'معطّلة'),
                      trailing: Switch(value: active, onChanged: _toggleActive),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.groups, color: AppTheme.accent),
                      title: const Text('عدد الطلاب'),
                      trailing: Text('${_school['students_count'] ?? 0}'),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.public, color: AppTheme.textMuted),
                      title: const Text('المنطقة الزمنية'),
                      trailing: Text('${_school['timezone']}'),
                    ),
                  ]),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: active ? _enter : null,
                  icon: const Icon(Icons.login),
                  label: const Text('الدخول إلى المدرسة (وضع العمل)'),
                ),
                const SizedBox(height: 20),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _createManager,
                      icon: const Icon(Icons.person_add_alt_1),
                      label: const Text('إنشاء حساب مدير المدرسة'),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                const Text('حسابات المدرسة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                if (_users.isEmpty)
                  const Card(
                      child: Padding(
                          padding: EdgeInsets.all(16), child: Text('لا يوجد مستخدمون بعد'))),
                ..._users.map((u) {
                  final roles = (u['roles'] as String?)?.split(',') ?? [];
                  return Card(
                    child: ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.person)),
                      title: Text(u['full_name'] as String),
                      subtitle: Text(
                          '${u['username']}  •  ${roles.map((r) => Roles.labels[r] ?? r).join('، ')}'),
                    ),
                  );
                }),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
                  onPressed: _archive,
                  icon: const Icon(Icons.archive),
                  label: const Text('أرشفة المدرسة (حذف منطقي آمن)'),
                ),
                const SizedBox(height: 30),
              ],
            ),
    );
  }
}
