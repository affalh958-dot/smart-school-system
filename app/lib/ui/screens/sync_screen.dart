import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/sync_queue_repository.dart';

/// شاشة المزامنة — تعرض السجلات غير المرسلة (الطابور) والفاشلة، وتتيح المحاولة مجدداً.
///
/// تُستخدم عند انقطاع الإنترنت: تُحفظ سجلات الحضور محلياً بمعرّف فريد (client_uuid)
/// ثم تُرسل عند عودة الاتصال دون تكرار.
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _repo = SyncQueueRepository();
  bool _loading = true;
  bool _syncing = false;
  List<SyncQueueItem> _pending = [];
  List<SyncQueueItem> _failed = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final schoolId = context.read<AppState>().schoolId;
    _pending = await _repo.pending(schoolId: schoolId);
    _failed = await _repo.failed(schoolId: schoolId);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _syncNow() async {
    final schoolId = context.read<AppState>().schoolId;
    setState(() => _syncing = true);
    final result = await _repo.sync(schoolId: schoolId);
    await _load();
    if (!mounted) return;
    setState(() => _syncing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('تمت المزامنة: ${result.synced} نجح، ${result.failed} فشل، ${result.remaining} متبقٍ'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('المزامنة'),
        actions: [
          if (!_syncing)
            IconButton(tooltip: 'تحديث', icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(children: [
                  Expanded(child: _statCard('بانتظار الإرسال', '${_pending.length}', AppTheme.warning)),
                  const SizedBox(width: 8),
                  Expanded(child: _statCard('فشل الإرسال', '${_failed.length}', _failed.isEmpty ? AppTheme.textMuted : AppTheme.danger)),
                ]),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _syncing ? null : _syncNow,
                  icon: _syncing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.sync),
                  label: Text(_syncing ? 'جارٍ المزامنة...' : 'مزامنة الآن'),
                ),
                const SizedBox(height: 20),
                const Text('سجلات بانتظار الإرسال', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 8),
                if (_pending.isEmpty)
                  const Text('لا توجد سجلات معلّقة — كل شيء متزامن.', style: TextStyle(color: AppTheme.textMuted)),
                ..._pending.map(_tile),
                const SizedBox(height: 20),
                if (_failed.isNotEmpty) ...[
                  const Text('سجلات فشل إرسالها (تحتاج مراجعة)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  ..._failed.map(_tile),
                ],
              ],
            ),
    );
  }

  Widget _tile(SyncQueueItem it) {
    final student = it.payload['student_id'] ?? it.entityId;
    final date = it.payload['session_date'] ?? '';
    final type = it.payload['session_type'] == 'checkout' ? 'انصراف' : 'حضور';
    return Card(
      child: ListTile(
        leading: const Icon(Icons.cloud_upload_outlined, color: AppTheme.primary),
        title: Text('$type • $date'),
        subtitle: Text('الطالب: $student\nالمعرّف: ${it.clientUuid.substring(0, 8)}...  •  محاولات: ${it.retryCount}'),
        isThreeLine: true,
      ),
    );
  }

  Widget _statCard(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        Text(value, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(color: AppTheme.textMuted)),
      ]),
    );
  }
}
