import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:school_app/core/permissions.dart';
import 'package:school_app/core/security.dart';
import 'package:school_app/core/whatsapp_helper.dart';
import 'package:school_app/data/academic_repository.dart';
import 'package:school_app/data/attendance_repository.dart';
import 'package:school_app/data/biometric_repository.dart';
import 'package:school_app/data/database.dart';
import 'package:school_app/data/evaluation_repository.dart';
import 'package:school_app/data/grade_repository.dart';
import 'package:school_app/data/import/csv_import_service.dart';
import 'package:school_app/data/models.dart';
import 'package:school_app/data/repositories.dart';
import 'package:school_app/data/reports_repository.dart';
import 'package:school_app/data/school_repository.dart';
import 'package:school_app/data/school_settings_repository.dart';
import 'package:school_app/data/student_columns_repository.dart';
import 'package:school_app/data/sync_queue_repository.dart';
import 'package:school_app/face/face_index.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// اختبارات حقيقية للمنطق الأساسي: الأمان، الصلاحيات، منع التكرار،
/// مطابقة الوجه، وعزل المدارس. تعمل على قاعدة بيانات SQLite فعلية.
void main() {
  late String schoolId;
  late Directory tmp;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = Directory.systemTemp.createTempSync('school_test');
    AppDatabase.testDbPath = '${tmp.path}/test.db';
    AppDatabase.testSchemaPath = 'assets/db/schema.sql';
    // يُنشئ الجداول
    final db = await AppDatabase.instance.database;
    schoolId = 'school-1';
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('schools', {
      'id': schoolId,
      'name': 'مدرسة الاختبار',
      'timezone': 'Asia/Baghdad',
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });
    // مستخدم مرجعي لسجلات التدقيق (entered_by / changed_by مفتاح أجنبي).
    await db.insert('users', {
      'id': 'u1',
      'school_id': schoolId,
      'username': 'tester',
      'password_hash': 'x',
      'password_salt': 'x',
      'full_name': 'مستخدم اختبار',
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDownAll(() async {
    await AppDatabase.instance.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('الأمان', () {
    test('تجزئة كلمة المرور والتحقق منها', () {
      final salt = Security.generateSalt();
      final hash = Security.hashPassword('كلمةمرور123', salt);
      expect(Security.verifyPassword('كلمةمرور123', salt, hash), isTrue);
      expect(Security.verifyPassword('خطأ', salt, hash), isFalse);
    });

    test('كلمتا مرور مختلفتان تعطيان هاشين مختلفين', () {
      final salt = Security.generateSalt();
      expect(Security.hashPassword('a123456', salt), isNot(Security.hashPassword('b123456', salt)));
    });
  });

  group('الصلاحيات', () {
    test('المالك يملك كل الصلاحيات', () {
      expect(Perms.roleHas(Roles.owner, Perms.tenantManage), isTrue);
      expect(Perms.roleHas(Roles.owner, Perms.userManage), isTrue);
    });

    test('المعلم لا يملك إدارة المستخدمين', () {
      expect(Perms.roleHas(Roles.teacher, Perms.userManage), isFalse);
      expect(Perms.roleHas(Roles.teacher, Perms.gradeWrite), isTrue);
    });

    test('موظف الحضور لا يملك إدارة المدارس', () {
      expect(Perms.roleHas(Roles.attendance, Perms.tenantManage), isFalse);
      expect(Perms.roleHas(Roles.attendance, Perms.attendanceScreen), isTrue);
    });
  });

  group('الطلاب', () {
    test('إنشاء طالب وبحثه بالرقم المدرسي', () async {
      final repo = StudentRepository();
      await repo.create(Student(
        id: '',
        schoolId: schoolId,
        studentNumber: '1001',
        fullName: 'أحمد محمد',
      ));
      final found = await repo.byNumber(schoolId, '1001');
      expect(found, isNotNull);
      expect(found!.fullName, 'أحمد محمد');
    });

    test('منع تكرار الرقم المدرسي', () async {
      final repo = StudentRepository();
      expect(
        () => repo.create(Student(id: '', schoolId: schoolId, studentNumber: '1001', fullName: 'آخر')),
        throwsA(isA<Exception>()),
      );
    });

    test('البحث بالاسم يعيد نتائج', () async {
      final repo = StudentRepository();
      await repo.create(Student(id: '', schoolId: schoolId, studentNumber: '1002', fullName: 'سارة علي'));
      final results = await repo.search(schoolId, 'سارة');
      expect(results.any((s) => s.studentNumber == '1002'), isTrue);
    });

    test('حفظ وعرض بيانات التواصل والسكن وملف كامل', () async {
      final repo = StudentRepository();
      final id = await repo.create(Student(
        id: '',
        schoolId: schoolId,
        studentNumber: '1003',
        fullName: 'حسين كريم',
        guardianName: 'كريم حسين',
        guardianPhone: '07701234567',
        residence: 'الكرادة',
      ));
      final profile = await repo.fullProfile(id);
      expect(profile, isNotNull);
      expect(profile!['guardian_phone'], '07701234567');
      expect(profile['residence'], 'الكرادة');
    });

    test('الحقول المخصّصة: تعريف حقل وحفظ قيمته للطالب', () async {
      final colRepo = StudentColumnsRepository();
      final students = StudentRepository();
      final sid = await students.create(Student(
          id: '', schoolId: schoolId, studentNumber: '1004', fullName: 'مريم صالح'));
      final colId = await colRepo.addColumn(schoolId: schoolId, label: 'الدم', dataType: 'text');
      await colRepo.setValues(sid, {colId: 'O+'});
      final values = await colRepo.valuesForStudent(sid);
      expect(values[colId], 'O+');
      // تحديث القيمة لا يُنشئ صفاً مكرراً
      await colRepo.setValues(sid, {colId: 'A+'});
      final updated = await colRepo.valuesForStudent(sid);
      expect(updated[colId], 'A+');
    });
  });

  group('الحضور ومنع التكرار', () {
    test('تسجيل الحضور مرة واحدة فقط', () async {
      final students = StudentRepository();
      final id = await students.create(Student(
        id: '', schoolId: schoolId, studentNumber: '2001', fullName: 'طالب الحضور'));
      final att = AttendanceRepository();

      final r1 = await att.record(studentId: id, sessionType: 'morning', status: 'present');
      expect(r1.outcome, RecordOutcome.recorded);

      final r2 = await att.record(studentId: id, sessionType: 'morning', status: 'present');
      expect(r2.outcome, RecordOutcome.duplicate);
    });

    test('client_uuid المكرر يُرفض (منع التكرار عند المزامنة)', () async {
      final students = StudentRepository();
      final id = await students.create(Student(
        id: '', schoolId: schoolId, studentNumber: '2002', fullName: 'طالب المزامنة'));
      final att = AttendanceRepository();
      final cuuid = 'fixed-uuid-123';

      final r1 = await att.record(
          studentId: id, sessionType: 'morning', status: 'present', clientUuid: cuuid);
      expect(r1.outcome, RecordOutcome.recorded);
      final r2 = await att.record(
          studentId: id, sessionType: 'morning', status: 'present', clientUuid: cuuid);
      expect(r2.outcome, RecordOutcome.duplicate);
    });

    test('الانصراف لا يُحتسب حضوراً صباحياً', () async {
      final students = StudentRepository();
      final id = await students.create(Student(
        id: '', schoolId: schoolId, studentNumber: '2003', fullName: 'طالب الانصراف'));
      final att = AttendanceRepository();
      final morning = await att.record(studentId: id, sessionType: 'morning', status: 'present');
      final checkout = await att.record(studentId: id, sessionType: 'checkout', status: 'early_leave');
      expect(morning.outcome, RecordOutcome.recorded);
      expect(checkout.outcome, RecordOutcome.recorded);

      final recs = await att.byDate(_today());
      final forStudent = recs.where((r) => r.studentId == id).toList();
      expect(forStudent.length, 2);
      expect(forStudent.any((r) => r.sessionType == 'morning'), isTrue);
      expect(forStudent.any((r) => r.sessionType == 'checkout'), isTrue);
    });

    test('تعديل الحضور يسجّل تدقيقاً بسبب إلزامي', () async {
      final students = StudentRepository();
      final id = await students.create(Student(
        id: '', schoolId: schoolId, studentNumber: '2004', fullName: 'طالب التعديل'));
      final userId = await AuthRepository().createUser(
        username: 'editor1',
        password: 'secret123',
        fullName: 'مشرف الحضور',
        schoolId: schoolId,
        roleCode: Roles.manager,
      );
      final att = AttendanceRepository();
      final r = await att.record(studentId: id, sessionType: 'morning', status: 'absent');
      await att.overrideStatus(
        recordId: r.recordId!,
        newStatus: 'excused',
        changedByUserId: userId,
        reason: 'إذن طبي معتمد',
      );
      final recs = await att.byDate(_today());
      final rec = recs.firstWhere((x) => x.id == r.recordId);
      expect(rec.status, 'excused');

      final db = await AppDatabase.instance.database;
      final audit = await db.query('attendance_audit',
          where: 'attendance_record_id = ?', whereArgs: [r.recordId]);
      expect(audit.length, 1);
      expect(audit.first['reason'], 'إذن طبي معتمد');
      expect(audit.first['old_status'], 'absent');
      expect(audit.first['new_status'], 'excused');
    });

    test('إحصاءات اليوم صحيحة', () async {
      final att = AttendanceRepository();
      final stats = await att.dailyStats(_today());
      expect(stats['present']! >= 2, isTrue);
    });
  });

  group('مطابقة الوجه', () {
    test('يطابق تمثيلاً مطابقاً بدقة عالية', () {
      final index = FaceIndex();
      final a = _vec([1.0, 0, 0, 0]);
      final b = _vec([0, 1.0, 0, 0]);
      index.build([
        BiometricTemplate(id: 't1', studentId: 's1', templateEncrypted: _toBytes(a)),
        BiometricTemplate(id: 't2', studentId: 's2', templateEncrypted: _toBytes(b)),
      ]);
      final m = index.identify(a, threshold: 0.5, margin: 0.01);
      expect(m.accepted, isTrue);
      expect(m.studentId, 's1');
    });

    test('يعيد no_match عندما لا يوجد تشابه كافٍ', () {
      final index = FaceIndex();
      final a = _vec([1.0, 0, 0, 0]);
      index.build([BiometricTemplate(id: 't1', studentId: 's1', templateEncrypted: _toBytes(a))]);
      final probe = _vec([0, 0, 0, 1.0]);
      final m = index.identify(probe, threshold: 0.45);
      expect(m.accepted, isFalse);
      expect(m.result, 'no_match');
    });

    test('يرفض التباس طالبين متشابهين (لا تخمين)', () {
      final index = FaceIndex();
      final a = _vec([1.0, 0, 0, 0]);
      final b = _vec([0.99, 0.01, 0, 0]);
      index.build([
        BiometricTemplate(id: 't1', studentId: 's1', templateEncrypted: _toBytes(a)),
        BiometricTemplate(id: 't2', studentId: 's2', templateEncrypted: _toBytes(b)),
      ]);
      final m = index.identify(_vec([1.0, 0, 0, 0]), threshold: 0.45, margin: 0.05);
      expect(m.result, 'ambiguous');
      expect(m.accepted, isFalse);
    });

    test('الأداء: مطابقة على 5000 تمثيل سريعة', () {
      final index = FaceIndex();
      final templates = List.generate(5000, (i) {
        final v = Float32List(128);
        for (var j = 0; j < 128; j++) {
          v[j] = ((i + j) % 7) - 3.0;
        }
        _normalize(v);
        return BiometricTemplate(id: 't$i', studentId: 's$i', templateEncrypted: _toBytes(v));
      });
      index.build(templates);
      expect(index.size, 5000);
      final probe = _vec(_randomNorm(128));
      final sw = Stopwatch()..start();
      for (var k = 0; k < 10; k++) {
        index.identify(probe);
      }
      sw.stop();
      // 10 مطابقات على 5000 طالب يجب أن تكون سريعة جداً
      expect(sw.elapsedMilliseconds < 2000, isTrue);
    });
  });

  group('البيانات الحيوية', () {
    test('حفظ التمثيل واسترجاعه', () async {
      final students = StudentRepository();
      final id = await students.create(Student(
        id: '', schoolId: schoolId, studentNumber: '3001', fullName: 'طالب الوجه'));
      final bio = BiometricRepository();
      final emb = Float32List.fromList(List.generate(128, (i) => i / 128.0));
      await bio.upsertTemplate(studentId: id, embedding: emb, quality: 0.9);
      final all = await bio.loadAllActive();
      expect(all.any((t) => t.studentId == id), isTrue);
      expect(await bio.countEnrolled() >= 1, isTrue);
    });

    test('تخزين القالب مشفّراً فعلياً ويُسترجع سليماً', () async {
      final students = StudentRepository();
      final id = await students.create(Student(
          id: '', schoolId: schoolId, studentNumber: '3002', fullName: 'طالب مشفّر'));
      final bio = BiometricRepository();
      final emb = Float32List.fromList(List.generate(128, (i) => i / 128.0));
      await bio.upsertTemplate(studentId: id, embedding: emb, quality: 0.9);

      // القيمة المخزّنة في القاعدة يجب أن تكون نصاً مشفّراً لا بايتات خام.
      final db = await AppDatabase.instance.database;
      final raw = await db.query('biometric_templates',
          where: 'student_id = ?', whereArgs: [id], limit: 1);
      expect(raw.first['template_encrypted'], isA<String>());
      expect((raw.first['template_encrypted'] as String).startsWith('encv1:'), isTrue);

      // القراءة تعيد البايتات الخام ويستطيع FaceIndex بناءها.
      final loaded = await bio.loadAllActive();
      final t = loaded.firstWhere((e) => e.studentId == id);
      expect(t.templateEncrypted.length, 128 * 4);
    });

    test('تسجيل محاولة تعرّف يكتب school_id ويُنشئ مراجعة للحالات الملتبسة', () async {
      final bio = BiometricRepository();
      final attemptId = await bio.logAttempt(
          result: 'no_match', deviceId: null, confidence: 0.2, schoolId: schoolId);
      expect(attemptId, isNotEmpty);
      final db = await AppDatabase.instance.database;
      final a = await db.query('recognition_attempts', where: 'id = ?', whereArgs: [attemptId]);
      expect(a.first['school_id'], schoolId);
      final r = await db.query('recognition_reviews', where: 'attempt_id = ?', whereArgs: [attemptId]);
      expect(r, isNotEmpty);
      expect(r.first['school_id'], schoolId);
    });
  });

  group('عزل المدارس', () {
    test('بيانات مدرسة لا تظهر لمدرسة أخرى', () async {
      final db = await AppDatabase.instance.database;
      final now = DateTime.now().toUtc().toIso8601String();
      await db.insert('schools', {
        'id': 'school-2',
        'name': 'مدرسة أخرى',
        'timezone': 'Asia/Baghdad',
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      });
      await StudentRepository().create(Student(
        id: '', schoolId: 'school-2', studentNumber: '5001', fullName: 'طالب المدرسة الأخرى'));

      final school1Students = await StudentRepository().search(schoolId, '');
      expect(school1Students.any((s) => s.studentNumber == '5001'), isFalse);

      final school2Students = await StudentRepository().search('school-2', '');
      expect(school2Students.any((s) => s.studentNumber == '5001'), isTrue);
    });
  });

  group('الهيكل المدرسي', () {
    test('إضافة مرحلة وصف وشعبة وربط الطالب بها', () async {
      final acad = AcademicRepository();
      final stageId = await acad.addStage(schoolId: schoolId, name: 'الابتدائية');
      final gradeId = await acad.addGrade(stageId: stageId, name: 'الأول');
      final yearId = await _currentYear();
      final sectionId = await acad.addSection(gradeId: gradeId, academicYearId: yearId, name: 'أ');

      final sections = await acad.sectionsWithNames(schoolId, yearId);
      expect(sections.any((s) => s['name'] == 'أ'), isTrue);

      final sid = await StudentRepository().create(Student(
          id: '', schoolId: schoolId, studentNumber: '9001', fullName: 'طالب شعبة', sectionId: sectionId));
      final inSection = await StudentRepository().bySection(sectionId);
      expect(inSection.map((e) => e.id), contains(sid));
    });

    test('منع حذف شعبة مرتبطة بطلاب', () async {
      final acad = AcademicRepository();
      final stageId = await acad.addStage(schoolId: schoolId, name: 'الثانوية');
      final gradeId = await acad.addGrade(stageId: stageId, name: 'الثاني');
      final yearId = await _currentYear();
      final sectionId = await acad.addSection(gradeId: gradeId, academicYearId: yearId, name: 'ب');
      await StudentRepository().create(Student(
          id: '', schoolId: schoolId, studentNumber: '9002', fullName: 'طالب مرتبط', sectionId: sectionId));

      expect(await acad.sectionHasRecords(sectionId), isTrue);
      await expectLater(acad.archiveSection(sectionId), throwsStateError);
    });

    test('منع تكرار اسم المرحلة داخل المدرسة', () async {
      final acad = AcademicRepository();
      await acad.addStage(schoolId: schoolId, name: 'مرحلة فريدة');
      await expectLater(acad.addStage(schoolId: schoolId, name: 'مرحلة فريدة'), throwsA(anything));
    });

    test('تكليف مدرّس بمادة وشعبة', () async {
      final acad = AcademicRepository();
      final teacherId = await acad.addTeacher(schoolId: schoolId, employeeNo: 'T100', fullName: 'أستاذ الرياضيات');
      final subjectId = await acad.addSubject(schoolId: schoolId, name: 'الرياضيات');
      final yearId = await _currentYear();
      final stageId = await acad.addStage(schoolId: schoolId, name: 'مرحلة التكليف');
      final gradeId = await acad.addGrade(stageId: stageId, name: 'الثالث');
      final sectionId = await acad.addSection(gradeId: gradeId, academicYearId: yearId, name: 'ج');

      await acad.assignTeacher(
          teacherId: teacherId, subjectId: subjectId, sectionId: sectionId, academicYearId: yearId);
      final list = await acad.assignments(schoolId, yearId);
      expect(list.any((a) => a['teacher_name'] == 'أستاذ الرياضيات' && a['subject_name'] == 'الرياضيات'), isTrue);
    });
  });

  group('الدرجات والامتحانات', () {
    test('إدخال درجة داخل النطاق ورفض خارج النطاق', () async {
      final acad = AcademicRepository();
      final repo = GradeRepository();
      final subjectId = await acad.addSubject(schoolId: schoolId, name: 'العلوم');
      final yearId = await _currentYear();
      final stageId = await acad.addStage(schoolId: schoolId, name: 'مرحلة الدرجات');
      final gradeId = await acad.addGrade(stageId: stageId, name: 'الرابع');
      final sectionId = await acad.addSection(gradeId: gradeId, academicYearId: yearId, name: 'د');
      final studentId = await StudentRepository().create(Student(
          id: '', schoolId: schoolId, studentNumber: '9500', fullName: 'طالب الدرجات', sectionId: sectionId));

      final examId = await repo.createExam(
          subjectId: subjectId, sectionId: sectionId, academicYearId: yearId,
          examType: 'شهري', maxScore: 100, passScore: 50);

      await repo.setScore(examId: examId, studentId: studentId, score: 87, enteredBy: 'u1');
      final scores = await repo.examScores(examId);
      expect(scores.any((s) => s['full_name'] == 'طالب الدرجات' && (s['score'] as num).toDouble() == 87), isTrue);

      await expectLater(
        repo.setScore(examId: examId, studentId: studentId, score: 120, enteredBy: 'u1'),
        throwsStateError,
      );
    });

    test('تصحيح درجة يسجّل تدقيقاً بسبب إلزامي', () async {
      final acad = AcademicRepository();
      final repo = GradeRepository();
      final subjectId = await acad.addSubject(schoolId: schoolId, name: 'اللغة');
      final yearId = await _currentYear();
      final stageId = await acad.addStage(schoolId: schoolId, name: 'مرحلة التصحيح');
      final gradeId = await acad.addGrade(stageId: stageId, name: 'الخامس');
      final sectionId = await acad.addSection(gradeId: gradeId, academicYearId: yearId, name: 'هـ');
      final studentId = await StudentRepository().create(Student(
          id: '', schoolId: schoolId, studentNumber: '9501', fullName: 'طالب التصحيح', sectionId: sectionId));
      final examId = await repo.createExam(
          subjectId: subjectId, sectionId: sectionId, academicYearId: yearId, examType: 'نهائي', maxScore: 50);

      await repo.setScore(examId: examId, studentId: studentId, score: 30, enteredBy: 'u1');
      final before = await repo.auditCount();
      // تصحيح بسبب
      await repo.setScore(
          examId: examId, studentId: studentId, score: 40, enteredBy: 'u1', isCorrection: true, reason: 'خطأ في الرصد');
      expect(await repo.auditCount(), before + 1);
      // تصحيح دون سبب يُرفض
      await expectLater(
        repo.setScore(examId: examId, studentId: studentId, score: 45, enteredBy: 'u1', isCorrection: true),
        throwsStateError,
      );
    });

    test('المجموع المرجّح يُحسب بقواعد قابلة للضبط', () async {
      final acad = AcademicRepository();
      final repo = GradeRepository();
      final subjectId = await acad.addSubject(schoolId: schoolId, name: 'الرياضة');
      final yearId = await _currentYear();
      final stageId = await acad.addStage(schoolId: schoolId, name: 'مرحلة المجموع');
      final gradeId = await acad.addGrade(stageId: stageId, name: 'السادس');
      final sectionId = await acad.addSection(gradeId: gradeId, academicYearId: yearId, name: 'و');
      final studentId = await StudentRepository().create(Student(
          id: '', schoolId: schoolId, studentNumber: '9502', fullName: 'طالب المجموع', sectionId: sectionId));

      final e1 = await repo.createExam(
          subjectId: subjectId, sectionId: sectionId, academicYearId: yearId, examType: 'شهري1', maxScore: 100, weight: 1);
      final e2 = await repo.createExam(
          subjectId: subjectId, sectionId: sectionId, academicYearId: yearId, examType: 'شهري2', maxScore: 50, weight: 1);
      await repo.setScore(examId: e1, studentId: studentId, score: 80, enteredBy: 'u1');
      await repo.setScore(examId: e2, studentId: studentId, score: 40, enteredBy: 'u1'); // 40/50 = 80%

      final total = await repo.weightedTotal(studentId, subjectId, yearId);
      expect(total, closeTo(80, 0.01));
    });
  });

  group('التقييم الأسبوعي التراكمي', () {
    test('تسجيل تقييم أسبوعي وحساب المتوسط التراكمي', () async {
      final acad = AcademicRepository();
      final eval = EvaluationRepository();
      final subjectId = await acad.addSubject(schoolId: schoolId, name: 'التقييم-رياضيات');
      final yearId = await _currentYear();
      final studentId = await StudentRepository().create(Student(
          id: '', schoolId: schoolId, studentNumber: '9700', fullName: 'طالب التقييم'));

      await eval.setEvaluation(
          schoolId: schoolId, studentId: studentId, subjectId: subjectId,
          academicYearId: yearId, weekNo: 1, score: 8, maxScore: 10);
      await eval.setEvaluation(
          schoolId: schoolId, studentId: studentId, subjectId: subjectId,
          academicYearId: yearId, weekNo: 2, score: 6, maxScore: 10);

      final cum = await eval.cumulativeBySubject(studentId, yearId);
      final row = cum.firstWhere((c) => c['subject_id'] == subjectId);
      expect(row['weeks'], 2);
      expect((row['weighted_avg'] as num).toDouble(), closeTo(7, 0.001));
      final overall = await eval.overallAverage(studentId, yearId);
      expect(overall, closeTo(70, 0.001));
    });

    test('تحديث تقييم نفس الأسبوع لا يُنشئ صفاً مكرراً', () async {
      final acad = AcademicRepository();
      final eval = EvaluationRepository();
      final subjectId = await acad.addSubject(schoolId: schoolId, name: 'التقييم-علوم');
      final yearId = await _currentYear();
      final studentId = await StudentRepository().create(Student(
          id: '', schoolId: schoolId, studentNumber: '9701', fullName: 'طالب تقييم2'));
      await eval.setEvaluation(
          schoolId: schoolId, studentId: studentId, subjectId: subjectId,
          academicYearId: yearId, weekNo: 3, score: 5, maxScore: 10);
      await eval.setEvaluation(
          schoolId: schoolId, studentId: studentId, subjectId: subjectId,
          academicYearId: yearId, weekNo: 3, score: 9, maxScore: 10);
      expect(await eval.countForStudent(studentId), 1);
      final rows = await eval.studentSubjectEvaluations(studentId, subjectId, yearId);
      expect((rows.first['score'] as num).toDouble(), 9);
    });

    test('رفض درجة خارج النطاق', () async {
      final acad = AcademicRepository();
      final eval = EvaluationRepository();
      final subjectId = await acad.addSubject(schoolId: schoolId, name: 'التقييم-حدود');
      final yearId = await _currentYear();
      final studentId = await StudentRepository().create(Student(
          id: '', schoolId: schoolId, studentNumber: '9702', fullName: 'طالب تقييم3'));
      await expectLater(
        eval.setEvaluation(
            schoolId: schoolId, studentId: studentId, subjectId: subjectId,
            academicYearId: yearId, weekNo: 1, score: 12, maxScore: 10),
        throwsArgumentError,
      );
    });
  });

  group('ترحيل نهاية السنة', () {
    test('الناجح يُنقل للشعبة الجديدة والراسب يبقى، مع توثيق الحركات', () async {
      final acad = AcademicRepository();
      final yearId = await _currentYear();
      final stageId = await acad.addStage(schoolId: schoolId, name: 'مرحلة الترحيل');
      final gradeId = await acad.addGrade(stageId: stageId, name: 'الأول');
      final fromSection = await acad.addSection(gradeId: gradeId, academicYearId: yearId, name: 'أ');
      final toSection = await acad.addSection(gradeId: gradeId, academicYearId: yearId, name: 'ب');
      final pass = await StudentRepository().create(Student(
          id: '', schoolId: schoolId, studentNumber: '9800', fullName: 'ناجح', sectionId: fromSection));
      final repeat = await StudentRepository().create(Student(
          id: '', schoolId: schoolId, studentNumber: '9801', fullName: 'راسب', sectionId: fromSection));

      await StudentRepository().promoteForNewYear(
        schoolId: schoolId,
        newAcademicYearId: yearId,
        moves: {pass: toSection, repeat: fromSection},
        reason: 'اختبار الترحيل',
      );

      final p = await StudentRepository().byId(pass);
      final r = await StudentRepository().byId(repeat);
      expect(p!.sectionId, toSection);
      expect(r!.sectionId, fromSection);

      final db = await AppDatabase.instance.database;
      final moves = await db.query('student_movements', where: 'student_id IN (?, ?)', whereArgs: [pass, repeat]);
      expect(moves.length, 2);
    });
  });

  group('رسائل واتساب الجاهزة', () {
    test('تطبيع أرقام الهاتف العراقية للصيغة الدولية', () {
      expect(WhatsappHelper.normalize('07701234567'), '9647701234567');
      expect(WhatsappHelper.normalize('+964 770 123 4567'), '9647701234567');
      expect(WhatsappHelper.normalize('009647701234567'), '9647701234567');
      expect(WhatsappHelper.normalize('9647701234567'), '9647701234567');
      expect(WhatsappHelper.normalize(''), '');
    });

    test('بناء رسالة تقييم تحتوي اسم الطالب والمواد والمعدّل', () {
      final msg = WhatsappHelper.evaluationMessage(
        schoolName: 'مدرسة الاختبار',
        studentName: 'أحمد علي',
        className: 'الابتدائية / الأول / أ',
        subjects: [
          {'subject_name': 'الرياضيات', 'weighted_avg': 8.5, 'max_score': 10, 'weeks': 4},
          {'subject_name': 'العلوم', 'weighted_avg': 7.0, 'max_score': 10, 'weeks': 3},
        ],
        overall: 78.0,
      );
      expect(msg, contains('أحمد علي'));
      expect(msg, contains('الرياضيات'));
      expect(msg, contains('8.5'));
      expect(msg, contains('78.0%'));
    });

    test('حساب المعلم: يُمنح صلاحيات التقييم ورفع الطالب لكن لا يدير المستخدمين', () {
      expect(Perms.roleHas(Roles.teacher, Perms.studentWrite), isTrue);
      expect(Perms.roleHas(Roles.teacher, Perms.evaluationWrite), isTrue);
      expect(Perms.roleHas(Roles.teacher, Perms.biometricManage), isTrue);
      expect(Perms.roleHas(Roles.teacher, Perms.userManage), isFalse);
    });

    test('الطالب والولي يقرآن التقييم فقط ولا يكتبانه', () {
      expect(Perms.roleHas(Roles.student, Perms.evaluationRead), isTrue);
      expect(Perms.roleHas(Roles.student, Perms.evaluationWrite), isFalse);
      expect(Perms.roleHas(Roles.guardian, Perms.evaluationRead), isTrue);
      expect(Perms.roleHas(Roles.guardian, Perms.evaluationWrite), isFalse);
    });
  });

  group('تقارير التقييم', () {
    test('تقرير التقييمات في نطاق زمني يعيد الصفوف الصحيحة', () async {
      final acad = AcademicRepository();
      final eval = EvaluationRepository();
      final reports = ReportsRepository();
      final subjectId = await acad.addSubject(schoolId: schoolId, name: 'تقارير-عربي');
      final yearId = await _currentYear();
      final sid = await StudentRepository().create(Student(
          id: '', schoolId: schoolId, studentNumber: '9900', fullName: 'طالب تقرير'));
      await eval.setEvaluation(
          schoolId: schoolId, studentId: sid, subjectId: subjectId,
          academicYearId: yearId, weekNo: 5, score: 7, maxScore: 10);

      final today = _today();
      final rows = await reports.evaluationsBySubject(schoolId, today, today);
      expect(rows.any((r) => r['student_number'] == '9900' && r['subject_name'] == 'تقارير-عربي'), isTrue);
    });

    test('المعدّل التراكمي لكل طالب يُحسب كنسبة صحيحة', () async {
      final acad = AcademicRepository();
      final eval = EvaluationRepository();
      final reports = ReportsRepository();
      final subjectId = await acad.addSubject(schoolId: schoolId, name: 'تقارير-رياضيات');
      final yearId = await _currentYear();
      final sid = await StudentRepository().create(Student(
          id: '', schoolId: schoolId, studentNumber: '9901', fullName: 'طالب معدّل'));
      await eval.setEvaluation(schoolId: schoolId, studentId: sid, subjectId: subjectId,
          academicYearId: yearId, weekNo: 1, score: 9, maxScore: 10);
      await eval.setEvaluation(schoolId: schoolId, studentId: sid, subjectId: subjectId,
          academicYearId: yearId, weekNo: 2, score: 9, maxScore: 10);
      final rows = await reports.cumulativeEvaluationSummary(schoolId);
      final row = rows.firstWhere((r) => r['student_number'] == '9901');
      expect((row['avg_pct'] as num).toDouble(), closeTo(90, 0.1));
      expect(row['weeks'], 2);
    });
  });

  group('منصة المالك (تعدد المدارس)', () {
    test('المالك ينشئ مدرسة معزولة مع مديرها وإعداداتها وسنتها', () async {
      final repo = SchoolRepository();
      final id = await repo.createSchool(
        name: 'مدرسة الرافدين',
        managerUsername: 'rafidain_mgr',
        managerPassword: 'secret123',
        managerName: 'أ. مدير الرافدين',
        seedStageNames: ['الابتدائية'],
        seedGrades: [
          ['الأول', 'الثاني']
        ],
      );
      expect(id, isNotEmpty);

      final school = await repo.byId(id);
      expect(school, isNotNull);
      expect(school!['name'], 'مدرسة الرافدين');

      // إعدادات وسنة دراسية أُنشئتا تلقائياً
      final db = await AppDatabase.instance.database;
      final settings = await db.query('attendance_settings', where: 'school_id = ?', whereArgs: [id]);
      expect(settings, isNotEmpty);
      final years = await db.query('academic_years', where: 'school_id = ? AND is_current = 1', whereArgs: [id]);
      expect(years, isNotEmpty);
      // هيكل مبدئي
      final stages = await db.query('stages', where: 'school_id = ?', whereArgs: [id]);
      expect(stages.map((e) => e['name']), contains('الابتدائية'));
      final stageId = stages.first['id'];
      final grades = await db.query('grades', where: 'stage_id = ?', whereArgs: [stageId]);
      expect(grades.length, 2);
    });

    test('مدير المدرسة يستطيع الدخول ببياناته ويرتبط بمدرسته فقط', () async {
      final repo = SchoolRepository();
      final id = await repo.createSchool(
        name: 'مدرسة دجلة',
        managerUsername: 'dijla_mgr',
        managerPassword: 'secret123',
      );
      final user = await AuthRepository().login('dijla_mgr', 'secret123');
      expect(user, isNotNull);
      expect(user!['school_id'], id);
      expect((user['roles'] as List).contains(Roles.manager), isTrue);
      expect((user['roles'] as List).contains(Roles.owner), isFalse);
    });

    test('تعطيل المدرسة يعطّل حساباتها (لا دخول)', () async {
      final repo = SchoolRepository();
      final id = await repo.createSchool(
        name: 'مدرسة الفرات',
        managerUsername: 'furat_mgr',
        managerPassword: 'secret123',
      );
      expect(await AuthRepository().login('furat_mgr', 'secret123'), isNotNull);
      await repo.setActive(id, false);
      expect(await AuthRepository().login('furat_mgr', 'secret123'), isNull);
    });

    test('حساب الطالب يُربط بملف طالب ويعيد student_id عند الدخول', () async {
      final sid = await StudentRepository().create(Student(
          id: '', schoolId: schoolId, studentNumber: '9950', fullName: 'طالب حساب'));
      await AuthRepository().createUser(
        username: 'student_acc',
        password: 'secret123',
        fullName: 'طالب حساب',
        schoolId: schoolId,
        roleCode: Roles.student,
        studentId: sid,
      );
      final user = await AuthRepository().login('student_acc', 'secret123');
      expect(user, isNotNull);
      expect(user!['student_id'], sid);
      expect((user['roles'] as List).contains(Roles.student), isTrue);
    });

    test('بيانات مدرستين معزولة تماماً (طلاب)', () async {
      final repo = SchoolRepository();
      final a = await repo.createSchool(name: 'مدرسة ألف');
      final b = await repo.createSchool(name: 'مدرسة باء');
      await StudentRepository().create(
          Student(id: '', schoolId: a, studentNumber: 'A-1', fullName: 'طالب ألف'));
      await StudentRepository().create(
          Student(id: '', schoolId: b, studentNumber: 'B-1', fullName: 'طالب باء'));
      final listA = await StudentRepository().search(a, '');
      final listB = await StudentRepository().search(b, '');
      expect(listA.map((s) => s.studentNumber), contains('A-1'));
      expect(listA.any((s) => s.studentNumber == 'B-1'), isFalse);
      expect(listB.map((s) => s.studentNumber), contains('B-1'));
      expect(await repo.all(), isNotEmpty);
    });
  });

  group('استيراد الطلاب (CSV)', () {
    test('تحليل صف رؤوس عربي مع تحقق من التكرار والنواقص', () {
      const csv = 'الرقم المدرسي,الاسم,الجنس,هاتف ولي الأمر\n'
          'S1,أحمد علي,ذكر,07700000001\n'
          'S2,سارة محمد,أنثى,07700000002\n'
          'S1,مكرّر,ذكر,07700000003\n'
          ',بلا رقم,ذكر,\n'
          'S3,,ذكر,\n';
      final res = CsvImportService.parse(csv, schoolId: schoolId);
      expect(res.valid.length, 2);
      expect(res.invalid.length, 3);
      expect(res.valid.first.student!.fullName, 'أحمد علي');
      expect(res.valid.every((r) => r.student!.schoolId == schoolId), isTrue);
    });

    test('استيراد فعلي إلى القاعدة مع تخطّي الموجود مسبقاً', () async {
      final repo = StudentRepository();
      const csv = 'الرقم المدرسي,الاسم\nIMP-1,طالب مستورد أ\nIMP-2,طالب مستورد ب\n';
      final res = CsvImportService.parse(csv, schoolId: schoolId);
      for (final row in res.valid) {
        await repo.create(row.student!);
      }
      expect(await repo.byNumber(schoolId, 'IMP-1'), isNotNull);
      expect(await repo.byNumber(schoolId, 'IMP-2'), isNotNull);
    });

    test('القالب يحتوي ترويسة عربية وصف نموذجي', () {
      final t = CsvImportService.template();
      expect(t.contains('الرقم المدرسي'), isTrue);
      expect(t.contains('الاسم'), isTrue);
    });
  });

  group('طابور المزامنة (العمل دون اتصال)', () {
    test('تسجيل الحضور يُدرج تلقائياً في طابور المزامنة', () async {
      final id = await StudentRepository().create(Student(
        id: '', schoolId: schoolId, studentNumber: '9901-queue', fullName: 'طالب الطابور'));
      final att = AttendanceRepository();
      final before = await SyncQueueRepository().pendingCount(schoolId: schoolId);
      final r = await att.record(studentId: id, sessionType: 'morning', status: 'present', schoolId: schoolId);
      expect(r.outcome, RecordOutcome.recorded);
      final after = await SyncQueueRepository().pendingCount(schoolId: schoolId);
      expect(after, before + 1);
    });

    test('client_uuid المكرر لا يُضاف مرتين إلى الطابور', () async {
      final repo = SyncQueueRepository();
      final before = await repo.pendingCount(schoolId: schoolId);
      await repo.enqueue(
          entityType: 'attendance_record',
          entityId: 'e1',
          operation: 'insert',
          payload: {'x': 1},
          schoolId: schoolId,
          clientUuid: 'cuuid-dup-1');
      await repo.enqueue(
          entityType: 'attendance_record',
          entityId: 'e1',
          operation: 'insert',
          payload: {'x': 1},
          schoolId: schoolId,
          clientUuid: 'cuuid-dup-1');
      expect(await repo.pendingCount(schoolId: schoolId), before + 1);
    });

    test('المزامنة تُفرِّغ الطابور وتُرجع النتيجة', () async {
      final repo = SyncQueueRepository();
      final result = await repo.sync(schoolId: schoolId);
      expect(result.remaining, 0);
      expect(result.synced >= 1, isTrue);
      expect(await repo.pendingCount(schoolId: schoolId), 0);
    });

    test('الفشل المتكرر يضع العنصر في قائمة الفاشلة دون حذفه', () async {
      final repo = SyncQueueRepository();
      await repo.enqueue(
          entityType: 'attendance_record',
          entityId: 'e2',
          operation: 'insert',
          payload: {'x': 2},
          schoolId: schoolId,
          clientUuid: 'cuuid-fail-1');
      for (var i = 0; i < 5; i++) {
        await repo.sync(schoolId: schoolId, pusher: (_) async => false);
      }
      final failed = await repo.failed(schoolId: schoolId);
      expect(failed.any((f) => f.clientUuid == 'cuuid-fail-1'), isTrue);
    });
  });

  group('إعدادات الدوام والعطل والاستراحات', () {
    test('أيام الدوام الافتراضية الأحد→الخميس', () async {
      final repo = SchoolSettingsRepository();
      final days = await repo.workingDays(schoolId);
      expect(days.containsAll({7, 1, 2, 3, 4}), isTrue);
      expect(days.contains(5), isFalse);
      expect(days.contains(6), isFalse);
    });

    test('حفظ واستعادة أيام الدوام', () async {
      final repo = SchoolSettingsRepository();
      await repo.saveWorkingDays(schoolId, {1, 2, 3});
      final days = await repo.workingDays(schoolId);
      expect(days, {1, 2, 3});
      await repo.saveWorkingDays(schoolId, {7, 1, 2, 3, 4});
    });

    test('العطلة تُمنع التسجيل في يومها وليس يوم دوام', () async {
      final repo = SchoolSettingsRepository();
      final today = _today();
      await repo.addHoliday(schoolId, Holiday(id: '', dateFrom: today, dateTo: today, type: 'official', title: 'عطلة اختبار'));
      expect(await repo.isWorkingDay(schoolId, today), isFalse);
      final h = await repo.holidayFor(schoolId, today);
      expect(h, isNotNull);
      expect(h!.title, 'عطلة اختبار');
      // تنظيف
      await repo.removeHoliday(h.id);
    });

    test('حفظ واستعادة الاستراحات', () async {
      final repo = SchoolSettingsRepository();
      await repo.saveBreaks(schoolId, [BreakSlot(label: 'استراحة الفسحة', start: '09:30', end: '09:50')]);
      final breaks = await repo.breaks(schoolId);
      expect(breaks.length, 1);
      expect(breaks.first.label, 'استراحة الفسحة');
      await repo.saveBreaks(schoolId, []);
    });

    test('قواعد الانصراف قابلة للضبط', () async {
      final repo = SchoolSettingsRepository();
      await repo.saveCheckoutRules(schoolId, {'min_before_end': 10, 'early_leave_before': '11:30'});
      final rules = await repo.checkoutRules(schoolId);
      expect(rules['early_leave_before'], '11:30');
      expect(rules['min_before_end'], 10);
    });
  });
}

String _today() {
  final d = DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// يعيد السنة الدراسية الحالية للمدرسة أو ينشئها (للاختبارات التي تحتاج شعبة).
Future<String> _currentYear() async {
  final db = await AppDatabase.instance.database;
  final rows = await db.query('academic_years',
      where: 'school_id = ? AND deleted_at IS NULL', whereArgs: ['school-1'], orderBy: 'is_current DESC', limit: 1);
  if (rows.isNotEmpty) return rows.first['id'] as String;
  final now = DateTime.now().toUtc().toIso8601String();
  final id = 'year-test';
  await db.insert('academic_years', {
    'id': id,
    'school_id': 'school-1',
    'name': '2025/2026',
    'start_date': '2025-09-01',
    'end_date': '2026-06-30',
    'is_current': 1,
    'created_at': now,
    'updated_at': now,
  });
  return id;
}

Float32List _vec(List<double> v) {
  final f = Float32List(128);
  for (var i = 0; i < v.length; i++) {
    f[i] = v[i];
  }
  return f;
}

Float32List _randomNorm(int n) {
  final f = Float32List(n);
  for (var i = 0; i < n; i++) {
    f[i] = (i % 5) - 2.0;
  }
  _normalize(f);
  return f;
}

void _normalize(Float32List v) {
  var norm = 0.0;
  for (final x in v) {
    norm += x * x;
  }
  norm = norm == 0 ? 1 : (norm).abs().toDouble();
  final s = _sqrt(norm);
  for (var i = 0; i < v.length; i++) {
    v[i] = v[i] / s;
  }
}

double _sqrt(double x) {
  var g = x;
  for (var i = 0; i < 30; i++) {
    g = 0.5 * (g + x / g);
  }
  return g;
}

List<int> _toBytes(Float32List floats) {
  final bd = ByteData(floats.length * 4);
  for (var i = 0; i < floats.length; i++) {
    bd.setFloat32(i * 4, floats[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}
