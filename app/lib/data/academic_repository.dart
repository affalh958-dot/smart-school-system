import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'database.dart';

/// مستودع الهيكل المدرسي: المراحل، الصفوف، الشعب، المدرسون، المواد، والتكليفات.
///
/// كل الكيانات مرتبطة بـ school_id (عزل المدارس) وتُدار من الإعدادات دون
/// تعديل الكود.
class AcademicRepository {
  final _uuid = const Uuid();

  Future<Database> get _db => AppDatabase.instance.database;

  String _now() => DateTime.now().toUtc().toIso8601String();

  // ------------------------- المراحل -------------------------
  Future<String> addStage({required String schoolId, required String name, int order = 0}) async {
    final id = _uuid.v4();
    final now = _now();
    await (await _db).insert('stages', {
      'id': id,
      'school_id': schoolId,
      'name': name,
      'order_index': order,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  Future<List<Map<String, dynamic>>> stages(String schoolId) async {
    return (await _db).query('stages',
        where: 'school_id = ? AND deleted_at IS NULL', whereArgs: [schoolId], orderBy: 'order_index, name');
  }

  // ------------------------- الصفوف -------------------------
  Future<String> addGrade({required String stageId, required String name, int order = 0}) async {
    final id = _uuid.v4();
    final now = _now();
    await (await _db).insert('grades', {
      'id': id,
      'stage_id': stageId,
      'name': name,
      'order_index': order,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  Future<List<Map<String, dynamic>>> grades(String stageId) async {
    return (await _db).query('grades',
        where: 'stage_id = ? AND deleted_at IS NULL', whereArgs: [stageId], orderBy: 'order_index, name');
  }

  // ------------------------- الشعب -------------------------
  Future<String> addSection({
    required String gradeId,
    required String academicYearId,
    required String name,
    int? capacity,
  }) async {
    final id = _uuid.v4();
    final now = _now();
    await (await _db).insert('sections', {
      'id': id,
      'grade_id': gradeId,
      'academic_year_id': academicYearId,
      'name': name,
      'capacity': capacity,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  /// الشعب مع اسم الصف والمرحلة — لعرض واضح في الواجهة.
  Future<List<Map<String, dynamic>>> sectionsWithNames(String schoolId, String academicYearId) async {
    return (await _db).rawQuery('''
      SELECT s.id, s.name, s.capacity,
             g.name AS grade_name, st.name AS stage_name,
             (SELECT COUNT(*) FROM students stu WHERE stu.section_id = s.id AND stu.deleted_at IS NULL) AS student_count
      FROM sections s
      JOIN grades g ON g.id = s.grade_id
      JOIN stages st ON st.id = g.stage_id
      WHERE st.school_id = ? AND s.academic_year_id = ? AND s.deleted_at IS NULL
      ORDER BY st.order_index, g.order_index, s.name
    ''', [schoolId, academicYearId]);
  }

  /// منع حذف شعبة/صف مرتبط بسجلات تاريخية — فحص قبل الحذف.
  Future<bool> sectionHasRecords(String sectionId) async {
    final db = await _db;
    final r = await db.rawQuery('SELECT COUNT(*) c FROM students WHERE section_id = ?', [sectionId]);
    final count = Sqflite.firstIntValue(r) ?? 0;
    return count > 0;
  }

  Future<void> archiveSection(String sectionId) async {
    if (await sectionHasRecords(sectionId)) {
      throw StateError('لا يمكن حذف شعبة مرتبطة بطلاب أو سجلات تاريخية');
    }
    await (await _db).update('sections', {'deleted_at': _now()}, where: 'id = ?', whereArgs: [sectionId]);
  }

  // ------------------------- المدرسون -------------------------
  Future<String> addTeacher({
    required String schoolId,
    required String employeeNo,
    required String fullName,
    String? phone,
    String? email,
  }) async {
    final id = _uuid.v4();
    final now = _now();
    await (await _db).insert('teachers', {
      'id': id,
      'school_id': schoolId,
      'employee_no': employeeNo,
      'full_name': fullName,
      'phone': phone,
      'email': email,
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  Future<List<Map<String, dynamic>>> teachers(String schoolId) async {
    return (await _db).query('teachers',
        where: 'school_id = ? AND deleted_at IS NULL', whereArgs: [schoolId], orderBy: 'full_name');
  }

  // ------------------------- المواد -------------------------
  Future<String> addSubject({required String schoolId, required String name, String? code}) async {
    final id = _uuid.v4();
    final now = _now();
    await (await _db).insert('subjects', {
      'id': id,
      'school_id': schoolId,
      'name': name,
      'code': code,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  Future<List<Map<String, dynamic>>> subjects(String schoolId) async {
    return (await _db).query('subjects',
        where: 'school_id = ? AND deleted_at IS NULL', whereArgs: [schoolId], orderBy: 'name');
  }

  // ------------------------- التكليفات -------------------------
  Future<String> assignTeacher({
    required String teacherId,
    required String subjectId,
    required String sectionId,
    required String academicYearId,
  }) async {
    final id = _uuid.v4();
    final now = _now();
    await (await _db).insert('teacher_assignments', {
      'id': id,
      'teacher_id': teacherId,
      'subject_id': subjectId,
      'section_id': sectionId,
      'academic_year_id': academicYearId,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return id;
  }

  Future<List<Map<String, dynamic>>> assignments(String schoolId, String academicYearId) async {
    return (await _db).rawQuery('''
      SELECT a.id, a.section_id, a.subject_id, t.full_name AS teacher_name,
             sub.name AS subject_name, sec.name AS section_name
      FROM teacher_assignments a
      JOIN teachers t ON t.id = a.teacher_id
      JOIN subjects sub ON sub.id = a.subject_id
      JOIN sections sec ON sec.id = a.section_id
      JOIN grades g ON g.id = sec.grade_id
      JOIN stages st ON st.id = g.stage_id
      WHERE st.school_id = ? AND a.academic_year_id = ? AND a.deleted_at IS NULL
      ORDER BY t.full_name
    ''', [schoolId, academicYearId]);
  }

  /// الشعب المكلّف بها معلّم معيّن (لتقييد إدخال الدرجات/التقييمات).
  Future<List<Map<String, dynamic>>> sectionsForTeacher(String teacherId, String academicYearId) async {
    return (await _db).rawQuery('''
      SELECT DISTINCT sec.id, sec.name, g.name AS grade_name, st.name AS stage_name
      FROM teacher_assignments a
      JOIN sections sec ON sec.id = a.section_id
      JOIN grades g ON g.id = sec.grade_id
      JOIN stages st ON st.id = g.stage_id
      WHERE a.teacher_id = ? AND a.academic_year_id = ? AND a.deleted_at IS NULL
      ORDER BY st.name, g.name, sec.name
    ''', [teacherId, academicYearId]);
  }

  /// المواد المكلّف بها معلّم في شعبة معيّنة.
  Future<List<Map<String, dynamic>>> subjectsForTeacher(
      String teacherId, String sectionId, String academicYearId) async {
    return (await _db).rawQuery('''
      SELECT DISTINCT sub.id, sub.name
      FROM teacher_assignments a
      JOIN subjects sub ON sub.id = a.subject_id
      WHERE a.teacher_id = ? AND a.section_id = ? AND a.academic_year_id = ? AND a.deleted_at IS NULL
      ORDER BY sub.name
    ''', [teacherId, sectionId, academicYearId]);
  }
}
