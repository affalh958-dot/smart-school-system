import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_app/data/export/xlsx_writer.dart';
import 'package:school_app/data/report_service.dart';

/// اختبارات التصدير: xlsx صالح قابل للقراءة، وPDF يُبنى دون أخطاء.
void main() {
  test('XLSX يُبنى ويحتوي الأوراق المطلوبة', () {
    final bytes = XlsxWriter.build(sheetName: 'تقرير الحضور', rows: [
      ['المدرسة النموذجية'],
      ['الرقم', 'الاسم', 'الحالة'],
      ['1001', 'أحمد علي', 'حاضر'],
      ['1002', 'سارة محمد', 'متأخر'],
    ]);
    expect(bytes.length, greaterThan(0));
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = archive.files.map((f) => f.name).toList();
    expect(names, contains('[Content_Types].xml'));
    expect(names, contains('xl/workbook.xml'));
    expect(names, contains('xl/worksheets/sheet1.xml'));
    final sheet = utf8.decode(archive.findFile('xl/worksheets/sheet1.xml')!.content as List<int>);
    expect(sheet, contains('أحمد علي'));
    expect(sheet, contains('1001'));
  });

  test('PDF يُبنى من بيانات التقرير', () async {
    // تحميل الخط العربي + الخط اللاتيني الاحتياطي للتحقق من العرض الكامل.
    final fontBytes = File('assets/fonts/NotoNaskhArabic-Regular.ttf').readAsBytesSync();
    final latinBytes = File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync();
    await ReportService.loadFonts(
      ByteData.view(Uint8List.fromList(fontBytes).buffer),
      ByteData.view(Uint8List.fromList(latinBytes).buffer),
    );
    final report = ReportData(
      schoolName: 'المدرسة النموذجية',
      title: 'تقرير الحضور اليومي',
      period: '2026-01-01',
      columns: [
        ReportColumn(title: 'الرقم', value: (r) => '${r['n']}'),
        ReportColumn(title: 'الاسم', value: (r) => '${r['name']}'),
      ],
      rows: [
        {'n': '1001', 'name': 'أحمد علي'},
        {'n': '1002', 'name': 'سارة محمد'},
      ],
    );
    final bytes = await ReportService.toPdf(report);
    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });

  test('Excel من بيانات التقرير صالح', () {
    final report = ReportData(
      schoolName: 'مدرسة',
      title: 'تقرير',
      period: '2026',
      columns: [ReportColumn(title: 'الاسم', value: (r) => '${r['name']}')],
      rows: [
        {'name': 'طالب'}
      ],
    );
    final bytes = ReportService.toExcel(report);
    final archive = ZipDecoder().decodeBytes(Uint8List.fromList(bytes));
    expect(archive.files.any((f) => f.name == 'xl/worksheets/sheet1.xml'), isTrue);
  });
}
