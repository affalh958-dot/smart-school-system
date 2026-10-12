import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../data/biometric_repository.dart';
import '../../data/models.dart';
import '../../data/repositories.dart';
import 'card_screen.dart';
import 'face_enroll_screen.dart';
import 'student_form_screen.dart';
import 'student_profile_screen.dart';

/// كشف الصف (roster): كل طلاب شعبة في شاشة واحدة.
/// إضافة/تعديل/حذف/تحديث طالب، تشغيل تسجيل البصمة للشعبة، وعرض الحالة.
class ClassRosterScreen extends StatefulWidget {
  final String sectionId;
  final String title;
  const ClassRosterScreen({super.key, required this.sectionId, required this.title});

  @override
  State<ClassRosterScreen> createState() => _ClassRosterScreenState();
}

class _ClassRosterScreenState extends State<ClassRosterScreen> {
  final _students = StudentRepository();
  final _bio = BiometricRepository();
  List<Student> _list = [];
  Set<String> _enrolled = {};
  bool _loading = true;
  String _query = '';
  bool _onlySpecial = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _students.bySection(widget.sectionId);
    final enrolled = await _bio.enrolledStudentIds(sectionId: widget.sectionId);
    if (!mounted) return;
    setState(() {
      _list = list;
      _enrolled = enrolled;
      _loading = false;
    });
  }

  bool _hasSpecial(Student s) =>
      (s.healthStatus != null && s.healthStatus!.trim().isNotEmpty) ||
      (s.notes != null && s.notes!.trim().isNotEmpty);

  List<Student> get _filtered {
    var list = _list;
    if (_onlySpecial) list = list.where(_hasSpecial).toList();
    if (_query.trim().isEmpty) return list;
    final q = _query.trim();
    return list
        .where((s) => s.fullName.contains(q) || s.studentNumber.contains(q))
        .toList();
  }

  int get _enrolledCount => _list.where((s) => _enrolled.contains(s.id)).length;

  Future<void> _add() async {
    final id = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => StudentFormScreen(presetSectionId: widget.sectionId)),
    );
    if (id == null) return;
    await _load();
    if (!mounted) return;
    // إضافة الوجه مباشرةً للطالب الجديد (المعلم/المدير المخوّل).
    if (context.read<AppState>().can(Perms.biometricManage)) {
      final enroll = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('تسجيل بصمة الوجه'),
          content: const Text('تمت إضافة الطالب. هل تريد تسجيل بصمة وجهه الآن؟'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('لاحقاً')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تسجيل البصمة')),
          ],
        ),
      );
      if (enroll == true && mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => FaceEnrollScreen(studentId: id, initialSectionId: widget.sectionId)),
        );
        await _load();
      }
    }
  }

  Future<void> _edit(Student s) async {
    final id = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => StudentFormScreen(existing: s)),
    );
    if (id != null) await _load();
  }

  Future<void> _archive(Student s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الطالب'),
        content: Text(
            'سيتم أرشفة ${s.fullName} (حذف منطقي) مع الاحتفاظ بسجلاته التاريخية. متابعة؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف')),
        ],
      ),
    );
    if (ok != true) return;
    await _students.archive(s.id);
    await _load();
  }

  Future<void> _revokeFace(Student s) async {
    final state = context.read<AppState>();
    await _bio.revokeForStudent(s.id);
    await state.rebuildFaceIndex();
    await _load();
  }

  Future<void> _showActions(Student s) async {
    final enrolled = _enrolled.contains(s.id);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(s.fullName, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('الرقم: ${s.studentNumber}'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.badge, color: AppTheme.primary),
            title: const Text('بطاقة الطالب التعريفية'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.push(
                  context, MaterialPageRoute(builder: (_) => CardScreen(studentId: s.id)));
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit, color: AppTheme.accent),
            title: const Text('تعديل المعلومات'),
            onTap: () {
              Navigator.pop(ctx);
              _edit(s);
            },
          ),
          ListTile(
            leading: const Icon(Icons.face_retouching_natural, color: AppTheme.success),
            title: Text(enrolled ? 'تحديث بصمة الوجه' : 'تسجيل بصمة الوجه'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => FaceEnrollScreen(studentId: s.id, initialSectionId: widget.sectionId)),
              ).then((_) => _load());
            },
          ),
          if (enrolled)
            ListTile(
              leading: const Icon(Icons.face_retouching_off, color: AppTheme.warning),
              title: const Text('تعطيل بصمة الوجه'),
              onTap: () {
                Navigator.pop(ctx);
                _revokeFace(s);
              },
            ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: AppTheme.danger),
            title: const Text('حذف (أرشفة)'),
            onTap: () {
              Navigator.pop(ctx);
              _archive(s);
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canWrite = context.watch<AppState>().can(Perms.studentWrite);
    final canBio = context.watch<AppState>().can(Perms.biometricManage);
    final list = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'تسجيل بصمات الشعبة',
            icon: const Icon(Icons.face_retouching_natural),
            onPressed: canBio
                ? () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => FaceEnrollScreen(initialSectionId: widget.sectionId)),
                    ).then((_) => _load())
                : null,
          ),
        ],
      ),
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(
              onPressed: _add, icon: const Icon(Icons.person_add), label: const Text('طالب جديد'))
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Card(
                  margin: const EdgeInsets.all(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(children: [
                      Row(children: [
                        Expanded(child: _metric('الطلاب', '${_list.length}', AppTheme.primary)),
                        const SizedBox(width: 8),
                        Expanded(child: _metric('بصمة مسجّلة', '$_enrolledCount', AppTheme.success)),
                        const SizedBox(width: 8),
                        Expanded(
                            child: _metric('ناقصة البصمة', '${_list.length - _enrolledCount}',
                                AppTheme.warning)),
                      ]),
                      const SizedBox(height: 10),
                      TextField(
                        decoration: const InputDecoration(
                            hintText: 'ابحث بالاسم أو الرقم المدرسي',
                            prefixIcon: Icon(Icons.search),
                            isDense: true),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                      const SizedBox(height: 6),
                      Row(children: [
                        FilterChip(
                          label: const Text('ذوو حالة صحية/ملاحظات'),
                          selected: _onlySpecial,
                          onSelected: (v) => setState(() => _onlySpecial = v),
                        ),
                        const Spacer(),
                        Text('الظاهر: ${_filtered.length}',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textMuted)),
                      ]),
                    ]),
                  ),
                ),
                Expanded(
                  child: list.isEmpty
                      ? const Center(child: Text('لا يوجد طلاب في هذه الشعبة'))
                      : ListView.builder(
                          itemCount: list.length,
                          itemBuilder: (ctx, i) => _tile(list[i]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _metric(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration:
          BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
      child: Column(children: [
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted)),
      ]),
    );
  }

  Widget _tile(Student s) {
    final enrolled = _enrolled.contains(s.id);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
          child: Text(s.fullName.characters.first,
              style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
        ),
        title: Text(s.fullName, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('الرقم: ${s.studentNumber}'),
            const SizedBox(width: 8),
            Icon(enrolled ? Icons.face : Icons.face_retouching_off,
                size: 15, color: enrolled ? AppTheme.success : AppTheme.warning),
            const SizedBox(width: 3),
            Text(enrolled ? 'بصمة' : 'بدون بصمة',
                style: TextStyle(
                    fontSize: 11.5, color: enrolled ? AppTheme.success : AppTheme.warning)),
          ]),
          if ((s.healthStatus ?? '').trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('⚕ ${s.healthStatus}',
                  style: const TextStyle(fontSize: 11.5, color: AppTheme.danger)),
            ),
          if ((s.notes ?? '').trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('📝 ${s.notes}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted)),
            ),
        ]),
        trailing: IconButton(
          icon: const Icon(Icons.more_vert),
          onPressed: () => _showActions(s),
        ),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => StudentProfileScreen(studentId: s.id)),
        ).then((_) => _load()),
      ),
    );
  }
}
