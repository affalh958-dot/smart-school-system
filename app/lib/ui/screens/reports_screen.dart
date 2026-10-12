import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/attendance_repository.dart';
import '../../data/models.dart';

/// شاشة التقارير — بسيطة: اختر التاريخ، اعرض الحضور والغياب والتأخير.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  DateTime _date = DateTime.now();
  String _filter = 'all';
  List<AttendanceRecord> _records = [];
  Map<String, int> _stats = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  String get _dateStr =>
      '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    setState(() => _loading = true);
    final att = AttendanceRepository();
    final state = context.read<AppState>();
    final recs = await att.byDate(_dateStr, status: _filter == 'all' ? null : _filter, schoolId: state.schoolId);
    final stats = await att.dailyStats(_dateStr, schoolId: state.schoolId);
    if (!mounted) return;
    setState(() {
      _records = recs;
      _stats = stats;
      _loading = false;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _date = picked);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('التقارير')),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickDate,
                          icon: const Icon(Icons.calendar_today, size: 18),
                          label: Text(_dateStr),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _filter,
                          decoration: const InputDecoration(labelText: 'الحالة'),
                          items: const [
                            DropdownMenuItem(value: 'all', child: Text('الكل')),
                            DropdownMenuItem(value: 'present', child: Text('حاضر')),
                            DropdownMenuItem(value: 'late', child: Text('متأخر')),
                            DropdownMenuItem(value: 'absent', child: Text('غائب')),
                            DropdownMenuItem(value: 'excused', child: Text('غياب بعذر')),
                          ],
                          onChanged: (v) {
                            setState(() => _filter = v ?? 'all');
                            _load();
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      _stat('حاضر', _stats['present'] ?? 0, AppTheme.success),
                      _stat('متأخر', _stats['late'] ?? 0, AppTheme.warning),
                      _stat('غائب', _stats['absent'] ?? 0, AppTheme.danger),
                      _stat('بعذر', _stats['excused'] ?? 0, AppTheme.accent),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _records.isEmpty
                    ? const Center(child: Text('لا توجد سجلات في هذا التاريخ'))
                    : ListView.builder(
                        itemCount: _records.length,
                        itemBuilder: (ctx, i) {
                          final r = _records[i];
                          return Card(
                            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                            child: ListTile(
                              dense: true,
                              leading: Icon(_icon(r.status), color: _color(r.status)),
                              title: Text(_label(r.status)),
                              subtitle: Text('${r.recordedAt.substring(11, 16)}  •  المصدر: ${r.source == 'face' ? 'التعرّف على الوجه' : 'يدوي'}'),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, int value, Color color) {
    return Chip(
      avatar: CircleAvatar(backgroundColor: color, child: Text('$value', style: const TextStyle(color: Colors.white, fontSize: 12))),
      label: Text(label),
    );
  }

  IconData _icon(String s) => switch (s) {
        'present' => Icons.check_circle,
        'late' => Icons.schedule,
        'absent' => Icons.cancel,
        'excused' => Icons.assignment_turned_in,
        'early_leave' => Icons.exit_to_app,
        _ => Icons.circle,
      };

  Color _color(String s) => switch (s) {
        'present' => AppTheme.success,
        'late' => AppTheme.warning,
        'absent' => AppTheme.danger,
        'excused' => AppTheme.accent,
        _ => AppTheme.textMuted,
      };

  String _label(String s) => switch (s) {
        'present' => 'حاضر',
        'late' => 'متأخر',
        'absent' => 'غائب',
        'excused' => 'غياب بعذر',
        'early_leave' => 'انصراف مبكر',
        _ => s,
      };
}
