import 'package:sqflite/sqflite.dart';

import 'database.dart';

/// مستودع التقارير — استعلامات مقيّدة بالمدرسة، تُبنى من القاعدة الفعلية.
class ReportsRepository {
  /// حضور يوم معيّن: الاسم والرقم والحالة والوقت (مقيّد بالمدرسة).
  Future<List<Map<String, dynamic>>> dailyAttendance(String schoolId, String date) async {
    final db = await AppDatabase.instance.database;
    return db.rawQuery('''
      SELECT s.student_number, s.full_name, ar.status, ar.recorded_at, ar.source,
             g.name AS grade_name, sec.name AS section_name
      FROM attendance_records ar
      JOIN students s ON s.id = ar.student_id
      LEFT JOIN sections sec ON sec.id = s.section_id
      LEFT JOIN grades g ON g.id = sec.grade_id
      WHERE s.school_id = ? AND ar.session_date = ? AND ar.deleted_at IS NULL
      ORDER BY ar.recorded_at DESC
    ''', [schoolId, date]);
  }

  /// الطلاب الذين لم يسجّلوا حضوراً صباحياً في تاريخ (قائمة «لم يسجل حضوراً»).
  Future<List<Map<String, dynamic>>> notRecorded(String schoolId, String date) async {
    final db = await AppDatabase.instance.database;
    return db.rawQuery('''
      SELECT s.student_number, s.full_name, g.name AS grade_name, sec.name AS section_name
      FROM students s
      LEFT JOIN sections sec ON sec.id = s.section_id
      LEFT JOIN grades g ON g.id = sec.grade_id
      WHERE s.school_id = ? AND s.deleted_at IS NULL AND s.status = 'active'
        AND s.id NOT IN (
          SELECT ar.student_id FROM attendance_records ar
          WHERE ar.session_date = ? AND ar.session_type = 'morning' AND ar.deleted_at IS NULL
        )
      ORDER BY g.name, sec.name, s.full_name
    ''', [schoolId, date]);
  }

  /// المتأخرون في تاريخ.
  Future<List<Map<String, dynamic>>> late(String schoolId, String date) async {
    final db = await AppDatabase.instance.database;
    return db.rawQuery('''
      SELECT s.student_number, s.full_name, ar.recorded_at, g.name AS grade_name, sec.name AS section_name
      FROM attendance_records ar
      JOIN students s ON s.id = ar.student_id
      LEFT JOIN sections sec ON sec.id = s.section_id
      LEFT JOIN grades g ON g.id = sec.grade_id
      WHERE s.school_id = ? AND ar.session_date = ? AND ar.status = 'late' AND ar.deleted_at IS NULL
      ORDER BY ar.recorded_at DESC
    ''', [schoolId, date]);
  }

  /// تقرير نطاق زمني: عدد الحضور/التأخير/الغياب/البعذر لكل طالب.
  Future<List<Map<String, dynamic>>> rangeSummary(String schoolId, String from, String to) async {
    final db = await AppDatabase.instance.database;
    return db.rawQuery('''
      SELECT s.student_number, s.full_name,
             SUM(CASE WHEN ar.status = 'present' THEN 1 ELSE 0 END) AS present_count,
             SUM(CASE WHEN ar.status = 'late' THEN 1 ELSE 0 END) AS late_count,
             SUM(CASE WHEN ar.status = 'absent' THEN 1 ELSE 0 END) AS absent_count,
             SUM(CASE WHEN ar.status = 'excused' THEN 1 ELSE 0 END) AS excused_count
      FROM attendance_records ar
      JOIN students s ON s.id = ar.student_id
      WHERE s.school_id = ? AND ar.session_date BETWEEN ? AND ? AND ar.deleted_at IS NULL
      GROUP BY s.id
      ORDER BY s.full_name
    ''', [schoolId, from, to]);
  }

