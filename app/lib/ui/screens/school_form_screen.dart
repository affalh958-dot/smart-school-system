import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/audit_repository.dart';
import '../../data/school_repository.dart';

/// نموذج إنشاء مدرسة جديدة (للمالك): الاسم + حساب مدير المدرسة + هيكل مبدئي اختياري.
class SchoolFormScreen extends StatefulWidget {
  const SchoolFormScreen({super.key});

  @override
  State<SchoolFormScreen> createState() => _SchoolFormScreenState();
}

class _SchoolFormScreenState extends State<SchoolFormScreen> {
  final _name = TextEditingController();
  final _managerName = TextEditingController();
  final _managerUser = TextEditingController();
  final _managerPass = TextEditingController();
  final _stages = TextEditingController(text: 'الابتدائية');
  final _grades = TextEditingController(text: 'الأول, الثاني, الثالث, الرابع, الخامس, السادس');
  bool _includeManager = true;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _managerName.dispose();
    _managerUser.dispose();
    _managerPass.dispose();
    _stages.dispose();
    _grades.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _snack('اسم المدرسة مطلوب', AppTheme.danger);
      return;
    }
    if (_includeManager && (_managerUser.text.trim().isEmpty || _managerPass.text.length < 6)) {
      _snack('اسم مستخدم المدير وكلمة مرور لا تقل عن 6 أحرف مطلوبان', AppTheme.danger);
      return;
    }
    setState(() => _saving = true);
    try {
      final uid = context.read<AppState>().user?['id'] as String?;
      final stages = _stages.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      final gradeNames = _grades.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      final seedGrades = List.generate(stages.length, (_) => List<String>.from(gradeNames));

      final id = await SchoolRepository().createSchool(
        name: _name.text.trim(),
        managerUsername: _includeManager ? _managerUser.text.trim() : null,
        managerPassword: _includeManager ? _managerPass.text : null,
        managerName: _managerName.text.trim(),
        seedStageNames: stages,
        seedGrades: seedGrades,
      );
      await AuditRepository().log(
        userId: uid,
        action: 'school.create',
        entityType: 'school',
        entityId: id,
        newValue: _name.text.trim(),
      );
      if (!mounted) return;
      _snack('تم إنشاء المدرسة ببياناتها المعزولة', AppTheme.success);
      Navigator.pop(context);
    } catch (e) {
      _snack('تعذّر الإنشاء: $e', AppTheme.danger);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String m, Color c) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), backgroundColor: c));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('مدرسة جديدة')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _Head('بيانات المدرسة'),
          _field(_name, 'اسم المدرسة *', Icons.apartment),
          const SizedBox(height: 8),
          const _Head('حساب مدير المدرسة'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('إنشاء حساب مدير المدرسة الآن'),
            value: _includeManager,
            onChanged: (v) => setState(() => _includeManager = v),
          ),
          if (_includeManager) ...[
            _field(_managerName, 'اسم المدير', Icons.person),
            _field(_managerUser, 'اسم المستخدم', Icons.account_circle),
            _field(_managerPass, 'كلمة المرور', Icons.lock, obscure: true),
          ],
          const SizedBox(height: 8),
          const _Head('الهيكل المبدئي (اختياري)'),
          _field(_stages, 'المراحل (مفصولة بفاصلة)', Icons.account_tree),
          _field(_grades, 'الصفوف (مفصولة بفاصلة)', Icons.school),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save),
            label: const Text('إنشاء المدرسة'),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label, IconData icon, {bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        obscureText: obscure,
        decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
      ),
    );
  }
}

class _Head extends StatelessWidget {
  final String text;
  const _Head(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(text,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.primary)),
      );
}
