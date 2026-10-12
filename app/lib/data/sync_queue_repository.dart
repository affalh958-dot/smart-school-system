import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'database.dart';

/// عنصر في طابور المزامنة (سجل حضور مؤقت بانتظار الإرسال عند عودة الاتصال).
class SyncQueueItem {
  final String id;
  final String clientUuid;
  final String entityType;
  final String entityId;
  final String operation;
  final Map<String, dynamic> payload;
  final String? schoolId;
  final String status; // pending|failed|synced
  final int retryCount;
  final String? lastError;

  SyncQueueItem({
    required this.id,
    required this.clientUuid,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payload,
    this.schoolId,
    this.status = 'pending',
    this.retryCount = 0,
    this.lastError,
  });

  factory SyncQueueItem.fromMap(Map<String, dynamic> m) => SyncQueueItem(
        id: m['id'] as String,
        clientUuid: m['client_uuid'] as String,
        entityType: m['entity_type'] as String,
        entityId: m['entity_id'] as String,
        operation: m['operation'] as String,
        payload: (jsonDecode(m['payload'] as String) as Map).cast<String, dynamic>(),
        schoolId: m['school_id'] as String?,
        status: (m['status'] as String?) ?? 'pending',
        retryCount: (m['retry_count'] as int?) ?? 0,
        lastError: m['last_error'] as String?,
      );
}

/// نتيجة محاولة مزامنة واحدة.
class SyncResult {
  final int synced;
  final int failed;
  final int remaining;
  SyncResult({required this.synced, required this.failed, required this.remaining});
}

/// طابور المزامنة: يحفظ العمليات محلياً بمعرّف فريد (client_uuid) لمنع التكرار،
/// ثم يُرسلها بالترتيب عند عودة الاتصال مع إعادة المحاولة وتسجيل الأخطاء.
///
/// يعمل حالياً بمزامنة محلية (نقل إلى الحالة synced) — وعند ربط خادم لاحقاً
/// يُستبدل `_push` بنداء API حقيقي دون تغيير بقية النظام.
class SyncQueueRepository {
  final _uuid = const Uuid();

  /// إضافة عملية إلى الطابور. client_uuid فريد يمنع تكرار الإدراج (idempotency).
  Future<String> enqueue({
    required String entityType,
    required String entityId,
    required String operation,
    required Map<String, dynamic> payload,
    String? schoolId,
    String? clientUuid,
  }) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    final cuuid = clientUuid ?? _uuid.v4();
    // إن وُجد نفس client_uuid سابقاً فلا نُكرّره.
    final dup = await db.query('sync_queue', columns: ['id'], where: 'client_uuid = ?', whereArgs: [cuuid], limit: 1);
    if (dup.isNotEmpty) return dup.first['id'] as String;
    final id = _uuid.v4();
    await db.insert('sync_queue', {
      'id': id,
      'client_uuid': cuuid,
      'entity_type': entityType,
      'entity_id': entityId,
      'operation': operation,
      'payload': jsonEncode(payload),
      'school_id': schoolId,
      'status': 'pending',
      'retry_count': 0,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  Future<List<SyncQueueItem>> pending({String? schoolId}) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('sync_queue',
        where: schoolId == null ? "status = 'pending'" : "status = 'pending' AND school_id = ?",
        whereArgs: schoolId == null ? null : [schoolId],
        orderBy: 'created_at ASC');
    return rows.map(SyncQueueItem.fromMap).toList();
  }

  Future<int> pendingCount({String? schoolId}) async {
    final db = await AppDatabase.instance.database;
    final r = await db.rawQuery(
        schoolId == null
            ? "SELECT COUNT(*) c FROM sync_queue WHERE status = 'pending'"
            : "SELECT COUNT(*) c FROM sync_queue WHERE status = 'pending' AND school_id = ?",
        schoolId == null ? null : [schoolId]);
    return Sqflite.firstIntValue(r) ?? 0;
  }

  /// مزامنة كل العناصر المعلّقة (أو عناصر مدرسة محدّدة).
  /// pusher يُرجع true عند النجاح — اتركه null للمزامنة المحلية.
  Future<SyncResult> sync({String? schoolId, Future<bool> Function(SyncQueueItem)? pusher}) async {
    final db = await AppDatabase.instance.database;
    final items = await pending(schoolId: schoolId);
    var synced = 0, failed = 0;
    for (final item in items) {
      final ok = pusher == null ? true : await pusher(item);
      final now = DateTime.now().toUtc().toIso8601String();
      if (ok) {
        await db.update('sync_queue', {'status': 'synced', 'updated_at': now, 'last_error': null},
            where: 'id = ?', whereArgs: [item.id]);
        synced++;
      } else {
        await db.update('sync_queue', {
          'retry_count': item.retryCount + 1,
          'status': item.retryCount + 1 >= 5 ? 'failed' : 'pending',
          'last_error': 'فشل الإرسال',
          'updated_at': now,
        }, where: 'id = ?', whereArgs: [item.id]);
        failed++;
      }
    }
    final remaining = await pendingCount(schoolId: schoolId);
    return SyncResult(synced: synced, failed: failed, remaining: remaining);
  }

  /// تعليم الرسائل الفاشلة نهائياً بكثرة المحاولات كي يمكن للمسؤول مراجعتها.
  Future<List<SyncQueueItem>> failed({String? schoolId}) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('sync_queue',
        where: schoolId == null ? "status = 'failed'" : "status = 'failed' AND school_id = ?",
        whereArgs: schoolId == null ? null : [schoolId],
        orderBy: 'updated_at DESC');
    return rows.map(SyncQueueItem.fromMap).toList();
  }
}
