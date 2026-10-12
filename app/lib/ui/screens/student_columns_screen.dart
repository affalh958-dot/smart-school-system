import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/student_columns_repository.dart';

/// إدارة الحقول الإضافية لملف الطالب — يحدّدها المدير/مسؤول النظام.
class StudentColumnsScreen extends StatefulWidget {
  const StudentColumnsScreen({super.key});

  @override
  State<StudentColumnsScreen> createState() => _StudentColumnsScreenState();
}

class _StudentColumnsScreenState extends State<StudentColumnsScreen> {
  final _repo = StudentColumnsRepository();
  List<StudentColumn> _columns = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  String? get _schoolId => context.read<AppState>().schoolId;

  Future<void> _load() async {
    final schoolId = _schoolId;
    if (schoolId == null) return;
    setState(() => _loading = true);
    final cols = await _repo.columns(schoolId);
    if (!mounted) return;
    setState(() {
      _columns = cols;
      _loading = false;
    });
  }

  Future<void> _add() async {
    final schoolId = _schoolId;
    if (schoolId == null) return;
    final labelCtrl = TextEditingController();
    String type = 'text';
    bool required = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        return AlertDialog(
          title: const Text('حقل إضافي جديد'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: labelCtrl, decoration: const InputDecoration(labelText: 'اسم الحقل')),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'النوع'),
              items: const [
                DropdownMenuItem(value: 'text', child: Text('نص')),
                DropdownMenuItem(value: 'number', child: Text('رقم')),
                DropdownMenuItem(value: 'date', child: Text('تاريخ')),
                DropdownMenuItem(value: 'bool', child: Text('نعم/لا')),
              ],
              onChanged: (v) => setDlg(() => type = v ?? 'text'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: required,
              onChanged: (v) => setDlg(() => required = v ?? false),
              title: const Text('حقل إلزامي'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إضافة')),
          ],
        );
      }),
    );
    if (ok != true || labelCtrl.text.trim().isEmpty) return;
    await _repo.addColumn(
      schoolId: schoolId,
      label: labelCtrl.text.trim(),
      dataType: type,
      isRequired: required,
      orderIndex: _columns.length,
    );
    await _load();
  }

  Future<void> _archive(StudentColumn c) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('أرشفة الحقل'),
        content: Text('سيتم إخفاء الحقل «${c.label}» عن النماذج مع الاحتفاظ بقيمه التاريخية. متابعة؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('أرشفة')),
        ],
      ),
    );
    if (confirm != true) return;
    await _repo.archiveColumn(c.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('حقول ملف الطالب')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('حقل جديد'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _columns.isEmpty
              ? const Center(child: Text('لا توجد حقول إضافية بعد'))
              : ListView.builder(
                  itemCount: _columns.length,
                  itemBuilder: (ctx, i) {
                    final c = _columns[i];
                    const typeLabels = {'text': 'نص', 'number': 'رقم', 'date': 'تاريخ', 'bool': 'نعم/لا'};
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: ListTile(
                        leading: const Icon(Icons.edit_note, color: AppTheme.primary),
                        title: Text(c.label),
                        subtitle: Text('${typeLabels[c.dataType] ?? c.dataType}${c.isRequired ? '  •  إلزامي' : ''}'),
                        trailing: IconButton(icon: const Icon(Icons.archive), onPressed: () => _archive(c)),
                      ),
                    );
                  },
                ),
    );
  }
}
