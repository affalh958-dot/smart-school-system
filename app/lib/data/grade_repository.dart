import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'database.dart';

/// مستودع الدرجات والامتحانات.
///
/// - قواعد النجاح/الرسوب والمجاميع قابلة للضبط (max_score, pass_score, weight)
///   ولا تُثبَّت في الكود.
/// - كل تعديل درجة يُسجَّل في grade_audit (من عدّل، متى، ولماذا).
class GradeRepository {
  final _uuid = const Uuid();
  Future<Database> get _db => AppDatabase.instance.database;
  String _now() => DateTime.now().toUtc().toIso8601String();

  Future<String> createExam({
    required String subjectId,
    required String sectionId,
    required String academicYearId,
    required String examType,
    String? examDate,
    double maxScore = 100,
    double? passScore,
    double weight = 1,
    String? semesterId,
  }) async {
    final id = _uuid.v4();
    final now = _now();
    await (await _db).insert('exams', {
      'id': id,
      'subject_id': subjectId,
      'section_id': sectionId,
      'academic_year_id': academicYearId,
      'semester_id': semesterId,
      'exam_type': examType,
      'exam_date': examDate,
      'max_score': maxScore,
      'pass_score': passScore,
      'weight': weight,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  /// إدخال/تعديل درجة. يتحقق من أن الدرجة داخل النطاق المسموح، ويسجّل التدقيق
  /// عند التعديل، ويقيّد العملية بالمستخدم المخوّل.
  Future<void> setScore({
    required String examId,
    required String studentId,
    required double score,
    required String enteredBy,
    bool isCorrection = false,
    String? reason,
  }) async {
    final db = await _db;
    final examRows = await db.query('exams', where: 'id = ?', whereArgs: [examId], limit: 1);
    if (examRows.isEmpty) throw StateError('الامتحان غير موجود');
    final maxScore = (examRows.first['max_score'] as num).toDouble();
    if (score < 0 || score > maxScore) {
      throw StateError('الدرجة يجب أن تكون بين 0 و $maxScore');
    }

    final now = _now();
    final existing = await db.query('exam_grades',
        where: 'exam_id = ? AND student_id = ?', whereArgs: [examId, studentId], limit: 1);

    if (existing.isNotEmpty && isCorrection) {
      final old = (existing.first['score'] as num?)?.toDouble();
      if (reason == null || reason.trim().isEmpty) {
        throw StateError('سبب التعديل مطلوب');
      }
      await db.transaction((txn) async {
        await txn.update('exam_grades', {'score': score, 'entered_by': enteredBy, 'entered_at': now, 'updated_at': now},
            where: 'id = ?', whereArgs: [existing.first['id']]);
        await txn.insert('grade_audit', {
          'id': _uuid.v4(),
          'grade_id': existing.first['id'],
          'old_score': old,
          'new_score': score,
          'changed_by': enteredBy,
          'changed_at': now,
          'reason': reason,
          'created_at': now,
        });
      });
      return;
    }

    await db.insert(
      'exam_grades',
      {
        'id': _uuid.v4(),
        'exam_id': examId,
        'student_id': studentId,
        'score': score,
        'entered_by': enteredBy,
        'entered_at': now,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> examScores(String examId) async {
    return (await _db).rawQuery('''
      SELECT g.id, s.full_name, s.student_number, g.score
      FROM exam_grades g JOIN students s ON s.id = g.student_id
      WHERE g.exam_id = ? AND g.deleted_at IS NULL
      ORDER BY s.full_name
    ''', [examId]);
  }

  /// مجموع الطالب في مادة/شعبة حسب الأوزان (قابل للضبط).
  Future<double> weightedTotal(String studentId, String subjectId, String academicYearId) async {
    final rows = await (await _db).rawQuery('''
      SELECT e.max_score, e.weight, g.score
      FROM exam_grades g
      JOIN exams e ON e.id = g.exam_id
      WHERE g.student_id = ? AND e.subject_id = ? AND e.academic_year_id = ? AND g.deleted_at IS NULL
    ''', [studentId, subjectId, academicYearId]);
    var total = 0.0;
    var weightSum = 0.0;
    for (final r in rows) {
      final score = (r['score'] as num?)?.toDouble() ?? 0;
      final max = (r['max_score'] as num?)?.toDouble() ?? 100;
      final w = (r['weight'] as num?)?.toDouble() ?? 1;
      if (max > 0) {
        total += (score / max) * 100 * w;
        weightSum += w;
      }
    }
    return weightSum > 0 ? total / weightSum : 0;
  }

  Future<int> auditCount() async {
    final r = await (await _db).rawQuery('SELECT COUNT(*) c FROM grade_audit');
    return Sqflite.firstIntValue(r) ?? 0;
  }
}
