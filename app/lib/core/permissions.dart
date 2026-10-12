/// تعريف الأدوار والصلاحيات — يُطبَّق من الخادم/الطبقة المنطقية، لا من الواجهة فقط.
class Roles {
  static const owner = 'owner';
  static const admin = 'admin';
  static const manager = 'manager';
  static const attendance = 'attendance';
  static const teacher = 'teacher';
  static const guardian = 'guardian';

  static const Map<String, String> labels = {
    owner: 'المالك / مسؤول المنصة',
    admin: 'مسؤول النظام',
    manager: 'مدير المدرسة',
    attendance: 'موظف الحضور',
    teacher: 'معلم',
    guardian: 'ولي أمر',
  };
}

class Perms {
  static const dashboardRead = 'dashboard.read';
  static const studentRead = 'student.read';
  static const studentWrite = 'student.write';
  static const studentDelete = 'student.delete';
  static const attendanceRead = 'attendance.read';
  static const attendanceWrite = 'attendance.write';
  static const attendanceScreen = 'attendance.screen';
  static const gradeRead = 'grade.read';
  static const gradeWrite = 'grade.write';
  static const reportRead = 'report.read';
  static const userManage = 'user.manage';
  static const settingsManage = 'settings.manage';
  static const biometricManage = 'biometric.manage';
  static const deviceManage = 'device.manage';
  static const backupManage = 'backup.manage';
  static const auditRead = 'audit.read';
  static const tenantManage = 'tenant.manage';

  /// خريطة الصلاحيات لكل دور (مطابقة لجدول role_permissions في قاعدة البيانات).
  static const Map<String, List<String>> byRole = {
    Roles.owner: [
      dashboardRead, studentRead, studentWrite, studentDelete, attendanceRead,
      attendanceWrite, attendanceScreen, gradeRead, gradeWrite, reportRead,
      userManage, settingsManage, biometricManage, deviceManage, backupManage,
      auditRead, tenantManage,
    ],
    Roles.admin: [
      dashboardRead, studentRead, studentWrite, studentDelete, attendanceRead,
      attendanceWrite, attendanceScreen, gradeRead, gradeWrite, reportRead,
      userManage, settingsManage, biometricManage, deviceManage, backupManage,
      auditRead,
    ],
    Roles.manager: [
      dashboardRead, studentRead, studentWrite, attendanceRead, attendanceWrite,
      gradeRead, reportRead, auditRead, settingsManage,
    ],
    Roles.attendance: [
      dashboardRead, studentRead, attendanceRead, attendanceWrite,
      attendanceScreen, reportRead,
    ],
    Roles.teacher: [studentRead, gradeRead, gradeWrite, attendanceRead],
    Roles.guardian: [attendanceRead, gradeRead],
  };

  static bool roleHas(String roleCode, String permission) =>
      (byRole[roleCode] ?? const []).contains(permission);
}
