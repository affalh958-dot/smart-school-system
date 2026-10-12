import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/repositories.dart';

/// شاشة الطلاب — بسيطة: بحث + إضافة + عرض الملف.
class StudentsScreen extends StatefulWidget {
  const StudentsScreen({super.key});

  @override
  State<StudentsScreen> createState() => _StudentsScreenState();
}

class _StudentsScreenState extends State<StudentsScreen> {
  final _searchCtrl = TextEditingController();
  List<Student> _results = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search(''));
  }

  Future<void> _search(String q) async {
    final state = context.read<AppState>();
    if (state.schoolId == null) return;
    setState(() => _loading = true);
    final list = await StudentRepository().search(state.schoolId!, q, limit: 100);
    if (!mounted) return;
    setState(() {
      _results = list;
      _loading = false;
    });
  }

  Future<void> _addStudent() async {
    final state = context.read<AppState>();
    if (state.schoolId == null) return;
    final numberCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة طالب جديد'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: numberCtrl, decoration: const InputDecoration(labelText: 'الرقم المدرسي')),
            const SizedBox(height: 12),
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'الاسم الكامل')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حفظ')),
        ],
      ),
    );
    if (ok != true) return;
    if (numberCtrl.text.trim().isEmpty || nameCtrl.text.trim().isEmpty) return;

    final existing = await StudentRepository().byNumber(state.schoolId!, numberCtrl.text.trim());
    if (existing != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرقم المدرسي مستخدم مسبقاً')),
      );
      return;
    }

    await StudentRepository().create(Student(
      id: '',
      schoolId: state.schoolId!,
      studentNumber: numberCtrl.text.trim(),
      fullName: nameCtrl.text.trim(),
    ));
    await _search(_searchCtrl.text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الطلاب')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addStudent,
        icon: const Icon(Icons.person_add),
        label: const Text('طالب جديد'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                hintText: 'ابحث بالاسم أو الرقم المدرسي',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _search,
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                    ? const Center(child: Text('لا توجد نتائج'))
                    : ListView.builder(
                        itemCount: _results.length,
                        itemBuilder: (ctx, i) {
                          final s = _results[i];
                          return Card(
                            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            child: ListTile(
                              leading: const CircleAvatar(child: Icon(Icons.person)),
                              title: Text(s.fullName),
                              subtitle: Text('الرقم: ${s.studentNumber}'),
                              trailing: Chip(
                                label: Text(_statusLabel(s.status), style: const TextStyle(fontSize: 11)),
                                backgroundColor: AppTheme.success.withValues(alpha: 0.1),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'active':
        return 'مستمر';
      case 'transferred':
        return 'منقول';
      case 'graduated':
        return 'متخرج';
      case 'withdrawn':
        return 'منسحب';
      default:
        return s;
    }
  }
}
