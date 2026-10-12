import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../data/school_settings_repository.dart';

/// شاشة الإعدادات — أوقات الدوام ونوافذ الحضور + أيام الدوام + الاستراحات + العطل + قواعد الانصراف.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _loading = true;
  final _fields = <String, TextEditingController>{};
  final _checkoutFields = <String, TextEditingController>{};
  String? _schoolId;
  Set<int> _workingDays = {7, 1, 2, 3, 4};
  List<BreakSlot> _breaks = [];
  List<Holiday> _holidays = [];

  final _repo = SchoolSettingsRepository();

  static const _labels = {
    'day_start': 'بداية الدوام',
    'day_end': 'نهاية الدوام',
    'checkin_window_start': 'بداية نافذة الحضور',
    'checkin_window_end': 'نهاية نافذة الحضور',
    'late_after': 'وقت اعتبار التأخير',
    'auto_close_time': 'الإغلاق التلقائي',
  };

  static const _checkoutLabels = {
    'min_before_end': 'أدنى دقائق قبل نهاية الدوام للانصراف',
    'early_leave_before': 'حد الانصراف المبكر (قبله = انصراف مبكر)',
  };

  // weekday: 1=الاثنين ... 7=الأحد
  static const _dayNames = {1: 'الاثنين', 2: 'الثلاثاء', 3: 'الأربعاء', 4: 'الخميس', 5: 'الجمعة', 6: 'السبت', 7: 'الأحد'};

  bool get _canEdit => context.read<AppState>().can(Perms.settingsManage);

  @override
  void initState() {
    super.initState();
    for (final k in _labels.keys) {
      _fields[k] = TextEditingController();
    }
    for (final k in _checkoutLabels.keys) {
      _checkoutFields[k] = TextEditingController();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    for (final c in _checkoutFields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    _schoolId = state.schoolId;
    if (_schoolId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final row = await _repo.getSettings(_schoolId!);
    if (row != null) {
      for (final k in _labels.keys) {
        _fields[k]!.text = (row[k] as String?) ?? '';
      }
    }
    final rules = await _repo.checkoutRules(_schoolId!);
    for (final k in _checkoutFields.keys) {
      _checkoutFields[k]!.text = '${rules[k] ?? ''}';
    }
    _workingDays = await _repo.workingDays(_schoolId!);
    _breaks = await _repo.breaks(_schoolId!);
    _holidays = await _repo.holidays(_schoolId!);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (_schoolId == null) return;
    final values = {for (final e in _fields.entries) e.key: e.value.text.trim()};
    await _repo.saveSettings(_schoolId!, values);
    await _repo.saveWorkingDays(_schoolId!, _workingDays);
    await _repo.saveBreaks(_schoolId!, _breaks);
    final rules = <String, dynamic>{
      'min_before_end': int.tryParse(_checkoutFields['min_before_end']!.text.trim()) ?? 0,
      'early_leave_before': _checkoutFields['early_leave_before']!.text.trim(),
    };
    await _repo.saveCheckoutRules(_schoolId!, rules);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ الإعدادات')));
  }

  Future<void> _addBreak() async {
    final label = TextEditingController(text: 'استراحة');
    final start = TextEditingController(text: '10:00');
    final end = TextEditingController(text: '10:30');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة استراحة'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: label, decoration: const InputDecoration(labelText: 'الاسم')),
          TextField(controller: start, decoration: const InputDecoration(labelText: 'البداية (HH:MM)')),
          TextField(controller: end, decoration: const InputDecoration(labelText: 'النهاية (HH:MM)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إضافة')),
        ],
      ),
    );
    if (ok == true) {
      setState(() => _breaks.add(BreakSlot(label: label.text.trim(), start: start.text.trim(), end: end.text.trim())));
    }
  }

  Future<void> _addHoliday() async {
    if (_schoolId == null) return;
    final title = TextEditingController();
    final from = TextEditingController(text: SchoolSettingsRepository.dateOnly(DateTime.now()));
    final to = TextEditingController(text: SchoolSettingsRepository.dateOnly(DateTime.now()));
    String type = 'official';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('إضافة عطلة'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: 'المناسبة')),
            TextField(controller: from, decoration: const InputDecoration(labelText: 'من (YYYY-MM-DD)')),
            TextField(controller: to, decoration: const InputDecoration(labelText: 'إلى (YYYY-MM-DD)')),
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'النوع'),
              items: const [
                DropdownMenuItem(value: 'official', child: Text('عطلة رسمية')),
                DropdownMenuItem(value: 'exception', child: Text('استثناء/دوام خاص')),
              ],
              onChanged: (v) => setSt(() => type = v ?? 'official'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إضافة')),
          ],
        ),
      ),
    );
    if (ok == true) {
      await _repo.addHoliday(
        _schoolId!,
        Holiday(id: '', dateFrom: from.text.trim(), dateTo: to.text.trim(), type: type, title: title.text.trim()),
      );
      _holidays = await _repo.holidays(_schoolId!);
      if (mounted) setState(() {});
    }
  }

  Future<void> _deleteHoliday(String id) async {
    await _repo.removeHoliday(id);
    if (_schoolId == null) return;
    _holidays = await _repo.holidays(_schoolId!);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _schoolId == null
              ? const Center(child: Text('لا توجد مدرسة نشطة'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _section('أوقات الدوام والحضور', [
                      ..._labels.entries.map((e) => _timeField(_fields[e.key]!, e.value)),
                    ]),
                    _section('أيام الدوام الأسبوعية', [
                      Wrap(
                        spacing: 8,
                        children: _dayNames.entries.map((e) {
                          final selected = _workingDays.contains(e.key);
                          return FilterChip(
                            label: Text(e.value),
                            selected: selected,
                            onSelected: _canEdit
                                ? (v) => setState(() => v ? _workingDays.add(e.key) : _workingDays.remove(e.key))
                                : null,
                          );
                        }).toList(),
                      ),
                    ]),
                    _section('الاستراحات', [
                      if (_breaks.isEmpty) const Text('لا توجد استراحات', style: TextStyle(color: AppTheme.textMuted)),
                      ..._breaks.asMap().entries.map((e) => Card(
                            child: ListTile(
                              leading: const Icon(Icons.free_breakfast, color: AppTheme.primary),
                              title: Text(e.value.label),
                              subtitle: Text('${e.value.start} - ${e.value.end}'),
                              trailing: _canEdit
                                  ? IconButton(
                                      icon: const Icon(Icons.delete, color: AppTheme.danger),
                                      onPressed: () => setState(() => _breaks.removeAt(e.key)),
                                    )
                                  : null,
                            ),
                          )),
                      if (_canEdit)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                              onPressed: _addBreak, icon: const Icon(Icons.add), label: const Text('إضافة استراحة')),
                        ),
                    ]),
                    _section('قواعد الانصراف', [
                      ..._checkoutLabels.entries.map((e) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: TextField(
                              controller: _checkoutFields[e.key],
                              enabled: _canEdit,
                              decoration: InputDecoration(labelText: e.value, prefixIcon: const Icon(Icons.timer)),
                            ),
                          )),
                    ]),
                    _section('العطل والاستثناءات', [
                      if (_holidays.isEmpty) const Text('لا توجد عطل مسجّلة', style: TextStyle(color: AppTheme.textMuted)),
                      ..._holidays.map((h) => Card(
                            child: ListTile(
                              leading: Icon(h.type == 'official' ? Icons.beach_access : Icons.event_available,
                                  color: h.type == 'official' ? AppTheme.warning : AppTheme.success),
                              title: Text(h.title?.isNotEmpty == true ? h.title! : 'عطلة'),
                              subtitle: Text('${h.dateFrom} → ${h.dateTo}  •  ${h.type == 'official' ? 'رسمية' : 'استثناء'}'),
                              trailing: _canEdit
                                  ? IconButton(
                                      icon: const Icon(Icons.delete, color: AppTheme.danger),
                                      onPressed: () => _deleteHoliday(h.id),
                                    )
                                  : null,
                            ),
                          )),
                      if (_canEdit)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                              onPressed: _addHoliday, icon: const Icon(Icons.add), label: const Text('إضافة عطلة')),
                        ),
                    ]),
                    const SizedBox(height: 8),
                    if (_canEdit)
                      ElevatedButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.save),
                        label: const Text('حفظ الإعدادات'),
                      ),
                  ],
                ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: AppTheme.primaryDark)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _timeField(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          enabled: _canEdit,
          decoration: InputDecoration(labelText: label, hintText: 'مثال: 07:30', prefixIcon: const Icon(Icons.access_time)),
        ),
      );
}
