import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/app_state.dart';
import '../../core/config.dart';
import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../data/database.dart';
import '../../data/repositories.dart';
import 'dashboard_screen.dart';

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
  final _schoolCtrl = TextEditingController(text: 'مدرستي');
  final _nameCtrl = TextEditingController(text: 'مالك النظام');
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
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const DashboardScreen()));
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
    final db = await AppDatabase.instance.database;
    final schoolId = const Uuid().v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('schools', {
      'id': schoolId,
      'name': _schoolCtrl.text.trim().isEmpty ? 'مدرستي' : _schoolCtrl.text.trim(),
      'timezone': AppConfig.timezone,
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });

    // إعدادات دوام افتراضية
    await db.insert('attendance_settings', {
      'id': const Uuid().v4(),
      'school_id': schoolId,
      'scope': 'school',
      'day_start': '07:30',
      'day_end': '13:30',
      'checkin_window_start': '07:00',
      'checkin_window_end': '07:45',
      'late_after': '07:30',
      'auto_close_time': '08:00',
      'working_days': '[0,1,2,3,4]',
      'created_at': now,
      'updated_at': now,
    });

    // سنة دراسية حالية
    final yearId = const Uuid().v4();
    final y = DateTime.now().year;
    await db.insert('academic_years', {
      'id': yearId,
      'school_id': schoolId,
      'name': '$y/${y + 1}',
      'start_date': '$y-09-01',
      'end_date': '${y + 1}-06-30',
      'is_current': 1,
      'created_at': now,
      'updated_at': now,
    });

    // حساب المالك الثابت
    await AuthRepository().createUser(
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
      fullName: _nameCtrl.text.trim(),
      schoolId: schoolId,
      roleCode: Roles.owner,
    );

    final user = await AuthRepository().login(_userCtrl.text.trim(), _passCtrl.text);
    if (user != null) {
      state.setSession(user);
      state.setSchool(schoolId, _schoolCtrl.text.trim());
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const DashboardScreen()));
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
                      _setup ? 'التهيئة الأولى للنظام' : 'تسجيل الدخول',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _setup ? 'أنشئ حساب المالك الثابت الذي يدير التطبيق بالكامل' : 'أدخل بياناتك للمتابعة',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppTheme.textMuted),
                    ),
                    const SizedBox(height: 24),
                    if (_setup) ...[
                      TextField(
                        controller: _schoolCtrl,
                        decoration: const InputDecoration(labelText: 'اسم المدرسة', prefixIcon: Icon(Icons.apartment)),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _nameCtrl,
                        decoration: const InputDecoration(labelText: 'الاسم الكامل', prefixIcon: Icon(Icons.person)),
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
