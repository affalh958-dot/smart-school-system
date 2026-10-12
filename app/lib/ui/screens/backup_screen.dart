import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/backup_repository.dart';

/// شاشة النسخ الاحتياطي والاستعادة — متاحة لمسؤول النظام والمالك.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _repo = BackupRepository();
  List<File> _files = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final files = await _repo.listBackups();
    if (mounted) setState(() => _files = files);
  }

  String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} ك.ب'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(2)} م.ب';

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final path = await _repo.createBackup(createdBy: context.read<AppState>().primaryRole);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم إنشاء نسخة احتياطية: ${path.split(Platform.pathSeparator).last}')),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذّر إنشاء النسخة: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(File f) async {
    await Share.shareXFiles([XFile(f.path)], text: 'نسخة احتياطية لقاعدة بيانات المدرسة');
  }

  Future<void> _restore(File f) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('تأكيد الاستعادة'),
        content: Text(
            'سيتم استبدال البيانات الحالية بمحتوى النسخة:\n${f.path.split(Platform.pathSeparator).last}\n\n'
            'سيتم أخذ نسخة أمان تلقائياً قبل الاستبدال. هل تريد المتابعة؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('استعادة')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await _repo.restoreBackup(f.path, restoredBy: state.primaryRole);
      if (!mounted) return;
      messenger.showSnackBar(
          const SnackBar(content: Text('تمت الاستعادة بنجاح. يُفضّل إعادة تشغيل التطبيق.')));
      await _load();
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('تعذّرت الاستعادة: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('النسخ الاحتياطي والاستعادة'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _create,
                icon: const Icon(Icons.backup),
                label: const Text('إنشاء نسخة احتياطية الآن'),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _files.isEmpty
                ? const Center(child: Text('لا توجد نسخ احتياطية بعد'))
                : ListView.separated(
                    itemCount: _files.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final f = _files[i];
                      final stat = f.statSync();
                      return ListTile(
                        leading: const Icon(Icons.archive, color: AppTheme.primary),
                        title: Text(f.path.split(Platform.pathSeparator).last,
                            style: const TextStyle(fontSize: 13)),
                        subtitle: Text(
                            '${stat.modified.toString().split('.').first}  •  ${_size(stat.size)}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'مشاركة/تنزيل',
                              onPressed: _busy ? null : () => _share(f),
                              icon: const Icon(Icons.ios_share),
                            ),
                            IconButton(
                              tooltip: 'استعادة',
                              onPressed: _busy ? null : () => _restore(f),
                              icon: const Icon(Icons.restore, color: AppTheme.warning),
                            ),
                          ],
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
