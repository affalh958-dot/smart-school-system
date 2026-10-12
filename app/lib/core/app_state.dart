import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/permissions.dart';
import '../data/biometric_repository.dart';
import '../data/database.dart';
import '../data/models.dart';
import '../face/face_engine.dart';
import '../face/face_index.dart';

/// الحالة العامة للتطبيق: المستخدم الحالي، المدرسة، الصلاحيات، ومحرّك الوجه.
class AppState extends ChangeNotifier {
  final FaceEngine faceEngine = FaceEngine();
  final FaceIndex faceIndex = FaceIndex();
  final BiometricRepository biometrics = BiometricRepository();
  final _uuid = const Uuid();

  Map<String, dynamic>? _user;
  String? _schoolId;
  String _schoolName = '';
  List<String> _roles = [];
  String? _deviceId;
  bool _busy = false;

  Map<String, dynamic>? get user => _user;
  String? get schoolId => _schoolId;
  String get schoolName => _schoolName;
  List<String> get roles => _roles;
  String? get deviceId => _deviceId;
  bool get busy => _busy;
  bool get isLoggedIn => _user != null;

  /// الدور الأساسي (الأعلى مرتبة) لعرض القائمة المناسبة.
  String get primaryRole {
    const order = [Roles.owner, Roles.admin, Roles.manager, Roles.attendance, Roles.teacher, Roles.guardian];
    for (final r in order) {
      if (_roles.contains(r)) return r;
    }
    return Roles.guardian;
  }

  bool can(String permission) {
    for (final r in _roles) {
      if (Perms.roleHas(r, permission)) return true;
    }
    return false;
  }

  Future<void> init() async {
    await AppDatabase.instance.database;
    await faceEngine.load();
  }

  void setBusy(bool v) {
    _busy = v;
    notifyListeners();
  }

  void setSession(Map<String, dynamic> user) {
    _user = user;
    _roles = (user['roles'] as List).cast<String>();
    _schoolId = user['school_id'] as String?;
    notifyListeners();
  }

  void setSchool(String id, String name) {
    _schoolId = id;
    _schoolName = name;
    notifyListeners();
  }

  void setDevice(String id) {
    _deviceId = id;
    notifyListeners();
  }

  String ensureDeviceId() {
    _deviceId ??= _uuid.v4();
    return _deviceId!;
  }

  /// إعادة بناء فهرس الوجه من قاعدة البيانات (مقيّد بمدرسة المستخدم الحالي).
  Future<void> rebuildFaceIndex() async {
    final templates = await biometrics.loadAllActive(schoolId: _schoolId);
    faceIndex.build(templates);
    notifyListeners();
  }

  void logout() {
    _user = null;
    _roles = [];
    notifyListeners();
  }

  @override
  void dispose() {
    faceEngine.dispose();
    super.dispose();
  }
}

/// بيانات مساعدة لعرض الطالب في نتائج الحضور.
class StudentView {
  final Student student;
  final String? sectionName;
  StudentView(this.student, this.sectionName);
}
