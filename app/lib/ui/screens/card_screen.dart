import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/report_service.dart';
import '../../data/repositories.dart';
import '../../data/student_columns_repository.dart';

/// بطاقة الطالب التعريفية — تصميم أنيق يعرض كل المعلومات المهمة،
/// مع إمكانية الطباعة (PDF بمقاس بطاقة) أو تقاسمها.
class CardScreen extends StatefulWidget {
  final String studentId;
  const CardScreen({super.key, required this.studentId});

  @override
  State<CardScreen> createState() => _CardScreenState();
}

class _CardScreenState extends State<CardScreen> {
  Map<String, dynamic>? _p;
  Map<String, String> _custom = {};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final schoolId = context.read<AppState>().schoolId;
    final profile = await StudentRepository().fullProfile(widget.studentId);
    final labels = <String, String>{};
    if (schoolId != null) {
      final cols = await StudentColumnsRepository().columns(schoolId);
      final vals = await StudentColumnsRepository().valuesForStudent(widget.studentId);
      for (final c in cols) {
        if (vals.containsKey(c.id)) labels[c.label] = vals[c.id]!;
      }
    }
    if (!mounted) return;
    setState(() {
      _p = profile;
      _custom = labels;
      _loading = false;
    });
  }

  Map<String, String> _fields() {
    final p = _p!;
    return {
      'الاسم': p['full_name'] as String,
      'الرقم المدرسي': '${p['student_number']}',
      'المرحلة': '${p['stage_name'] ?? '-'}',
      'الصف': '${p['grade_name'] ?? '-'}',
      'الشعبة': '${p['section_name'] ?? '-'}',
      'الجنس': p['gender'] == 'male' ? 'ذكر' : (p['gender'] == 'female' ? 'أنثى' : '-'),
      'تاريخ الميلاد': '${p['birth_date'] ?? '-'}',
      'ولي الأمر': '${p['guardian_name'] ?? '-'}',
      'هاتف ولي الأمر': '${p['guardian_phone'] ?? '-'}',
      'السنة الدراسية': p['academic_year_id'] != null ? 'مُسجّل' : '-',
      ..._custom,
    };
  }

  Future<void> _print() async {
    if (_p == null) return;
    final school = context.read<AppState>().schoolName;
    setState(() => _busy = true);
    try {
      final reg = await rootBundle.load('assets/fonts/NotoNaskhArabic-Regular.ttf');
      final latin = await rootBundle.load('assets/fonts/Roboto-Regular.ttf');
      await ReportService.loadFonts(reg, latin);
      final photoPath = _p!['photo_path'] as String?;
      Uint8List? photo;
      if (photoPath != null && File(photoPath).existsSync()) {
        photo = await File(photoPath).readAsBytes();
      }
      final bytes = await ReportService.toStudentCardPdf(
        schoolName: school,
        fields: _fields(),
        photo: photo,
        qrPayload: '${_p!['student_number']}',
      );
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'بطاقة-${_p!['student_number']}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذّر إنشاء البطاقة: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('بطاقة الطالب'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _print,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.print),
            tooltip: 'طباعة / تصدير PDF',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _p == null
              ? const Center(child: Text('لم يتم العثور على الطالب'))
              : Center(child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: _card())),
    );
  }

  Widget _card() {
    final p = _p!;
    final photo = p['photo_path'] as String?;
    final school = context.watch<AppState>().schoolName;
    final hasPhoto = photo != null && File(photo).existsSync();
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [AppTheme.primary, Color(0xFF0D3B66)],
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 14, offset: const Offset(0, 6))],
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          Row(children: [
            const Icon(Icons.school, color: Colors.white, size: 26),
            const SizedBox(width: 8),
            Expanded(
              child: Text(school,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          const Divider(color: Colors.white24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 42,
                backgroundColor: Colors.white24,
                backgroundImage: hasPhoto ? FileImage(File(photo)) : null,
                child: hasPhoto
                    ? null
                    : Text(p['full_name'].toString().characters.first,
                        style: const TextStyle(fontSize: 30, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p['full_name'] as String,
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    _line('الرقم المدرسي', '${p['student_number']}'),
                    _line('المرحلة / الصف', '${p['stage_name'] ?? '-'} / ${p['grade_name'] ?? '-'}'),
                    _line('الشعبة', '${p['section_name'] ?? '-'}'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.all(12),
            child: Column(children: _fields().entries.map((e) => _line(e.key, e.value)).toList()),
          ),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.qr_code_2, color: Colors.white70),
            const SizedBox(width: 6),
            Text('رقم التحقق: ${p['student_number']}',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ]),
        ],
      ),
    );
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(
            width: 120,
            child: Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600))),
        Expanded(
            child: Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 13), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}
