import 'package:uuid/uuid.dart';

import 'database.dart';

/// سجل العمليات (التدقيق): يُسجِّل الإجراءات الإدارية الحساسة مع المستخدم والوقت.
class AuditRepository {
  final _uuid = const Uuid();

  Future<void> log({
    String? userId,
    required String action,
    String? entityType,
    String? entityId,
    String? oldValue,
    String? newValue,
    String? deviceId,
  }) async {
    final db = await AppDatabase.instance.database;
    await db.insert('audit_log', {
      'id': _uuid.v4(),
      'user_id': userId,
      'action': action,
      'entity_type': entityType,
      'entity_id': entityId,
      'old_value': oldValue,
      'new_value': newValue,
      'device_id': deviceId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// أحدث العمليات (مع اسم المستخدم).
  Future<List<Map<String, dynamic>>> recent({int limit = 200}) async {
    final db = await AppDatabase.instance.database;
    return db.rawQuery('''
      SELECT a.*, u.full_name AS user_name
      FROM audit_log a
      LEFT JOIN users u ON u.id = a.user_id
      ORDER BY a.created_at DESC
      LIMIT ?
    ''', [limit]);
  }

  /// سجل تعديلات الحضور (مع اسم الطالب والمستخدم).
  Future<List<Map<String, dynamic>>> attendanceAudit({int limit = 200}) async {
    final db = await AppDatabase.instance.database;
    return db.rawQuery('''
      SELECT aa.*, s.full_name AS student_name, u.full_name AS user_name
      FROM attendance_audit aa
      LEFT JOIN attendance_records ar ON ar.id = aa.attendance_record_id
      LEFT JOIN students s ON s.id = ar.student_id
      LEFT JOIN users u ON u.id = aa.changed_by
      ORDER BY aa.changed_at DESC
      LIMIT ?
    ''', [limit]);
  }
}
