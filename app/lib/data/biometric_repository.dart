import 'dart:convert';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../core/biometric_crypto.dart';
import 'database.dart';
import 'models.dart';

/// مستودع البيانات الحيوية: يخزّن تمثيل السمات (Embedding) مشفّراً فقط — لا صور.
///
/// - يُشفَّر القالب (AES-256-CBC) قبل الحفظ، والمفتاح في المخزن الآمن للنظام.
/// - `loadAllActive` يعيد البايتات الخام مفكوكة التشفير لبناء `FaceIndex` كما هو.
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
    final encrypted = await BiometricCrypto.instance.encryptTemplate(bytes);

    final existing = await db.query('biometric_templates',
        where: 'student_id = ? AND is_active = 1 AND deleted_at IS NULL', whereArgs: [studentId], limit: 1);
    if (existing.isNotEmpty) {
      await db.update(
          'biometric_templates',
          {
            'template_encrypted': encrypted,
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
        'template_encrypted': encrypted,
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

  /// تحميل التمثيلات النشطة — مقيّدة بالمدرسة عند تمريرها (عزل تام).
  Future<List<BiometricTemplate>> loadAllActive({String? schoolId}) async {
    final db = await AppDatabase.instance.database;
    List<Map<String, Object?>> rows;
    if (schoolId == null) {
      rows = await db.query('biometric_templates', where: 'is_active = 1 AND deleted_at IS NULL');
    } else {
      rows = await db.rawQuery('''
        SELECT bt.* FROM biometric_templates bt
        JOIN students s ON s.id = bt.student_id
        WHERE bt.is_active = 1 AND bt.deleted_at IS NULL AND s.school_id = ?
      ''', [schoolId]);
    }
    final out = <BiometricTemplate>[];
    for (final r in rows) {
      final raw = r['template_encrypted'];
      final stored = raw is String ? raw : utf8.decode((raw as List).cast<int>());
      Uint8List bytes;
      try {
        bytes = await BiometricCrypto.instance.decryptTemplate(stored);
      } catch (_) {
        // قيمة تالفة أو مفتاح غير متاح: نتخطّى القالب بدل إسقاط الشاشة.
        continue;
      }
      out.add(BiometricTemplate(
        id: r['id'] as String,
        studentId: r['student_id'] as String,
        templateEncrypted: bytes,
        embeddingDim: (r['embedding_dim'] as int?) ?? 128,
        templateVersion: (r['template_version'] as String?) ?? 'mobilefacenet-v1',
        qualityScore: (r['quality_score'] as num?)?.toDouble(),
        isActive: (r['is_active'] as int) == 1,
      ));
    }
    return out;
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

  /// مجموعة معرّفات الطلاب الذين لديهم تمثيل وجه نشط (للعرض والتحقق من الحالة).
  Future<Set<String>> enrolledStudentIds({String? schoolId, String? sectionId}) async {
    final db = await AppDatabase.instance.database;
    final where = StringBuffer('bt.is_active = 1 AND bt.deleted_at IS NULL');
    final args = <dynamic>[];
    if (schoolId != null) {
      where.write(' AND s.school_id = ?');
      args.add(schoolId);
    }
    if (sectionId != null) {
      where.write(' AND s.section_id = ?');
      args.add(sectionId);
    }
    final rows = await db.rawQuery('''
      SELECT DISTINCT bt.student_id FROM biometric_templates bt
      JOIN students s ON s.id = bt.student_id
      WHERE $where
    ''', args);
    return rows.map((r) => r['student_id'] as String).toSet();
  }

  /// تسجيل محاولة تعرّف (للتدقيق والمراجعة) — منفصل عن سجل الحضور.
  Future<String> logAttempt({
    required String result,
    String? deviceId,
    String? matchedStudentId,
    double? confidence,
    double? quality,
    String? schoolId,
  }) async {
    final db = await AppDatabase.instance.database;
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('recognition_attempts', {
      'id': id,
      'school_id': schoolId,
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
        'school_id': schoolId,
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
