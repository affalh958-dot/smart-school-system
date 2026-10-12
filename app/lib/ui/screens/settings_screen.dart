import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../data/database.dart';

/// شاشة الإعدادات — أوقات الدوام ونوافذ الحضور (تُقرأ وتُحفظ في قاعدة البيانات).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _loading = true;
  final _fields = <String, TextEditingController>{};
  String? _settingsId;

  static const _labels = {
    'day_start': 'بداية الدوام',
    'day_end': 'نهاية الدوام',
    'checkin_window_start': 'بداية نافذة الحضور',
    'checkin_window_end': 'نهاية نافذة الحضور',
    'late_after': 'وقت اعتبار التأخير',
    'auto_close_time': 'الإغلاق التلقائي',
  };

  @override
  void initState() {
    super.initState();
    for (final k in _labels.keys) {
      _fields[k] = TextEditingController();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    if (state.schoolId == null) return;
    final db = await AppDatabase.instance.database;
    final rows = await db.query('attendance_settings',
        where: 'school_id = ? AND scope = ?', whereArgs: [state.schoolId, 'school'], limit: 1);
    if (rows.isNotEmpty) {
      _settingsId = rows.first['id'] as String;
      for (final k in _labels.keys) {
        _fields[k]!.text = (rows.first[k] as String?) ?? '';
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    final values = {
      for (final e in _fields.entries) e.key: e.value.text.trim(),
      'updated_at': now,
    };
    if (_settingsId != null) {
      await db.update('attendance_settings', values, where: 'id = ?', whereArgs: [_settingsId]);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ الإعدادات')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('أوقات الدوام والحضور', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                ..._labels.entries.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextField(
                        controller: _fields[e.key],
                        decoration: InputDecoration(
                          labelText: e.value,
                          hintText: 'مثال: 07:30',
                          prefixIcon: const Icon(Icons.access_time),
                        ),
                      ),
                    )),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save),
                  label: const Text('حفظ الإعدادات'),
                ),
              ],
            ),
    );
  }
}
