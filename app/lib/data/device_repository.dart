import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'database.dart';

/// مستودع الأجهزة: يسجّل الجهاز الموثوق عند أول استخدام حتى تصحّ مفاتيح
/// `device_id` الأجنبية في سجلات الحضور ومحاولات التعرّف.
class DeviceRepository {
  Future<void> ensureRegistered({
    required String deviceId,
    required String schoolId,
    String? name,
    String? platform,
  }) async {
    final db = await AppDatabase.instance.database;
    final existing = await db.query('devices',
        columns: ['id', 'last_seen_at'],
        where: 'id = ?',
        whereArgs: [deviceId],
        limit: 1);
    final now = DateTime.now().toUtc().toIso8601String();
    if (existing.isEmpty) {
      await db.insert('devices', {
        'id': deviceId,
        'school_id': schoolId,
        'name': name ?? 'جهاز الحضور',
        'platform': platform ?? _platformName,
        'is_trusted': 0,
        'is_revoked': 0,
        'last_seen_at': now,
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    } else {
      await db.update('devices', {'last_seen_at': now, 'updated_at': now},
          where: 'id = ?', whereArgs: [deviceId]);
    }
  }

  static String get _platformName {
    try {
      if (Platform.isAndroid) return 'Android';
      if (Platform.isWindows) return 'Windows';
      if (Platform.isIOS) return 'iOS';
      if (Platform.isLinux) return 'Linux';
      if (Platform.isMacOS) return 'macOS';
    } catch (_) {}
    return 'unknown';
  }
}
