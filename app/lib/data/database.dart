import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// إدارة قاعدة البيانات المحلية (SQLite).
/// - على أندرويد: sqflite العادي.
/// - على ويندوز/سطح المكتب: sqflite_common_ffi.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  /// مسارات بديلة للاختبار (تُضبط فقط في بيئة الاختبار).
  static String? testDbPath;
  static String? testSchemaPath;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    if (testDbPath != null) {
      databaseFactory = databaseFactoryFfi;
      final schema = await _loadTestSchema();
      return _create(testDbPath!, schema);
    }

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await getApplicationSupportDirectory();
    final dbDir = Directory(p.join(dir.path, 'school_db'));
    if (!dbDir.existsSync()) dbDir.createSync(recursive: true);
    final dbPath = p.join(dbDir.path, 'school.db');
    final schema = await rootBundle.loadString('assets/db/schema.sql');
    return _create(dbPath, schema);
  }

  Future<String> _loadTestSchema() async {
    if (testSchemaPath != null) {
      return File(testSchemaPath!).readAsString();
    }
    return File('assets/db/schema.sql').readAsString();
  }

  Future<Database> _create(String dbPath, String schema) async {
    return openDatabase(
      dbPath,
      version: 3,
      onConfigure: (d) async {
        await d.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (d, version) async {
        for (final stmt in _splitSql(schema)) {
          if (stmt.toUpperCase().startsWith('PRAGMA')) continue;
          await d.execute(stmt);
        }
      },
      onUpgrade: (d, oldVersion, newVersion) async {
        // ترحيل آمن 1 → 2: عزل المدرسة لسجلات التعرّف ومحاولات المراجعة.
        if (oldVersion < 2) {
          await _addColumnIfMissing(d, 'recognition_attempts', 'school_id TEXT REFERENCES schools(id)');
          await _addColumnIfMissing(d, 'recognition_reviews', 'school_id TEXT REFERENCES schools(id)');
          try {
            await d.execute('CREATE INDEX IF NOT EXISTS idx_attempts_school ON recognition_attempts(school_id, attempted_at)');
            await d.execute('CREATE INDEX IF NOT EXISTS idx_reviews_school ON recognition_reviews(school_id, status)');
          } catch (_) {}
        }
        // ترحيل 2 → 3: حقول ملف الطالب الإضافية + جداول الحقول المخصّصة (EAV).
        if (oldVersion < 3) {
          for (final col in const [
            'national_id TEXT',
            'student_phone TEXT',
            'guardian_name TEXT',
            'guardian_phone TEXT',
            'residence TEXT',
          ]) {
            await _addColumnIfMissing(d, 'students', col);
          }
          await d.execute('''
            CREATE TABLE IF NOT EXISTS student_columns (
              id          TEXT PRIMARY KEY,
              school_id   TEXT NOT NULL,
              key         TEXT NOT NULL,
              label       TEXT NOT NULL,
              data_type   TEXT NOT NULL DEFAULT 'text',
              is_required INTEGER NOT NULL DEFAULT 0,
              order_index INTEGER NOT NULL DEFAULT 0,
              created_at  TEXT NOT NULL,
              updated_at  TEXT NOT NULL,
              deleted_at  TEXT,
              UNIQUE (school_id, key)
            )
          ''');
          await d.execute('''
            CREATE TABLE IF NOT EXISTS student_attribute_values (
              id             TEXT PRIMARY KEY,
              student_id     TEXT NOT NULL,
              column_id      TEXT NOT NULL,
              value          TEXT,
              value_number   REAL,
              created_at     TEXT NOT NULL,
              updated_at     TEXT NOT NULL,
              UNIQUE (student_id, column_id)
            )
          ''');
          await d.execute('CREATE INDEX IF NOT EXISTS idx_sav_student ON student_attribute_values(student_id)');
          await d.execute('CREATE INDEX IF NOT EXISTS idx_sav_column  ON student_attribute_values(column_id)');
        }
      },
      onOpen: (d) async {
        await d.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  /// إضافة عمود إن لم يكن موجوداً (SQLite لا يدعم IF NOT EXISTS للأعمدة).
  Future<void> _addColumnIfMissing(Database d, String table, String columnDef) async {
    final columnName = columnDef.split(' ').first;
    final info = await d.rawQuery('PRAGMA table_info($table)');
    final exists = info.any((c) => c['name'] == columnName);
    if (!exists) {
      // SQLite لا يسمح بإضافة عمود بمفتاح أجنبي مباشرة في بعض الإصدارات — نضيفه كنص.
      final safeDef = columnDef.replaceAll(RegExp(r'\s+REFERENCES\s+\w+\([^)]*\)'), '');
      await d.execute('ALTER TABLE $table ADD COLUMN $safeDef');
    }
  }

  /// تقسيم ملف SQL إلى عبارات (يحترم الفواصل المنقوطة داخل النصوص).
  static List<String> _splitSql(String sql) {
    final statements = <String>[];
    final buffer = StringBuffer();
    var inString = false;
    for (var i = 0; i < sql.length; i++) {
      final ch = sql[i];
      if (ch == "'") inString = !inString;
      if (ch == ';' && !inString) {
        final s = buffer.toString().trim();
        if (s.isNotEmpty) statements.add(s);
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    final last = buffer.toString().trim();
    if (last.isNotEmpty) statements.add(last);
    return statements;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