  /// الحالات التي فشل فيها التعرّف (محاولات غير مطابقة) في النطاق.
  Future<List<Map<String, dynamic>>> failedRecognitions(String schoolId, String from, String to) async {
    final db = await AppDatabase.instance.database;
    return db.rawQuery('''
      SELECT result, COUNT(*) AS c
      FROM recognition_attempts
      WHERE school_id = ? AND date(attempted_at) BETWEEN ? AND ?
      GROUP BY result ORDER BY c DESC
    ''', [schoolId, from, to]);
  }

  /// الأجهزة التي سجّلت الحضور.
  Future<List<Map<String, dynamic>>> devicesReport(String schoolId, String from, String to) async {
    final db = await AppDatabase.instance.database;
    return db.rawQuery('''
      SELECT COALESCE(ar.device_id, 'غير محدد') AS device_id, COUNT(*) AS c
      FROM attendance_records ar
      JOIN students s ON s.id = ar.student_id
      WHERE s.school_id = ? AND ar.session_date BETWEEN ? AND ? AND ar.deleted_at IS NULL
      GROUP BY ar.device_id ORDER BY c DESC
    ''', [schoolId, from, to]);
  }

  /// سجل تعديلات الحضور (التدقيق) مع بيانات السجل والطالب.
  Future<List<Map<String, dynamic>>> attendanceAudit(String schoolId, int limit) async {
    final db = await AppDatabase.instance.database;
    return db.rawQuery('''
      SELECT au.changed_at, au.old_status, au.new_status, au.reason,
             s.full_name, u.full_name AS changed_by_name
      FROM attendance_audit au
      JOIN attendance_records ar ON ar.id = au.attendance_record_id
      JOIN students s ON s.id = ar.student_id
      LEFT JOIN users u ON u.id = au.changed_by
      WHERE s.school_id = ?
      ORDER BY au.changed_at DESC LIMIT ?
    ''', [schoolId, limit]);
  }

  /// نسب الحضور حسب الصف والشعبة لِنطاق زمني.
  Future<List<Map<String, dynamic>>> byGradeSection(String schoolId, String from, String to) async {
    final db = await AppDatabase.instance.database;
    return db.rawQuery('''
      SELECT g.name AS grade_name, sec.name AS section_name,
             SUM(CASE WHEN ar.status IN ('present','late') THEN 1 ELSE 0 END) AS attended,
             COUNT(ar.id) AS total
      FROM attendance_records ar
      JOIN students s ON s.id = ar.student_id
      LEFT JOIN sections sec ON sec.id = s.section_id
      LEFT JOIN grades g ON g.id = sec.grade_id
      WHERE s.school_id = ? AND ar.session_date BETWEEN ? AND ? AND ar.deleted_at IS NULL
      GROUP BY g.name, sec.name
      ORDER BY g.name, sec.name
    ''', [schoolId, from, to]);
  }

  /// تقرير درجات شعبة لِامتحان.
  Future<List<Map<String, dynamic>>> examReport(String examId) async {
    final db = await AppDatabase.instance.database;
    return db.rawQuery('''
      SELECT s.student_number, s.full_name, eg.score, e.max_score, e.pass_score
      FROM exam_grades eg
      JOIN students s ON s.id = eg.student_id
      JOIN exams e ON e.id = eg.exam_id
      WHERE eg.exam_id = ? AND eg.deleted_at IS NULL
      ORDER BY eg.score DESC
    ''', [examId]);
  }

  /// عدّاد سريع لعدد السجلات (للتحقق من الأداء مع أعداد كبيرة).
  Future<int> countAttendance(String schoolId) async {
    final db = await AppDatabase.instance.database;
    final r = await db.rawQuery('''
      SELECT COUNT(*) c FROM attendance_records ar
      JOIN students s ON s.id = ar.student_id WHERE s.school_id = ?
    ''', [schoolId]);
    return Sqflite.firstIntValue(r) ?? 0;
  }
}
