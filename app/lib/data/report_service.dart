import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'export/xlsx_writer.dart';

/// عمود في تقرير: العنوان + كيف يُقرأ من الصف.
class ReportColumn {
  final String title;
  final String Function(Map<String, dynamic> row) value;
  final double width;
  ReportColumn({required this.title, required this.value, this.width = 1});
}

/// تقرير جاهز للطباعة/التصدير: العنوان، الأعمدة، والصفوف.
class ReportData {
  final String schoolName;
  final String title;
  final String period;
  final List<ReportColumn> columns;
  final List<Map<String, dynamic>> rows;
  ReportData({
    required this.schoolName,
    required this.title,
    required this.period,
    required this.columns,
    required this.rows,
  });
}

/// خدمة توليد التقارير PDF و Excel — تعمل دون إنترنت، بخط عربي مدمج.
class ReportService {
  static pw.Font? _arabicFont;
  static pw.Font? _arabicBold;
  static pw.Font? _latinFallback;

  /// يحمّل خط Noto Naskh Arabic من الأصول، مع خط لاتيني احتياطي للأرقام والرموز.
  static Future<void> loadFonts(ByteData regular, [ByteData? latin]) async {
    _arabicFont = pw.Font.ttf(regular);
    _arabicBold = _arabicFont;
    if (latin != null) _latinFallback = pw.Font.ttf(latin);
  }

  static pw.Font get _font => _arabicFont ?? pw.Font.helvetica();

  /// احتياطي لرسم الأرقام والرموز غير الموجودة في الخط العربي.
  static List<pw.Font> get _fallback =>
      _latinFallback != null ? [_latinFallback!] : const [];

  /// بناء ملف PDF عربي RTL بجدول كامل.
  static Future<Uint8List> toPdf(ReportData report) async {
    final doc = pw.Document();
    final headers = report.columns.map((c) => c.title).toList();
    final data = report.rows
        .map((r) => report.columns.map((c) => c.value(r)).toList())
        .toList();

    final now = DateTime.now();
    final generated = '${now.year}-${_p(now.month)}-${_p(now.day)} ${_p(now.hour)}:${_p(now.minute)}';

    doc.addPage(
      pw.MultiPage(
        textDirection: pw.TextDirection.rtl,
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        theme: pw.ThemeData.withFont(base: _font, bold: _arabicBold ?? _font, fontFallback: _fallback),
        header: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Text(report.schoolName, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 4),
            pw.Text(report.title, style: const pw.TextStyle(fontSize: 14)),
            pw.Text('الفترة: ${report.period}', style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
            pw.Divider(),
          ],
        ),
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('تاريخ الإنشاء: $generated', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
            pw.Text('صفحة ${ctx.pageNumber} / ${ctx.pagesCount}',
                style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
          ],
        ),
        build: (ctx) => [
          pw.TableHelper.fromTextArray(
            headers: headers,
            data: data,
            headerStyle: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
            cellStyle: const pw.TextStyle(fontSize: 10),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
            cellAlignment: pw.Alignment.centerRight,
            headerAlignment: pw.Alignment.centerRight,
          ),
        ],
      ),
    );
    return doc.save();
  }

  /// بناء ملف Excel (xlsx) بأعمدة التقرير.
  static Uint8List toExcel(ReportData report) {
    final rows = <List<dynamic>>[];
    rows.add([report.schoolName]);
    rows.add([report.title]);
    rows.add(['الفترة', report.period]);
    rows.add([]);
    rows.add(report.columns.map((c) => c.title).toList());
    for (final r in report.rows) {
      rows.add(report.columns.map((c) => c.value(r)).toList());
    }
    return XlsxWriter.build(sheetName: report.title, rows: rows);
  }

  static String _p(int v) => v.toString().padLeft(2, '0');
}
