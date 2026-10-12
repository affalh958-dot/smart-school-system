import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'database.dart';

/// مستودع التقييم الأسبوعي التراكمي.
/// كل صف = تقييم طالب في مادة لأسبوع محدّد. التراكم = مجموع مرجّح.
class EvaluationRepository {
  final _uuid = const Uuid();
  Future<Database> get _db => AppDatabase.instance.database;

  /// تسجيل/تحديث تقييم أسبوعي (upsert على المفتاح: طالب+مادة+سنة+أسبوع).
  Future<void> setEvaluation({
    required String schoolId,
    required String studentId,
    required String subjectId,
    String? sectionId,
    String? academicYearId,
    String? teacherId,
    required int weekNo,
    String? weekStart,
    required double score,
    double maxScore = 10,
    double weight = 1,
    String? comment,
    String? evaluatedBy,
  }) async {
    final db = await _db;
    final now = DateTime.now().toUtc().toIso8601String();
    // تحقق من النطاق
    if (score < 0 || score > maxScore) {
      throw ArgumentError('الدرجة يجب أن تكون بين 0 و $maxScore');
    }
    final existing = await db.query('weekly_evaluations',
        where: 'student_id = ? AND subject_id = ? AND week_no = ? AND IFNULL(academic_year_id, \'\') = ?',
        whereArgs: [studentId, subjectId, weekNo, academicYearId ?? ''],
        limit: 1);
    if (existing.isNotEmpty) {
      await db.update(
        'weekly_evaluations',
        {
          'score': score,
          'max_score': maxScore,
          'weight': weight,
          'comment': comment,
          'teacher_id': teacherId,
          'evaluated_by': evaluatedBy,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
    } else {
      await db.insert('weekly_evaluations', {
        'id': _uuid.v4(),
        'school_id': schoolId,
        'student_id': studentId,
        'subject_id': subjectId,
        'section_id': sectionId,
        'academic_year_id': academicYearId,
        'teacher_id': teacherId,
        'week_no': weekNo,
        'week_start': weekStart,
        'score': score,
        'max_score': maxScore,
        'weight': weight,
        'comment': comment,
        'evaluated_by': evaluatedBy,
        'created_at': now,
        'updated_at': now,
      });
    }
  }

  /// تقييمات طالب في مادة (لسنة دراسية) مرتّبة بالأسبوع.
  Future<List<Map<String, dynamic>>> studentSubjectEvaluations(
      String studentId, String subjectId, String? academicYearId) async {
    final db = await _db;
    return db.query('weekly_evaluations',
        where: 'student_id = ? AND subject_id = ? AND IFNULL(academic_year_id, \'\') = ? AND deleted_at IS NULL',
        whereArgs: [studentId, subjectId, academicYearId ?? ''],
        orderBy: 'week_no');
  }

  /// كل تقييمات طالب (كل المواد) لسنة دراسية، مع اسم المادة.
  Future<List<Map<String, dynamic>>> studentAllEvaluations(String studentId, String? academicYearId) async {
    final db = await _db;
    return db.rawQuery('''
      SELECT we.*, sub.name AS subject_name, t.full_name AS teacher_name
      FROM weekly_evaluations we
      JOIN subjects sub ON sub.id = we.subject_id
      LEFT JOIN teachers t ON t.id = we.teacher_id
      WHERE we.student_id = ? AND IFNULL(we.academic_year_id, '') = ? AND we.deleted_at IS NULL
      ORDER BY sub.name, we.week_no
    ''', [studentId, academicYearId ?? '']);
  }

  /// ملخّص تراكمي لكل مادة: المتوسط، عدد الأسابيع، آخر تقييم.
  Future<List<Map<String, dynamic>>> cumulativeBySubject(String studentId, String? academicYearId) async {
    final db = await _db;
    return db.rawQuery('''
      SELECT sub.id AS subject_id, sub.name AS subject_name,
             COUNT(we.id) AS weeks,
             SUM(we.score * we.weight) / NULLIF(SUM(we.weight), 0) AS weighted_avg,
             MAX(we.max_score) AS max_score,
             SUM(CASE WHEN we.score >= (we.max_score * 0.5) THEN 1 ELSE 0 END) AS pass_weeks
      FROM weekly_evaluations we
      JOIN subjects sub ON sub.id = we.subject_id
      WHERE we.student_id = ? AND IFNULL(we.academic_year_id, '') = ? AND we.deleted_at IS NULL
      GROUP BY sub.id
      ORDER BY sub.name
    ''', [studentId, academicYearId ?? '']);
  }

  /// متوسط تراكمي عام للطالب (0..max) محوّل إلى نسبة مئوية.
  Future<double?> overallAverage(String studentId, String? academicYearId) async {
    final db = await _db;
    final r = await db.rawQuery('''
      SELECT SUM(we.score * we.weight) / NULLIF(SUM(we.weight * we.max_score), 0) * 100 AS pct
      FROM weekly_evaluations we
      WHERE we.student_id = ? AND IFNULL(we.academic_year_id, '') = ? AND we.deleted_at IS NULL
    ''', [studentId, academicYearId ?? '']);
    final v = r.isNotEmpty ? r.first['pct'] : null;
    return v == null ? null : (v as num).toDouble();
  }

  /// تقييمات شعبة في مادة لأسبوع (لإدخال المعلم دفعة واحدة).
  Future<List<Map<String, dynamic>>> sectionSubjectWeek(
      String sectionId, String subjectId, int weekNo, String? academicYearId) async {
    final db = await _db;
    return db.rawQuery('''
      SELECT s.id AS student_id, s.full_name, s.student_number,
             we.score, we.comment, we.id AS evaluation_id
      FROM students s
      LEFT JOIN weekly_evaluations we
        ON we.student_id = s.id AND we.subject_id = ? AND we.week_no = ?
        AND IFNULL(we.academic_year_id, '') = ? AND we.deleted_at IS NULL
      WHERE s.section_id = ? AND s.deleted_at IS NULL AND s.status = 'active'
      ORDER BY s.full_name
    ''', [subjectId, weekNo, academicYearId ?? '', sectionId]);
  }

  /// عدد التقييمات لطالب (للتحقق في الاختبارات).
  Future<int> countForStudent(String studentId) async {
    final db = await _db;
    final r = await db.rawQuery(
        'SELECT COUNT(*) c FROM weekly_evaluations WHERE student_id = ? AND deleted_at IS NULL', [studentId]);
    return Sqflite.firstIntValue(r) ?? 0;
  }
}
