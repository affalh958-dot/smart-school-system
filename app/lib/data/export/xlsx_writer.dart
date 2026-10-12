import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// مُولّد ملفات XLSX بسيط يعمل دون إنترنت (بدون حزم خارجية).
/// يبني حزمة OOXML بحد أدنى صحيح: [Content_Types] + relationships + sheet.
class XlsxWriter {
  /// يبني ملف xlsx من ورقة واحدة.
  /// [rows]: قائمة صفوف، كل صف قائمة خلايا (String أو num أو null).
  static Uint8List build({required String sheetName, required List<List<dynamic>> rows}) {
    final archive = Archive();
    void add(String path, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    add('[Content_Types].xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>''');

    add('_rels/.rels', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>''');

    add('xl/workbook.xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets><sheet name="${_escape(sheetName)}" sheetId="1" r:id="rId1"/></sheets>
</workbook>''');

    add('xl/_rels/workbook.xml.rels', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>''');

    final sb = StringBuffer();
    sb.write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
    sb.write('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>');
    for (var r = 0; r < rows.length; r++) {
      final rowNum = r + 1;
      sb.write('<row r="$rowNum">');
      final row = rows[r];
      for (var c = 0; c < row.length; c++) {
        final ref = '${_colName(c)}$rowNum';
        final value = row[c];
        if (value == null) continue;
        if (value is num) {
          sb.write('<c r="$ref"><v>$value</v></c>');
        } else {
          sb.write('<c r="$ref" t="inlineStr"><is><t xml:space="preserve">${_escape(value.toString())}</t></is></c>');
        }
      }
      sb.write('</row>');
    }
    sb.write('</sheetData></worksheet>');
    add('xl/worksheets/sheet1.xml', sb.toString());

    final zipped = ZipEncoder().encode(archive);
    return Uint8List.fromList(zipped);
  }

  static String _colName(int index) {
    var i = index;
    var name = '';
    while (i >= 0) {
      name = String.fromCharCode(65 + (i % 26)) + name;
      i = (i ~/ 26) - 1;
    }
    return name;
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
