import 'dart:convert';

import '../models.dart';

/// صف واحد داخل ملف الاستيراد: إما صالح (مع كائن الطالب) أو مرفوض (مع السبب).
class ImportRow {
  final int line;
  final Student? student;
  final String? error;
  ImportRow({required this.line, this.student, this.error});
  bool get ok => student != null;
}

/// نتيجة تحليل ملف الاستيراد كاملةً.
class ImportParseResult {
  final List<ImportRow> rows;
  final List<String> warnings;
  ImportParseResult(this.rows, this.warnings);
  List<ImportRow> get valid => rows.where((r) => r.ok).toList();
  List<ImportRow> get invalid => rows.where((r) => !r.ok).toList();
}

/// محلّل استيراد الطلاب من CSV (يعمل دون إنترنت).
///
/// الأعمدة المدعومة (بالعربية أو الإنجليزية، والترتيب غير مهم بوجود صف رأس):
///   الرقم المدرسي | الاسم | الجنس | تاريخ الميلاد | العنوان |
///   ولي الأمر | هاتف ولي الأمر | هاتف الطالب | الرقم الوطني | ملاحظات
///
/// - يقبل الفواصل: `,` أو `;` أو Tab.
/// - يكتشف التكرار داخل الملف (نفس الرقم المدرسي) ويرفض الصف الثاني.
/// - يرفض الصفوف الناقصة (رقم أو اسم) مع بيان السبب ورقم السطر.
class CsvImportService {
  static const _aliases = <String, List<String>>{
    'number': ['الرقم المدرسي', 'رقم', 'الرقم', 'student_number', 'number', 'id'],
    'name': ['الاسم', 'الاسم الكامل', 'اسم الطالب', 'full_name', 'name'],
    'gender': ['الجنس', 'gender', 'sex'],
    'birth': ['تاريخ الميلاد', 'الميلاد', 'birth_date', 'dob'],
    'address': ['العنوان', 'address'],
    'guardian': ['ولي الأمر', 'اسم ولي الأمر', 'guardian', 'guardian_name'],
    'guardian_phone': ['هاتف ولي الأمر', 'هاتف الولي', 'guardian_phone'],
    'student_phone': ['هاتف الطالب', 'هاتف', 'student_phone', 'phone'],
    'national_id': ['الرقم الوطني', 'national_id'],
    'notes': ['ملاحظات', 'notes'],
  };

  /// تحليل نص CSV إلى صفوف صالحة/مرفوضة (بلا أي كتابة في قاعدة البيانات).
  static ImportParseResult parse(String content,
      {required String schoolId, String? sectionId, String? academicYearId}) {
    final lines = const LineSplitter().convert(content).where((l) => l.trim().isNotEmpty).toList();
    final warnings = <String>[];
    final rows = <ImportRow>[];
    if (lines.isEmpty) {
      return ImportParseResult(rows, ['الملف فارغ']);
    }

    final delimiter = _detectDelimiter(lines.first);
    var start = 0;
    Map<String, int> map = {};

    // هل السطر الأول رأس أعمدة؟
    final firstCells = _split(lines.first, delimiter);
    final headerMap = _mapHeader(firstCells);
    if (headerMap.isNotEmpty) {
      map = headerMap;
      start = 1;
    } else {
      // بلا رأس: نفترض الترتيب الشائع رقم، اسم، جنس، هاتف الولي
      map = {'number': 0, 'name': 1, 'gender': 2, 'guardian_phone': 3};
      warnings.add('لم يُعثر على صف رؤوس — استُخدم الترتيب الافتراضي (رقم، اسم، جنس، هاتف الوليّ)');
    }

    final seen = <String>{};
    for (var i = start; i < lines.length; i++) {
      final line = lines[i];
      final cells = _split(line, delimiter);
      final number = _cell(cells, map['number'])?.trim() ?? '';
      final name = _cell(cells, map['name'])?.trim() ?? '';
      if (number.isEmpty && name.isEmpty) continue; // سطر متجاهَل

      if (number.isEmpty) {
        rows.add(ImportRow(line: i + 1, error: 'الرقم المدرسي مطلوب'));
        continue;
      }
      if (name.isEmpty) {
        rows.add(ImportRow(line: i + 1, error: 'الاسم مطلوب'));
        continue;
      }
      if (!seen.add(number)) {
        rows.add(ImportRow(line: i + 1, error: 'رقم مكرّر داخل الملف: $number'));
        continue;
      }

      rows.add(ImportRow(
        line: i + 1,
        student: Student(
          id: '',
          schoolId: schoolId,
          studentNumber: number,
          fullName: name,
          gender: _cell(cells, map['gender'])?.trim(),
          birthDate: _cell(cells, map['birth'])?.trim(),
          address: _cell(cells, map['address'])?.trim(),
          sectionId: sectionId,
          academicYearId: academicYearId,
          guardianName: _cell(cells, map['guardian'])?.trim(),
          guardianPhone: _cell(cells, map['guardian_phone'])?.trim(),
          studentPhone: _cell(cells, map['student_phone'])?.trim(),
          nationalId: _cell(cells, map['national_id'])?.trim(),
          notes: _cell(cells, map['notes'])?.trim(),
          status: 'active',
        ),
      ));
    }
    return ImportParseResult(rows, warnings);
  }

  /// قالب CSV جاهز بترويسة عربية (UTF-8 BOM ليقرأه Excel عربياً).
  static String template() {
    const header =
        'الرقم المدرسي,الاسم,الجنس,تاريخ الميلاد,هاتف الطالب,ولي الأمر,هاتف ولي الأمر,الرقم الوطني,العنوان,ملاحظات';
    const sample =
        'S001,أحمد محمد علي,ذكر,2012-05-10,07700000001,محمد علي,07700000002,1234567890,بغداد,';
    return '\uFEFF$header\r\n$sample\r\n';
  }

  static String _detectDelimiter(String line) {
    if (line.contains('\t')) return '\t';
    if (line.contains(';')) return ';';
    return ',';
  }

  static Map<String, int> _mapHeader(List<String> cells) {
    final map = <String, int>{};
    for (var i = 0; i < cells.length; i++) {
      final h = cells[i].trim().toLowerCase().replaceAll('_', ' ');
      for (final entry in _aliases.entries) {
        if (entry.value.any((a) => a.toLowerCase() == h)) {
          map.putIfAbsent(entry.key, () => i);
        }
      }
    }
    return map;
  }

  static String? _cell(List<String> cells, int? idx) {
    if (idx == null || idx < 0 || idx >= cells.length) return null;
    return cells[idx];
  }

  /// تقسيم سطر CSV يحترم علامات التنصيص.
  static List<String> _split(String line, String delim) {
    final out = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == delim && !inQuotes) {
        out.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    out.add(buf.toString());
    return out;
  }
}
