import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/audit_repository.dart';

/// شاشة سجل العمليات — تُظهر آخر الإجراءات وتعديلات الحضور للمستخدمين المخوّلين.
class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final _repo = AuditRepository();
  List<Map<String, dynamic>> _ops = [];
  List<Map<String, dynamic>> _attendance = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final ops = await _repo.recent();
    final att = await _repo.attendanceAudit();
    if (!mounted) return;
    setState(() {
      _ops = ops;
      _attendance = att;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('سجل العمليات'),
        bottom: TabBar(controller: _tabs, tabs: const [
          Tab(text: 'العمليات الإدارية'),
          Tab(text: 'تعديلات الحضور'),
        ]),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(controller: _tabs, children: [_opsTab(), _attTab()]),
    );
  }

  Widget _opsTab() {
    if (_ops.isEmpty) return const Center(child: Text('لا توجد عمليات مسجّلة'));
    return ListView.builder(
      itemCount: _ops.length,
      itemBuilder: (ctx, i) {
        final r = _ops[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ListTile(
            leading: const Icon(Icons.history, color: AppTheme.primary),
            title: Text('${r['action']}'),
            subtitle: Text('${r['user_name'] ?? 'النظام'}  •  ${_fmt(r['created_at'])}'
                '${r['entity_type'] != null ? '  •  ${r['entity_type']}' : ''}'),
          ),
        );
      },
    );
  }

  Widget _attTab() {
    if (_attendance.isEmpty) return const Center(child: Text('لا توجد تعديلات على الحضور'));
    return ListView.builder(
      itemCount: _attendance.length,
      itemBuilder: (ctx, i) {
        final r = _attendance[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ListTile(
            leading: const Icon(Icons.edit_calendar, color: AppTheme.warning),
            title: Text(r['student_name'] ?? 'طالب'),
            subtitle: Text('${r['old_status']} ← ${r['new_status']}  •  ${r['user_name'] ?? '-'}\n'
                'السبب: ${r['reason']}  •  ${_fmt(r['changed_at'])}'),
            isThreeLine: true,
          ),
        );
      },
    );
  }

  String _fmt(String? iso) {
    if (iso == null) return '-';
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return iso;
    return '${d.year}/${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
