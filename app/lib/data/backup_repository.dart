import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'database.dart';

/// نسخ احتياطي/استعادة لقاعدة البيانات المحلية (SQLite).
///
/// - النسخة = ملف قاعدة البيانات مضغوطاً (gzip) مع بصمة SHA-256 للتحقق من السلامة.
/// - تُخزَّن في مجلد `backups` داخل مجلد دعم التطبيق، وتُسجَّل في جدول `backups`.
/// - الاستعادة: إغلاق القاعدة، أخذ نسخة أمان تلقائية، ثم استبدال الملف وإعادة الفتح.
class BackupRepository {
  final _uuid = const Uuid();

  Future<Directory> _backupDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'backups'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// إنشاء نسخة احتياطية. يعيد مسار الملف الناتج.
  Future<String> createBackup({String? createdBy, String? schoolId, String? label}) async {
    final dbPath = AppDatabase.instance.dbPath;
    if (dbPath == null || !File(dbPath).existsSync()) {
      throw StateError('قاعدة البيانات غير مفتوحة بعد');
    }
    // إتمام ما في الذاكرة إلى الملف قبل النسخ.
    final db = await AppDatabase.instance.database;
    await db.execute('PRAGMA wal_checkpoint(FULL)');

    final srcBytes = await File(dbPath).readAsBytes();
    final gz = gzip.encode(srcBytes);
    final digest = sha256.convert(srcBytes).toString();

    final name = 'school_backup_${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.db.gz';
    final outPath = p.join((await _backupDir()).path, name);
    await File(outPath).writeAsBytes(gz, flush: true);

    // تسجيل النسخة في قاعدة البيانات (للعرض والتدقيق).
    try {
      await db.insert('backups', {
        'id': _uuid.v4(),
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'size_bytes': gz.length,
        'location': outPath,
        'checksum': digest,
        'created_by': createdBy,
      });
    } catch (_) {
      // فشل التسجيل لا يُبطل النسخة نفسها.
    }
    return outPath;
  }

  /// قائمة النسخ الموجودة على القرص (الأحدث أولاً).
  Future<List<File>> listBackups() async {
    final dir = await _backupDir();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.db.gz'))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return files;
  }

  /// استعادة نسخة احتياطية. تنشئ نسخة أمان من الحالة الحالية أولاً.
  Future<void> restoreBackup(String backupPath, {String? restoredBy}) async {
    final file = File(backupPath);
    if (!file.existsSync()) throw ArgumentError('ملف النسخة غير موجود');

    // نسخة أمان قبل الاستبدال (لا نفقد الحالة الحالية).
    await createBackup(createdBy: restoredBy, label: 'قبل الاستعادة');

    final dbPath = AppDatabase.instance.dbPath;
    if (dbPath == null) throw StateError('قاعدة البيانات غير مفتوحة بعد');
    final raw = gzip.decode(await file.readAsBytes());

    await AppDatabase.instance.close();
    await File(dbPath).writeAsBytes(raw, flush: true);
    // ملفات WAL/SHM القديمة قد تُفسد الحالة — تُزال.
    for (final suffix in ['-wal', '-shm']) {
      final f = File('$dbPath$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    await AppDatabase.instance.database; // إعادة الفتح والترحيل إن لزم

    // تسجيل عملية الاستعادة.
    try {
      final db = await AppDatabase.instance.database;
      await db.insert('backups', {
        'id': _uuid.v4(),
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'size_bytes': file.lengthSync(),
        'location': 'استعادة من: ${p.basename(backupPath)}',
        'checksum': null,
        'created_by': restoredBy,
      });
    } catch (_) {}
  }
}
