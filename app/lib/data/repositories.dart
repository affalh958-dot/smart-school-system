import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../core/security.dart';
import 'database.dart';
import 'models.dart';

/// مستودع الطلاب: إضافة/تعديل/بحث/نقل — مع منع التكرار والتحقق.
class StudentRepository {
  final _uuid = const Uuid();

  Future<String> create(Student s) async {
    final db = await AppDatabase.instance.database;
    final id = s.id.isEmpty ? _uuid.v4() : s.id;
    final now = DateTime.now().toUtc().toIso8601String();
    final map = s.toMap()
      ..['id'] = id
      ..['created_at'] = now
      ..['updated_at'] = now;
    await db.insert('students', map, conflictAlgorithm: ConflictAlgorithm.abort);
    return id;
  }

  Future<void> update(Student s) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.update('students', {...s.toMap(), 'updated_at': now},
        where: 'id = ?', whereArgs: [s.id]);
  }

  Future<Student?> byId(String id) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('students', where: 'id = ? AND deleted_at IS NULL', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Student.fromMap(rows.first);
  }

  Future<Student?> byNumber(String schoolId, String number) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('students',
        where: 'school_id = ? AND student_number = ? AND deleted_at IS NULL',
        whereArgs: [schoolId, number],
        limit: 1);
    return rows.isEmpty ? null : Student.fromMap(rows.first);
  }

  /// بحث بالاسم أو الرقم المدرسي — سريع ومحدود.
  Future<List<Student>> search(String schoolId, String query, {int limit = 50}) async {
    final db = await AppDatabase.instance.database;
    final q = '%${query.trim()}%';
    final rows = await db.query('students',
        where: 'school_id = ? AND deleted_at IS NULL AND (full_name LIKE ? OR student_number LIKE ?)',
        whereArgs: [schoolId, q, q],
        orderBy: 'full_name ASC',
        limit: limit);
    return rows.map(Student.fromMap).toList();
  }

  Future<List<Student>> bySection(String sectionId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('students',
        where: 'section_id = ? AND deleted_at IS NULL',
        whereArgs: [sectionId],
        orderBy: 'full_name ASC');
    return rows.map(Student.fromMap).toList();
  }

  Future<int> countAll(String schoolId) async {
    final db = await AppDatabase.instance.database;
    final r = await db.rawQuery(
        'SELECT COUNT(*) c FROM students WHERE school_id = ? AND deleted_at IS NULL', [schoolId]);
    return Sqflite.firstIntValue(r) ?? 0;
  }

  /// نقل الطالب بين الشعب مع حفظ السجل التاريخي.
  Future<void> moveToSection({
    required String studentId,
    required String fromSection,
    required String toSection,
    required String academicYearId,
    String? byUserId,
    String? reason,
  }) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      await txn.update('students', {'section_id': toSection, 'updated_at': now},
          where: 'id = ?', whereArgs: [studentId]);
      await txn.insert('student_movements', {
        'id': _uuid.v4(),
        'student_id': studentId,
        'from_section': fromSection,
        'to_section': toSection,
        'academic_year_id': academicYearId,
        'moved_at': now,
        'moved_by': byUserId,
        'reason': reason,
        'created_at': now,
        'updated_at': now,
      });
    });
  }

  /// إحصاء الطلاب في شعبة.
  Future<int> countBySection(String sectionId) async {
    final db = await AppDatabase.instance.database;
    final r = await db.rawQuery(
        'SELECT COUNT(*) c FROM students WHERE section_id = ? AND deleted_at IS NULL', [sectionId]);
    return Sqflite.firstIntValue(r) ?? 0;
  }

  /// ملف الطالب الكامل مع أسماء المرحلة/الصف/الشعبة (لعرض أنيق في وقت واحد).
  Future<Map<String, dynamic>?> fullProfile(String studentId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT s.*, sec.name AS section_name, g.name AS grade_name, st.name AS stage_name
      FROM students s
      LEFT JOIN sections sec ON sec.id = s.section_id
      LEFT JOIN grades g ON g.id = sec.grade_id
      LEFT JOIN stages st ON st.id = g.stage_id
      WHERE s.id = ? AND s.deleted_at IS NULL
      LIMIT 1
    ''', [studentId]);
    return rows.isEmpty ? null : rows.first;
  }

  /// بحث فوري بالرقم المدرسي (للبحث عند الحضور أو عرض سريع).
  Future<Student?> byNumberExact(String schoolId, String number) => byNumber(schoolId, number);

  /// الطلاب النشطون في شعبة، مع حالة التسجيل الحيوي (للتحقق قبل الترحيل).
  Future<List<Map<String, dynamic>>> activeBySection(String sectionId) async {
    final db = await AppDatabase.instance.database;
    return db.rawQuery('''
      SELECT s.id, s.student_number, s.full_name, s.gender, s.section_id
      FROM students s
      WHERE s.section_id = ? AND s.status = 'active' AND s.deleted_at IS NULL
      ORDER BY s.full_name
    ''', [sectionId]);
  }

  /// ترحيل نهاية السنة: نقل قائمة طلاب إلى شعبة جديدة، أو إبقاؤهم مكانهم.
  /// يعمل داخل معاملة واحدة ويوثّق كل حركة في student_movements.
  Future<void> promoteForNewYear({
    required String schoolId,
    required String newAcademicYearId,
    required Map<String, String> moves, // studentId -> toSectionId
    String? movedBy,
    String? reason,
  }) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      for (final entry in moves.entries) {
        final studentId = entry.key;
        final toSectionId = entry.value;
        final rows = await txn.query('students',
            columns: ['section_id'], where: 'id = ?', whereArgs: [studentId], limit: 1);
        if (rows.isEmpty) continue;
        final fromSection = rows.first['section_id'] as String?;
        await txn.update(
          'students',
          {
            'section_id': toSectionId,
            'academic_year_id': newAcademicYearId,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [studentId],
        );
        await txn.insert('student_movements', {
          'id': _uuid.v4(),
          'student_id': studentId,
          'from_section': fromSection,
          'to_section': toSectionId,
          'academic_year_id': newAcademicYearId,
          'moved_at': now,
          'moved_by': movedBy,
          'reason': reason ?? 'ترحيل نهاية السنة',
          'created_at': now,
          'updated_at': now,
        });
      }
    });
  }

  /// أرشفة (حذف منطقي) — لا حذف فعلي للسجلات التاريخية.
  Future<void> archive(String studentId) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.update('students', {'deleted_at': now, 'status': 'withdrawn', 'updated_at': now},
        where: 'id = ?', whereArgs: [studentId]);
  }
}

/// مستودع المصادقة: إنشاء الحسابات والتحقق وتسجيل الدخول.
class AuthRepository {
  final _uuid = const Uuid();

  Future<String> createUser({
    required String username,
    required String password,
    required String fullName,
    String? phone,
    String? schoolId,
    required String roleCode,
    String? teacherId,
    String? studentId,
  }) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    final salt = Security.generateSalt();
    final hash = Security.hashPassword(password, salt);
    final id = _uuid.v4();
    await db.transaction((txn) async {
      await txn.insert('users', {
        'id': id,
        'school_id': schoolId,
        'username': username,
        'password_hash': hash,
        'password_salt': salt,
        'full_name': fullName,
        'phone': phone,
        'is_active': 1,
        'teacher_id': teacherId,
        'student_id': studentId,
        'created_at': now,
        'updated_at': now,
      });
      final roleRows = await txn.query('roles', where: 'code = ?', whereArgs: [roleCode], limit: 1);
      if (roleRows.isNotEmpty) {
        await txn.insert('user_roles', {'user_id': id, 'role_id': roleRows.first['id']});
      }
    });
    return id;
  }

  Future<Map<String, dynamic>?> login(String username, String password) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('users',
        where: 'username = ? AND is_active = 1 AND deleted_at IS NULL',
        whereArgs: [username],
        limit: 1);
    if (rows.isEmpty) return null;
    final u = rows.first;
    final ok = Security.verifyPassword(password, u['password_salt'] as String, u['password_hash'] as String);
    if (!ok) return null;

    final roles = await db.rawQuery('''
      SELECT r.code FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE ur.user_id = ?
    ''', [u['id']]);
    final roleCodes = roles.map((e) => e['code'] as String).toList();

    await db.update('users', {'last_login_at': DateTime.now().toUtc().toIso8601String()},
        where: 'id = ?', whereArgs: [u['id']]);

    return {
      'id': u['id'],
      'username': u['username'],
      'full_name': u['full_name'],
      'phone': u['phone'],
      'school_id': u['school_id'],
      'student_id': u['student_id'],
      'linked_student_id': u['linked_student_id'],
      'roles': roleCodes,
    };
  }

  /// بيانات الحسابات في مدرسة (اسم المستخدم، الدور) — لاطلاع المالك/المدير.
  Future<List<Map<String, dynamic>>> usersOfSchool(String schoolId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT u.id, u.username, u.full_name, u.phone, u.is_active,
             GROUP_CONCAT(r.code) AS role_codes
      FROM users u
      LEFT JOIN user_roles ur ON ur.user_id = u.id
      LEFT JOIN roles r ON r.id = ur.role_id
      WHERE u.school_id = ? AND u.deleted_at IS NULL
      GROUP BY u.id
      ORDER BY u.created_at
    ''', [schoolId]);
    return rows;
  }

  /// إعادة تعيين كلمة مرور مستخدم (يُسجَّل في سجل التدقيق من الطبقة المستدعية).
  Future<void> resetPassword(String userId, String newPassword) async {
    final db = await AppDatabase.instance.database;
    final salt = Security.generateSalt();
    final hash = Security.hashPassword(newPassword, salt);
    await db.update('users',
        {'password_salt': salt, 'password_hash': hash, 'updated_at': DateTime.now().toUtc().toIso8601String()},
        where: 'id = ?', whereArgs: [userId]);
  }

  /// تحديث بيانات مستخدم (الاسم/الهاتف/التفعيل).
  Future<void> updateUser(String userId, {String? fullName, String? phone, int? isActive}) async {
    final db = await AppDatabase.instance.database;
    final data = <String, dynamic>{'updated_at': DateTime.now().toUtc().toIso8601String()};
    if (fullName != null) data['full_name'] = fullName;
    if (phone != null) data['phone'] = phone;
    if (isActive != null) data['is_active'] = isActive;
    await db.update('users', data, where: 'id = ?', whereArgs: [userId]);
  }

  Future<bool> hasAnyUser() async {
    final db = await AppDatabase.instance.database;
    final r = await db.rawQuery('SELECT COUNT(*) c FROM users');
    return (Sqflite.firstIntValue(r) ?? 0) > 0;
  }
}
