import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/import/csv_import_service.dart';
import '../../data/repositories.dart';

/// استيراد الطلاب من ملف CSV — مع معاينة ونتائج التحقق قبل الحفظ.
///
/// لا يكتب أي صف في قاعدة البيانات قبل موافقة المستخدم على المعاينة.
class StudentImportScreen extends StatefulWidget {
  const StudentImportScreen({super.key});

  @override
  State<StudentImportScreen> createState() => _StudentImportScreenState();
}

class _StudentImportScreenState extends State<StudentImportScreen> {
  final _students = StudentRepository();
  ImportParseResult? _result;
  String? _fileName;
  bool _busy = false;
  String? _summary;

  Future<void> _pickFile() async {
    const type = XTypeGroup(label: 'CSV', extensions: ['csv', 'txt']);
    final file = await openFile(acceptedTypeGroups: [type]);
    if (file == null) return;
    if (!mounted) return;
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    if (state.schoolId == null) return;

    setState(() => _busy = true);
    try {
      var content = await File(file.path).readAsString();
      if (content.startsWith('\uFEFF')) content = content.substring(1);
      final res = CsvImportService.parse(content, schoolId: state.schoolId!);
      if (!mounted) return;
      setState(() {
        _result = res;
        _fileName = file.name;
        _summary = null;
      });
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('تعذّر قراءة الملف: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadTemplate() async {
    final dir = await getSaveLocation(suggestedName: 'قالب_الطلاب.csv');
    if (dir == null) return;
    await File(dir.path).writeAsString(CsvImportService.template(), encoding: utf8);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم حفظ القالب في: ${dir.path}')));
    }
  }

  Future<void> _confirmImport() async {
    final res = _result;
    if (res == null) return;
    final valid = res.valid;
    if (valid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('لا توجد صفوف صالحة للاستيراد')));
      return;
    }
    setState(() => _busy = true);
    var created = 0;
    var skipped = 0;
    try {
      for (final row in valid) {
        try {
          await _students.create(row.student!);
          created++;
        } catch (_) {
          // غالباً تكرار الرقم المدرسي في قاعدة البيانات (قيد UNIQUE).
          skipped++;
        }
      }
      if (!mounted) return;
      setState(() {
        _summary = 'تم استيراد $created طالباً بنجاح.'
            '${skipped > 0 ? ' وتُخطّي $skipped (أرقام موجودة مسبقاً أو مكرّرة).' : ''}';
        _result = null;
        _fileName = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final res = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('استيراد الطلاب من ملف')),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _pickFile,
                        icon: const Icon(Icons.upload_file),
                        label: const Text('اختيار ملف CSV'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _downloadTemplate,
                      icon: const Icon(Icons.download),
                      label: const Text('تنزيل قالب'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'الأعمدة المدعومة: الرقم المدرسي، الاسم، الجنس، تاريخ الميلاد، هاتف الطالب، '
                  'ولي الأمر، هاتف ولي الأمر، الرقم الوطني، العنوان، ملاحظات.',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                ),
                if (_summary != null) ...[
                  const SizedBox(height: 12),
                  Card(
                    color: AppTheme.success.withValues(alpha: 0.12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle, color: AppTheme.success),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_summary!)),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          if (res == null)
            const Expanded(child: Center(child: Text('لم يتم اختيار ملف بعد')))
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('الملف: ${_fileName ?? ''}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  ...res.warnings.map((w) => Text('• $w',
                      style: const TextStyle(color: AppTheme.warning, fontSize: 13))),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _chip('صالح: ${res.valid.length}', AppTheme.success),
                      const SizedBox(width: 8),
                      _chip('مرفوض: ${res.invalid.length}', AppTheme.danger),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (res.invalid.isNotEmpty) ...[
                    const Text('الصفوف المرفوضة:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    ...res.invalid.take(30).map((r) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text('سطر ${r.line}: ${r.error}',
                              style: const TextStyle(color: AppTheme.danger, fontSize: 13)),
                        )),
                    const Divider(height: 24),
                  ],
                  const Text('الصفوف الصالحة (المرشّحة للاستيراد):',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  DataTable(
                    columnSpacing: 16,
                    headingRowHeight: 36,
                    dataRowMinHeight: 32,
                    dataRowMaxHeight: 40,
                    columns: const [
                      DataColumn(label: Text('سطر')),
                      DataColumn(label: Text('الرقم')),
                      DataColumn(label: Text('الاسم')),
                      DataColumn(label: Text('ولي الأمر')),
                    ],
                    rows: res.valid
                        .take(100)
                        .map((r) => DataRow(cells: [
                              DataCell(Text('${r.line}')),
                              DataCell(Text(r.student!.studentNumber)),
                              DataCell(Text(r.student!.fullName)),
                              DataCell(Text(r.student!.guardianName ?? '-')),
                            ]))
                        .toList(),
                  ),
                  if (res.valid.length > 100)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('... و${res.valid.length - 100} صفاً آخر',
                          style: const TextStyle(color: AppTheme.textMuted)),
                    ),
                ],
              ),
            ),
          if (res != null && res.valid.isNotEmpty)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _confirmImport,
                    icon: const Icon(Icons.save),
                    label: Text('استيراد ${res.valid.length} طالباً'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
      );
}
