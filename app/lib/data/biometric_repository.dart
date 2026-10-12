import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'database.dart';
import 'models.dart';

/// مستودع البيانات الحيوية: يخزّن تمثيل السمات (Embedding) مشفّراً فقط — لا صور.
class BiometricRepository {
  final _uuid = const Uuid();

  /// حفظ/تحديث تمثيل وجه لطالب.
  Future<void> upsertTemplate({
    required String studentId,
    required Float32List embedding,
    double? quality,
    String? enrolledBy,
  }) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    final bytes = _floatsToBytes(embedding);

    final existing = await db.query('biometric_templates',
        where: 'student_id = ? AND is_active = 1 AND deleted_at IS NULL', whereArgs: [studentId], limit: 1);
    if (existing.isNotEmpty) {
      await db.update(
          'biometric_templates',
          {
            'template_encrypted': bytes,
            'quality_score': quality,
            'enrolled_by': enrolledBy,
            'enrolled_at': now,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [existing.first['id']]);
    } else {
      await db.insert('biometric_templates', {
        'id': _uuid.v4(),
        'student_id': studentId,
        'template_encrypted': bytes,
        'embedding_dim': embedding.length,
        'template_version': 'mobilefacenet-v1',
        'quality_score': quality,
        'is_active': 1,
        'enrolled_by': enrolledBy,
        'enrolled_at': now,
        'created_at': now,
        'updated_at': now,
      });
    }
  }

  /// تحميل كل التمثيلات النشطة لبناء فهرس المطابقة (محمّل مرّة واحدة).
  Future<List<BiometricTemplate>> loadAllActive() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('biometric_templates',
        where: 'is_active = 1 AND deleted_at IS NULL');
    return rows
        .map((r) => BiometricTemplate(
              id: r['id'] as String,
              studentId: r['student_id'] as String,
              templateEncrypted: (r['template_encrypted'] as List).cast<int>(),
              embeddingDim: (r['embedding_dim'] as int?) ?? 128,
              templateVersion: (r['template_version'] as String?) ?? 'mobilefacenet-v1',
              qualityScore: (r['quality_score'] as num?)?.toDouble(),
              isActive: (r['is_active'] as int) == 1,
            ))
        .toList();
  }

  /// تعطيل التعرّف لطالب دون حذف ملفه المدرسي.
  Future<void> revokeForStudent(String studentId) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.update('biometric_templates', {'is_active': 0, 'revoked_at': now, 'updated_at': now},
        where: 'student_id = ?', whereArgs: [studentId]);
  }

  Future<int> countEnrolled() async {
    final db = await AppDatabase.instance.database;
    final r = await db.rawQuery(
        'SELECT COUNT(DISTINCT student_id) c FROM biometric_templates WHERE is_active = 1 AND deleted_at IS NULL');
    return Sqflite.firstIntValue(r) ?? 0;
  }

  /// تسجيل محاولة تعرّف (للتدقيق والمراجعة) — منفصل عن سجل الحضور.
  Future<String> logAttempt({
    required String result,
    String? deviceId,
    String? matchedStudentId,
    double? confidence,
    double? quality,
  }) async {
    final db = await AppDatabase.instance.database;
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('recognition_attempts', {
      'id': id,
      'device_id': deviceId,
      'attempted_at': now,
      'result': result,
      'matched_student_id': matchedStudentId,
      'confidence': confidence,
      'quality_score': quality,
      'created_at': now,
    });
    if (result == 'ambiguous' || result == 'no_match' || result == 'low_quality') {
      await db.insert('recognition_reviews', {
        'id': _uuid.v4(),
        'attempt_id': id,
        'student_id': matchedStudentId,
        'status': 'pending',
        'created_at': now,
        'updated_at': now,
      });
    }
    return id;
  }

  static List<int> _floatsToBytes(Float32List floats) {
    final bd = ByteData(floats.length * 4);
    for (var i = 0; i < floats.length; i++) {
      bd.setFloat32(i * 4, floats[i], Endian.little);
    }
    return bd.buffer.asUint8List();
  }
}
