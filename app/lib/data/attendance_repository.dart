import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'database.dart';
import 'models.dart';

/// نتيجة محاولة تسجيل الحضور.
enum RecordOutcome { recorded, duplicate, outsideWindow, notFound }

class RecordResult {
  final RecordOutcome outcome;
  final String? recordId;
  final String message;
  RecordResult(this.outcome, this.message, {this.recordId});
}

/// مستودع الحضور: تسجيل آمن + منع التكرار على مستوى القاعدة + تدقيق التعديلات.
class AttendanceRepository {
  final _uuid = const Uuid();

  /// تسجيل حضور/انصراف. يمنع التكرار عبر قيد UNIQUE و client_uuid.
  Future<RecordResult> record({
    required String studentId,
    required String sessionType, // morning|checkout
    required String status, // present|late|absent|excused|early_leave
    String source = 'face',
    String? deviceId,
    double? confidence,
    String? clientUuid,
    DateTime? at,
  }) async {
    final db = await AppDatabase.instance.database;
    final now = (at ?? DateTime.now()).toUtc();
    final date = _dateOnly(now);
    final cuuid = clientUuid ?? _uuid.v4();

    // فحص سريع للوجود قبل الإدراج (لتقليل الاعتماد على الاستثناءات)
    final existing = await db.query('attendance_records',
        columns: ['id'],
        where: 'student_id = ? AND session_date = ? AND session_type = ? AND deleted_at IS NULL',
        whereArgs: [studentId, date, sessionType],
        limit: 1);
    if (existing.isNotEmpty) {
      return RecordResult(RecordOutcome.duplicate, 'مسجَّل مسبقاً لهذه الفترة');
    }

    try {
      final id = _uuid.v4();
      await db.insert('attendance_records', {
        'id': id,
        'student_id': studentId,
        'session_date': date,
        'session_type': sessionType,
        'status': status,
        'recorded_at': now.toIso8601String(),
        'time_source': 'device',
        'source': source,
        'device_id': deviceId,
        'client_uuid': cuuid,
        'confidence': confidence,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.abort);
      return RecordResult(RecordOutcome.recorded, 'تم التسجيل', recordId: id);
    } on DatabaseException catch (e) {
      if (e.toString().contains('UNIQUE')) {
        return RecordResult(RecordOutcome.duplicate, 'مسجَّل مسبقاً');
      }
      rethrow;
    }
  }

  /// تعديل حالة سجل حضور بصلاحية مخوّلة — مع تسجيل التدقيق (السبب إلزامي).
  Future<void> overrideStatus({
    required String recordId,
    required String newStatus,
    required String changedByUserId,
    required String reason,
  }) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    final rows = await db.query('attendance_records', where: 'id = ?', whereArgs: [recordId], limit: 1);
    if (rows.isEmpty) throw StateError('السجل غير موجود');
    final oldStatus = rows.first['status'] as String;

    await db.transaction((txn) async {
      await txn.update('attendance_records', {'status': newStatus, 'updated_at': now},
          where: 'id = ?', whereArgs: [recordId]);
      await txn.insert('attendance_audit', {
        'id': _uuid.v4(),
        'attendance_record_id': recordId,
        'old_status': oldStatus,
        'new_status': newStatus,
        'changed_by': changedByUserId,
        'changed_at': now,
        'reason': reason,
        'created_at': now,
      });
    });
  }

  Future<List<AttendanceRecord>> byDate(String date, {String? status, String? sessionType}) async {
    final db = await AppDatabase.instance.database;
    final where = StringBuffer('session_date = ? AND deleted_at IS NULL');
    final args = <dynamic>[date];
    if (status != null) {
      where.write(' AND status = ?');
      args.add(status);
    }
    if (sessionType != null) {
      where.write(' AND session_type = ?');
      args.add(sessionType);
    }
    final rows = await db.query('attendance_records', where: where.toString(), whereArgs: args, orderBy: 'recorded_at DESC');
    return rows.map(AttendanceRecord.fromMap).toList();
  }

  /// إحصاءات سريعة ليوم معيّن.
  Future<Map<String, int>> dailyStats(String date) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT status, COUNT(*) c FROM attendance_records
      WHERE session_date = ? AND session_type = 'morning' AND deleted_at IS NULL
      GROUP BY status
    ''', [date]);
    final stats = <String, int>{'present': 0, 'late': 0, 'absent': 0, 'excused': 0, 'early_leave': 0};
    for (final r in rows) {
      stats[r['status'] as String] = (r['c'] as int);
    }
    return stats;
  }

  /// الحالات التي تحتاج مراجعة.
  Future<int> pendingReviews() async {
    final db = await AppDatabase.instance.database;
    final r = await db.rawQuery("SELECT COUNT(*) c FROM recognition_reviews WHERE status = 'pending'");
    return Sqflite.firstIntValue(r) ?? 0;
  }

  static String _dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
