import 'package:uuid/uuid.dart';

import '../core/security.dart';
import 'database.dart';

/// مستودع المدارس — للمالك (مدير المنصة) فقط: إنشاء مدارس معزولة وإدارتها.
class SchoolRepository {
  final _uuid = const Uuid();

  Future<List<Map<String, dynamic>>> all() async {
    final db = await AppDatabase.instance.database;
    return db.rawQuery('''
      SELECT s.*,
             (SELECT COUNT(*) FROM students st WHERE st.school_id = s.id AND st.deleted_at IS NULL) AS students_count,
             (SELECT COUNT(*) FROM users u WHERE u.school_id = s.id AND u.deleted_at IS NULL) AS users_count
      FROM schools s
      WHERE s.deleted_at IS NULL
      ORDER BY s.name
    ''');
  }

  Future<Map<String, dynamic>?> byId(String id) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('schools', where: 'id = ? AND deleted_at IS NULL', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> usersOf(String schoolId) async {
    final db = await AppDatabase.instance.database;
    return db.rawQuery('''
      SELECT u.id, u.username, u.full_name, u.is_active, GROUP_CONCAT(r.code) roles
      FROM users u
      LEFT JOIN user_roles ur ON ur.user_id = u.id
      LEFT JOIN roles r ON r.id = ur.role_id
      WHERE u.school_id = ? AND u.deleted_at IS NULL
      GROUP BY u.id
      ORDER BY u.full_name
    ''', [schoolId]);
  }

  Future<void> setActive(String id, bool active) async {
    final db = await AppDatabase.instance.database;
    await db.update('schools', {'is_active': active ? 1 : 0, 'updated_at': _now()},
        where: 'id = ?', whereArgs: [id]);
    if (!active) {
      await db.update('users', {'is_active': 0, 'updated_at': _now()},
          where: 'school_id = ?', whereArgs: [id]);
    }
  }

  /// أرشفة مدرسة (حذف منطقي) مع تعطيل حساباتها. تبقى السجلات التاريخية محفوظة.
  Future<void> archive(String id) async {
    final db = await AppDatabase.instance.database;
    final now = _now();
    await db.update('schools', {'deleted_at': now, 'is_active': 0, 'updated_at': now},
        where: 'id = ?', whereArgs: [id]);
    await db.update('users', {'is_active': 0, 'updated_at': now}, where: 'school_id = ?', whereArgs: [id]);
  }

  String _now() => DateTime.now().toUtc().toIso8601String();

  /// إنشاء مدرسة جديدة مع إعداداتها الافتراضية: دوام + سنة دراسية حالية،
  /// ورؤوس مراحل/صفوف اختيارية. يعمل داخل معاملة واحدة.
  Future<String> createSchool({
    required String name,
    String timezone = 'Asia/Baghdad',
    String? managerUsername,
    String? managerPassword,
    String? managerName,
    List<String> seedStageNames = const [],
    List<List<String>> seedGrades = const [],
  }) async {
    final db = await AppDatabase.instance.database;
    final schoolId = _uuid.v4();
    final now = _now();
    final year = DateTime.now().year;
    await db.transaction((txn) async {
      await txn.insert('schools', {
        'id': schoolId,
        'name': name,
        'timezone': timezone,
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      });
      await txn.insert('attendance_settings', {
        'id': _uuid.v4(),
        'school_id': schoolId,
        'scope': 'school',
        'day_start': '07:30',
        'day_end': '13:30',
        'checkin_window_start': '07:00',
        'checkin_window_end': '07:45',
        'late_after': '07:30',
        'auto_close_time': '08:00',
        'working_days': '[0,1,2,3,4]',
        'created_at': now,
        'updated_at': now,
      });
      await txn.insert('academic_years', {
        'id': _uuid.v4(),
        'school_id': schoolId,
        'name': '$year/${year + 1}',
        'start_date': '$year-09-01',
        'end_date': '${year + 1}-06-30',
        'is_current': 1,
        'created_at': now,
        'updated_at': now,
      });
      for (var i = 0; i < seedStageNames.length; i++) {
        final stageName = seedStageNames[i];
        if (stageName.trim().isEmpty) continue;
        final stageId = _uuid.v4();
        await txn.insert('stages', {
          'id': stageId,
          'school_id': schoolId,
          'name': stageName.trim(),
          'order_index': i,
          'created_at': now,
          'updated_at': now,
        });
        if (i < seedGrades.length) {
          for (var g = 0; g < seedGrades[i].length; g++) {
            final gName = seedGrades[i][g];
            if (gName.trim().isEmpty) continue;
            await txn.insert('grades', {
              'id': _uuid.v4(),
              'stage_id': stageId,
              'name': gName.trim(),
              'order_index': g,
              'created_at': now,
              'updated_at': now,
            });
          }
        }
      }
    });

    if ((managerUsername?.trim().isNotEmpty ?? false) && (managerPassword?.length ?? 0) >= 6) {
      await createManager(
        schoolId: schoolId,
        username: managerUsername!.trim(),
        password: managerPassword!,
        fullName: managerName?.trim().isNotEmpty == true ? managerName!.trim() : 'مدير المدرسة',
        roleCode: 'manager',
      );
    }
    return schoolId;
  }

  /// إنشاء مستخدم ضمن مدرسة (مدير مدرسة/معاون/موظف حضور/معلم...).
  Future<String> createManager({
    required String schoolId,
    required String username,
    required String password,
    required String fullName,
    String roleCode = 'manager',
  }) async {
    final db = await AppDatabase.instance.database;
    final id = _uuid.v4();
    final now = _now();
    final salt = Security.generateSalt();
    final hash = Security.hashPassword(password, salt);
    final roleRows = await db.query('roles', where: 'code = ?', whereArgs: [roleCode], limit: 1);
    await db.transaction((txn) async {
      await txn.insert('users', {
        'id': id,
        'school_id': schoolId,
        'username': username,
        'password_hash': hash,
        'password_salt': salt,
        'full_name': fullName,
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      });
      if (roleRows.isNotEmpty) {
        await txn.insert('user_roles', {'user_id': id, 'role_id': roleRows.first['id']});
      }
    });
    return id;
  }
}
