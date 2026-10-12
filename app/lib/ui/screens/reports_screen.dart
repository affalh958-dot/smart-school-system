import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../data/report_service.dart';
import '../../data/reports_repository.dart';

/// شاشة التقارير — تقارير حقيقية من قاعدة البيانات مع طباعة PDF وتصدير Excel.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  final _repo = ReportsRepository();
  DateTime _from = DateTime.now();
  DateTime _to = DateTime.now();
  String _type = 'daily';
  List<Map<String, dynamic>> _rows = [];
  bool _loading = false;
  bool _fontsReady = false;

  static const _types = <String, String>{
    'daily': 'تقرير الحضور اليومي',
    'late': 'قائمة المتأخرين',
    'not_recorded': 'الطلاب الذين لم يسجّلوا حضوراً',
    'range': 'ملخص الغياب (نطاق زمني)',
    'by_grade': 'نسب الحضور حسب الصف والشعبة',
    'failed': 'الحالات التي فشل فيها التعرّف',
    'devices': 'الأجهزة التي سجّلت الحضور',
    'audit': 'سجل تعديلات الحضور',
    'eval_range': 'تقييمات أسبوعية (نطاق زمني)',
    'eval_cumulative': 'المعدّل التراكمي لكل طالب',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadFonts();
      await _load();
    });
  }

  Future<void> _loadFonts() async {
    try {
      final reg = await rootBundle.load('assets/fonts/NotoNaskhArabic-Regular.ttf');
      final latin = await rootBundle.load('assets/fonts/Roboto-Regular.ttf');
      await ReportService.loadFonts(reg, latin);
      _fontsReady = true;
    } catch (_) {
      _fontsReady = false;
    }
  }

  String get _schoolId => context.read<AppState>().schoolId ?? '';
  String get _schoolName => context.read<AppState>().schoolName;

  String _d(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    if (_schoolId.isEmpty) return;
    setState(() => _loading = true);
    final from = _d(_from);
    final to = _d(_to);
    List<Map<String, dynamic>> rows;
    switch (_type) {
      case 'daily':
        rows = await _repo.dailyAttendance(_schoolId, from);
        break;
      case 'late':
        rows = await _repo.late(_schoolId, from);
        break;
      case 'not_recorded':
        rows = await _repo.notRecorded(_schoolId, from);
        break;
      case 'range':
        rows = await _repo.rangeSummary(_schoolId, from, to);
        break;
      case 'by_grade':
        rows = await _repo.byGradeSection(_schoolId, from, to);
        break;
      case 'failed':
        rows = await _repo.failedRecognitions(_schoolId, from, to);
        break;
      case 'devices':
        rows = await _repo.devicesReport(_schoolId, from, to);
        break;
      case 'audit':
        rows = await _repo.attendanceAudit(_schoolId, 500);
        break;
      case 'eval_range':
        rows = await _repo.evaluationsBySubject(_schoolId, from, to);
        break;
      case 'eval_cumulative':
        rows = await _repo.cumulativeEvaluationSummary(_schoolId);
        break;
      default:
        rows = [];
    }
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  List<ReportColumn> get _columns {
    switch (_type) {
      case 'daily':
        return [
          ReportColumn(title: 'الرقم', value: (r) => '${r['student_number']}'),
          ReportColumn(title: 'الاسم', value: (r) => '${r['full_name']}'),
          ReportColumn(title: 'الصف', value: (r) => '${r['grade_name'] ?? '-'}'),
          ReportColumn(title: 'الشعبة', value: (r) => '${r['section_name'] ?? '-'}'),
          ReportColumn(title: 'الحالة', value: (r) => _statusLabel('${r['status']}')),
          ReportColumn(title: 'الوقت', value: (r) => _time('${r['recorded_at']}')),
        ];
      case 'late':
        return [
          ReportColumn(title: 'الرقم', value: (r) => '${r['student_number']}'),
          ReportColumn(title: 'الاسم', value: (r) => '${r['full_name']}'),
          ReportColumn(title: 'الصف', value: (r) => '${r['grade_name'] ?? '-'}'),
          ReportColumn(title: 'الشعبة', value: (r) => '${r['section_name'] ?? '-'}'),
          ReportColumn(title: 'وقت التسجيل', value: (r) => _time('${r['recorded_at']}')),
        ];
      case 'not_recorded':
        return [
          ReportColumn(title: 'الرقم', value: (r) => '${r['student_number']}'),
          ReportColumn(title: 'الاسم', value: (r) => '${r['full_name']}'),
          ReportColumn(title: 'الصف', value: (r) => '${r['grade_name'] ?? '-'}'),
          ReportColumn(title: 'الشعبة', value: (r) => '${r['section_name'] ?? '-'}'),
        ];
      case 'range':
        return [
          ReportColumn(title: 'الرقم', value: (r) => '${r['student_number']}'),
          ReportColumn(title: 'الاسم', value: (r) => '${r['full_name']}'),
          ReportColumn(title: 'حاضر', value: (r) => '${r['present_count']}'),
          ReportColumn(title: 'متأخر', value: (r) => '${r['late_count']}'),
          ReportColumn(title: 'غائب', value: (r) => '${r['absent_count']}'),
          ReportColumn(title: 'بعذر', value: (r) => '${r['excused_count']}'),
        ];
      case 'by_grade':
        return [
          ReportColumn(title: 'الصف', value: (r) => '${r['grade_name'] ?? '-'}'),
          ReportColumn(title: 'الشعبة', value: (r) => '${r['section_name'] ?? '-'}'),
          ReportColumn(title: 'الحاضرون', value: (r) => '${r['attended']}'),
          ReportColumn(title: 'الإجمالي', value: (r) => '${r['total']}'),
          ReportColumn(
              title: 'النسبة %',
              value: (r) {
                final t = (r['total'] as num?)?.toDouble() ?? 0;
                final a = (r['attended'] as num?)?.toDouble() ?? 0;
                return t == 0 ? '0' : (a * 100 / t).toStringAsFixed(1);
              }),
        ];
      case 'failed':
        return [
          ReportColumn(title: 'النتيجة', value: (r) => _resultLabel('${r['result']}')),
          ReportColumn(title: 'العدد', value: (r) => '${r['c']}'),
        ];
      case 'devices':
        return [
          ReportColumn(title: 'الجهاز', value: (r) => '${r['device_id']}'),
          ReportColumn(title: 'عدد السجلات', value: (r) => '${r['c']}'),
        ];
      case 'audit':
        return [
          ReportColumn(title: 'الوقت', value: (r) => _time('${r['changed_at']}')),
          ReportColumn(title: 'الطالب', value: (r) => '${r['full_name']}'),
          ReportColumn(title: 'من', value: (r) => _statusLabel('${r['old_status']}')),
          ReportColumn(title: 'إلى', value: (r) => _statusLabel('${r['new_status']}')),
          ReportColumn(title: 'بواسطة', value: (r) => '${r['changed_by_name'] ?? '-'}'),
          ReportColumn(title: 'السبب', value: (r) => '${r['reason']}'),
        ];
      case 'eval_range':
        return [
          ReportColumn(title: 'الرقم', value: (r) => '${r['student_number']}'),
          ReportColumn(title: 'الاسم', value: (r) => '${r['full_name']}'),
          ReportColumn(title: 'الصف', value: (r) => '${r['grade_name'] ?? '-'}'),
          ReportColumn(title: 'الشعبة', value: (r) => '${r['section_name'] ?? '-'}'),
          ReportColumn(title: 'المادة', value: (r) => '${r['subject_name']}'),
          ReportColumn(title: 'الأسبوع', value: (r) => '${r['week_no']}'),
          ReportColumn(title: 'الدرجة', value: (r) => '${r['score']} / ${r['max_score']}'),
          ReportColumn(title: 'ملاحظة', value: (r) => '${r['comment'] ?? ''}'),
        ];
      case 'eval_cumulative':
        return [
          ReportColumn(title: 'الرقم', value: (r) => '${r['student_number']}'),
          ReportColumn(title: 'الاسم', value: (r) => '${r['full_name']}'),
          ReportColumn(title: 'الصف', value: (r) => '${r['grade_name'] ?? '-'}'),
          ReportColumn(title: 'الشعبة', value: (r) => '${r['section_name'] ?? '-'}'),
          ReportColumn(title: 'عدد الأسابيع', value: (r) => '${r['weeks']}'),
          ReportColumn(title: 'المعدّل %', value: (r) => '${r['avg_pct'] ?? '-'}'),
        ];
      default:
        return [];
    }
  }

  ReportData _buildReport() {
    final isSingleDay = {'daily', 'late', 'not_recorded'}.contains(_type);
    return ReportData(
      schoolName: _schoolName.isEmpty ? 'المدرسة' : _schoolName,
      title: _types[_type] ?? 'تقرير',
      period: isSingleDay ? _d(_from) : '${_d(_from)} — ${_d(_to)}',
      columns: _columns,
      rows: _rows,
    );
  }

  Future<void> _exportPdf() async {
    if (_rows.isEmpty) {
      _snack('لا توجد بيانات للتصدير');
      return;
    }
    if (!_fontsReady) {
      _snack('تعذّر تحميل الخط العربي');
      return;
    }
    final bytes = await ReportService.toPdf(_buildReport());
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: '${_types[_type]}.pdf');
  }

  Future<void> _exportExcel() async {
    if (_rows.isEmpty) {
      _snack('لا توجد بيانات للتصدير');
      return;
    }
    final bytes = ReportService.toExcel(_buildReport());
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, '${_types[_type]}_${_d(DateTime.now())}.xlsx'));
    await file.writeAsBytes(bytes);
    if (!mounted) return;
    await Share.shareXFiles([XFile(file.path)], text: _types[_type]);
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  String _time(String iso) {
    if (iso.length >= 16) return iso.substring(11, 16);
    return iso;
  }

  String _statusLabel(String s) => switch (s) {
        'present' => 'حاضر',
        'late' => 'متأخر',
        'absent' => 'غائب',
        'excused' => 'غياب بعذر',
        'early_leave' => 'انصراف مبكر',
        _ => s,
      };

  String _resultLabel(String r) => switch (r) {
        'no_match' => 'لا تطابق',
        'ambiguous' => 'التباس',
        'low_quality' => 'جودة منخفضة',
        'spoof' => 'محاولة انتحال',
        'matched' => 'مطابق',
        _ => r,
      };

  @override
  Widget build(BuildContext context) {
    final cols = _columns;
    return Scaffold(
      appBar: AppBar(title: const Text('التقارير')),
      body: Column(
        children: [
          _filters(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? const Center(child: Text('لا توجد بيانات في هذه الفترة'))
                    : _table(cols),
          ),
          _exportBar(),
        ],
      ),
    );
  }

  Widget _filters() {
    final isSingleDay = {'daily', 'late', 'not_recorded'}.contains(_type);
    return Card(
      margin: const EdgeInsets.all(10),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(labelText: 'نوع التقرير', prefixIcon: Icon(Icons.description)),
              items: _types.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) {
                setState(() => _type = v ?? 'daily');
                _load();
              },
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _dateField('من', _from, (d) => setState(() => _from = d))),
              if (!isSingleDay) ...[
                const SizedBox(width: 8),
                Expanded(child: _dateField('إلى', _to, (d) => setState(() => _to = d))),
              ],
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('عرض'),
                ),
              ),
              const SizedBox(width: 8),
              Chip(label: Text('${_rows.length} سجل')),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _dateField(String label, DateTime value, ValueChanged<DateTime> onPick) {
    return OutlinedButton.icon(
      icon: const Icon(Icons.calendar_today, size: 16),
      label: Text('$label: ${_d(value)}'),
      onPressed: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value,
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
        );
        if (picked != null) {
          onPick(picked);
        }
      },
    );
  }

  Widget _table(List<ReportColumn> cols) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        child: DataTable(
          headingRowColor: WidgetStateProperty.all(AppTheme.primary.withValues(alpha: 0.08)),
          columns: cols.map((c) => DataColumn(label: Text(c.title, style: const TextStyle(fontWeight: FontWeight.bold)))).toList(),
          rows: _rows
              .map((r) => DataRow(cells: cols.map((c) => DataCell(Text(c.value(r)))).toList()))
              .toList(),
        ),
      ),
    );
  }

  Widget _exportBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _exportPdf,
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('طباعة / PDF'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _exportExcel,
              icon: const Icon(Icons.table_view),
              label: const Text('تصدير Excel'),
            ),
          ),
        ]),
      ),
    );
  }
}
