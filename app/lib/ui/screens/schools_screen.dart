import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/config.dart';
import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../data/database.dart';
import '../../data/repositories.dart';

/// شاشة المدارس (للمالك فقط) — إنشاء مدارس مستقلة ومعزولة تماماً.
class SchoolsScreen extends StatefulWidget {
  const SchoolsScreen({super.key});

  @override
  State<SchoolsScreen> createState() => _SchoolsScreenState();
}

class _SchoolsScreenState extends State<SchoolsScreen> {
  List<Map<String, dynamic>> _schools = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = await AppDatabase.instance.database;
    final rows = await db.query('schools', where: 'deleted_at IS NULL', orderBy: 'name');
    if (!mounted) return;
    setState(() {
      _schools = rows;
      _loading = false;
    });
  }

  Future<void> _addSchool() async {
    final nameCtrl = TextEditingController();
    final adminUserCtrl = TextEditingController();
    final adminNameCtrl = TextEditingController();
    final adminPassCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إنشاء مدرسة جديدة (معزولة)'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'اسم المدرسة')),
              const SizedBox(height: 10),
              const Divider(),
              const Text('حساب مدير المدرسة (اختياري)', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(controller: adminNameCtrl, decoration: const InputDecoration(labelText: 'اسم المدير')),
              const SizedBox(height: 10),
              TextField(controller: adminUserCtrl, decoration: const InputDecoration(labelText: 'اسم المستخدم')),
              const SizedBox(height: 10),
              TextField(controller: adminPassCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إنشاء')),
        ],
      ),
    );
    if (ok != true || nameCtrl.text.trim().isEmpty) return;

    final db = await AppDatabase.instance.database;
    final schoolId = const Uuid().v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      await txn.insert('schools', {
        'id': schoolId,
        'name': nameCtrl.text.trim(),
        'timezone': AppConfig.timezone,
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      });
      await txn.insert('attendance_settings', {
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
      final y = DateTime.now().year;
      await txn.insert('academic_years', {
        'id': const Uuid().v4(),
        'school_id': schoolId,
        'name': '$y/${y + 1}',
        'start_date': '$y-09-01',
        'end_date': '${y + 1}-06-30',
        'is_current': 1,
        'created_at': now,
        'updated_at': now,
      });
    });

    if (adminUserCtrl.text.trim().isNotEmpty && adminPassCtrl.text.length >= 6) {
      await AuthRepository().createUser(
        username: adminUserCtrl.text.trim(),
        password: adminPassCtrl.text,
        fullName: adminNameCtrl.text.trim(),
        schoolId: schoolId,
        roleCode: Roles.manager,
      );
    }
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تم إنشاء مدرسة «${nameCtrl.text.trim()}» معزولة بالكامل')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('المدارس')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addSchool,
        icon: const Icon(Icons.add_business),
        label: const Text('مدرسة جديدة'),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(children: [
              Icon(Icons.lock, color: AppTheme.accent),
              SizedBox(width: 10),
              Expanded(
                child: Text('كل مدرسة معزولة تماماً: بياناتها وطلابها ومستخدموها لا تظهر لأي مدرسة أخرى.',
                    style: TextStyle(fontSize: 13)),
              ),
            ]),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _schools.length,
                    itemBuilder: (ctx, i) {
                      final s = _schools[i];
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.apartment)),
                          title: Text(s['name'] as String),
                          subtitle: Text('المنطقة الزمنية: ${s['timezone']}'),
                          trailing: const Icon(Icons.check_circle, color: AppTheme.success),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
