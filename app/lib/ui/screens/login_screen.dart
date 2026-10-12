import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../data/database.dart';
import '../../data/repositories.dart';
import 'dashboard_screen.dart';
import 'platform_dashboard_screen.dart';
import 'student_home_screen.dart';

/// شاشة الدخول. عند أول تشغيل تُنشئ حساب المالك الثابت والمدرسة الأولى.
class LoginScreen extends StatefulWidget {
  final bool firstRun;
  const LoginScreen({super.key, this.firstRun = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _nameCtrl = TextEditingController(text: 'مالك النظام');
  final _phoneCtrl = TextEditingController();
  bool _setup = false;
  bool _obscure = true;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _setup = widget.firstRun;
  }

  Future<void> _submit() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    final state = context.read<AppState>();
    try {
      if (_setup) {
        await _createFirstSetup(state);
      } else {
        final auth = AuthRepository();
        final user = await auth.login(_userCtrl.text.trim(), _passCtrl.text);
        if (user == null) {
          setState(() => _error = 'اسم المستخدم أو كلمة المرور غير صحيحة');
          return;
        }
        state.setSession(user);
        final school = await _loadSchool(user['school_id'] as String?);
        if (school != null) state.setSchool(school['id'], school['name']);
        if (!mounted) return;
        final owner = state.isPlatformOwner;
        final student = state.isStudent;
        Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (_) => owner
                ? const PlatformDashboardScreen()
                : (student ? const StudentHomeScreen() : const DashboardScreen())));
      }
    } catch (e) {
      setState(() => _error = 'حدث خطأ: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createFirstSetup(AppState state) async {
    if (_userCtrl.text.trim().isEmpty || _passCtrl.text.length < 6) {
      setState(() => _error = 'أدخل اسم مستخدم وكلمة مرور لا تقل عن 6 أحرف');
      return;
    }
    // المالك = مدير المنصة. لا يُنشأ أي مدرسة هنا؛ المالك ينشئ المدارس لاحقاً.
    await AuthRepository().createUser(
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
      fullName: _nameCtrl.text.trim().isEmpty ? 'مالك المنصة' : _nameCtrl.text.trim(),
      phone: _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
      schoolId: null,
      roleCode: Roles.owner,
    );

    final user = await AuthRepository().login(_userCtrl.text.trim(), _passCtrl.text);
    if (user != null) state.setSession(user);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const PlatformDashboardScreen()));
  }

  Future<Map<String, dynamic>?> _loadSchool(String? id) async {
    if (id == null) return null;
    final db = await AppDatabase.instance.database;
    final rows = await db.query('schools', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.school, size: 64, color: AppTheme.primary),
                    const SizedBox(height: 12),
                    Text(
                      _setup ? 'تهيئة النظام — حساب المالك' : 'تسجيل الدخول',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _setup
                          ? 'المالك هو مدير المنصة: ينشئ المدارس ومديريها لاحقاً'
                          : 'أدخل بياناتك للمتابعة',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppTheme.textMuted),
                    ),
                    const SizedBox(height: 24),
                    if (_setup) ...[
                      TextField(
                        controller: _nameCtrl,
                        decoration: const InputDecoration(labelText: 'الاسم الكامل', prefixIcon: Icon(Icons.person)),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _phoneCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(labelText: 'رقم الهاتف (اختياري)', prefixIcon: Icon(Icons.phone)),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: _userCtrl,
                      decoration: const InputDecoration(labelText: 'اسم المستخدم', prefixIcon: Icon(Icons.account_circle)),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passCtrl,
                      obscureText: _obscure,
                      decoration: InputDecoration(
                        labelText: 'كلمة المرور',
                        prefixIcon: const Icon(Icons.lock),
                        suffixIcon: IconButton(
                          icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.danger.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(children: [
                          const Icon(Icons.error_outline, color: AppTheme.danger, size: 20),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_error!, style: const TextStyle(color: AppTheme.danger))),
                        ]),
                      ),
                    ],
                    const SizedBox(height: 20),
                    ElevatedButton.icon(
                      onPressed: _loading ? null : _submit,
                      icon: _loading
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.login),
                      label: Text(_setup ? 'إنشاء النظام والدخول' : 'دخول'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
