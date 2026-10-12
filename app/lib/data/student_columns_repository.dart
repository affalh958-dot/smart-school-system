import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'database.dart';

/// عمود مخصّص يعرّفه المدير (حقل إضافي في ملف الطالب).
class StudentColumn {
  final String id;
  final String key;
  final String label;
  final String dataType; // text|number|date|bool
  final bool isRequired;
  final int orderIndex;
  StudentColumn({
    required this.id,
    required this.key,
    required this.label,
    this.dataType = 'text',
    this.isRequired = false,
    this.orderIndex = 0,
  });
  factory StudentColumn.fromMap(Map<String, dynamic> m) => StudentColumn(
        id: m['id'] as String,
        key: m['key'] as String,
        label: m['label'] as String,
        dataType: m['data_type'] as String? ?? 'text',
        isRequired: (m['is_required'] as int? ?? 0) == 1,
        orderIndex: m['order_index'] as int? ?? 0,
      );
}

/// السمات المخصّصة للطلاب: تعريف الحقول + قراءة/كتابة القيم (EAV) مع عزل المدرسة.
class StudentColumnsRepository {
  final _uuid = const Uuid();

  Future<Database> get _db => AppDatabase.instance.database;

  String _now() => DateTime.now().toUtc().toIso8601String();

  Future<List<StudentColumn>> columns(String schoolId) async {
    final rows = await (await _db).query('student_columns',
        where: 'school_id = ? AND deleted_at IS NULL',
        whereArgs: [schoolId],
        orderBy: 'order_index, label');
    return rows.map(StudentColumn.fromMap).toList();
  }

  Future<String> addColumn({
    required String schoolId,
    required String label,
    String? key,
    String dataType = 'text',
    bool isRequired = false,
    int orderIndex = 0,
  }) async {
    final id = _uuid.v4();
    final now = _now();
    final finalKey = (key == null || key.trim().isEmpty) ? 'col_${id.substring(0, 8)}' : key.trim();
    await (await _db).insert('student_columns', {
      'id': id,
      'school_id': schoolId,
      'key': finalKey,
      'label': label,
      'data_type': dataType,
      'is_required': isRequired ? 1 : 0,
      'order_index': orderIndex,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  /// أرشفة عمود: يمنع الحذف الفعلي حفاظاً على السجلات التاريخية.
  Future<void> archiveColumn(String columnId) async {
    await (await _db)
        .update('student_columns', {'deleted_at': _now()}, where: 'id = ?', whereArgs: [columnId]);
  }

  Future<Map<String, String>> valuesForStudent(String studentId) async {
    final rows = await (await _db).rawQuery('''
      SELECT c.id AS column_id, v.value AS value, v.value_number AS value_number
      FROM student_attribute_values v
      JOIN student_columns c ON c.id = v.column_id
      WHERE v.student_id = ? AND c.deleted_at IS NULL
    ''', [studentId]);
    final out = <String, String>{};
    for (final r in rows) {
      final v = r['value'] ?? (r['value_number']?.toString() ?? '');
      out[r['column_id'] as String] = '$v';
    }
    return out;
  }

  /// حفظ قيم السمات لطالب داخل معاملة واحدة (يستبدل القيم الحالية).
  Future<void> setValues(String studentId, Map<String, String> byColumnId) async {
    final db = await _db;
    final now = _now();
    await db.transaction((txn) async {
      for (final e in byColumnId.entries) {
        final numeric = double.tryParse(e.value.trim());
        final rows = await txn.query('student_attribute_values',
            where: 'student_id = ? AND column_id = ?', whereArgs: [studentId, e.key], limit: 1);
        if (rows.isEmpty) {
          await txn.insert('student_attribute_values', {
            'id': _uuid.v4(),
            'student_id': studentId,
            'column_id': e.key,
            'value': e.value,
            'value_number': numeric,
            'created_at': now,
            'updated_at': now,
          });
        } else {
          await txn.update(
              'student_attribute_values',
              {'value': e.value, 'value_number': numeric, 'updated_at': now},
              where: 'id = ?',
              whereArgs: [rows.first['id']]);
        }
      }
    });
  }
}
