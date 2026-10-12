-- ============================================================================
--  نظام إدارة المدرسة الذكي — مخطط قاعدة البيانات الكامل (SQLite)
--  الإصدار: 1.0
--  الاستخدام: قاعدة محلية على الجهاز (Offline-first). لاحقاً تُزامَن مع الخادم.
--  المنطقة الزمنية المرجعية: Asia/Baghdad — تُخزَّن الأوقات بصيغة UTC ISO-8601.
--  ملاحظات:
--   * كل الجداول فيها created_at / updated_at / deleted_at (حذف منطقي).
--   * منع التكرار على مستوى القاعدة عبر قيود UNIQUE.
--   * الأوقات تُسجَّل من الخادم عند توفّره، وإلا من الجهاز (time_source).
-- ============================================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

-- ---------------------------------------------------------------------------
-- 1) الهيكل المدرسي
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schools (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  timezone      TEXT NOT NULL DEFAULT 'Asia/Baghdad',
  logo_path     TEXT,
  is_active     INTEGER NOT NULL DEFAULT 1,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  deleted_at    TEXT
);

CREATE TABLE IF NOT EXISTS academic_years (
  id            TEXT PRIMARY KEY,
  school_id     TEXT NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  name          TEXT NOT NULL,
  start_date    TEXT NOT NULL,
  end_date      TEXT NOT NULL,
  is_current    INTEGER NOT NULL DEFAULT 0,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  deleted_at    TEXT,
  UNIQUE (school_id, name)
);

CREATE TABLE IF NOT EXISTS semesters (
  id               TEXT PRIMARY KEY,
  academic_year_id TEXT NOT NULL REFERENCES academic_years(id) ON DELETE RESTRICT,
  name             TEXT NOT NULL,
  start_date       TEXT NOT NULL,
  end_date         TEXT NOT NULL,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL,
  deleted_at       TEXT,
  UNIQUE (academic_year_id, name)
);

CREATE TABLE IF NOT EXISTS stages (
  id          TEXT PRIMARY KEY,
  school_id   TEXT NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  name        TEXT NOT NULL,
  order_index INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  deleted_at  TEXT,
  UNIQUE (school_id, name)
);

CREATE TABLE IF NOT EXISTS grades (
  id          TEXT PRIMARY KEY,
  stage_id    TEXT NOT NULL REFERENCES stages(id) ON DELETE RESTRICT,
  name        TEXT NOT NULL,
  order_index INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  deleted_at  TEXT,
  UNIQUE (stage_id, name)
);

CREATE TABLE IF NOT EXISTS sections (
  id               TEXT PRIMARY KEY,
  grade_id         TEXT NOT NULL REFERENCES grades(id) ON DELETE RESTRICT,
  academic_year_id TEXT NOT NULL REFERENCES academic_years(id) ON DELETE RESTRICT,
  name             TEXT NOT NULL,
  capacity         INTEGER,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL,
  deleted_at       TEXT,
  UNIQUE (grade_id, academic_year_id, name)
);

-- ---------------------------------------------------------------------------
-- 2) الأشخاص
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS students (
  id               TEXT PRIMARY KEY,
  school_id        TEXT NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  student_number   TEXT NOT NULL,
  full_name        TEXT NOT NULL,
  gender           TEXT,
  birth_date       TEXT,
  photo_path       TEXT,
  section_id       TEXT REFERENCES sections(id) ON DELETE RESTRICT,
  academic_year_id TEXT REFERENCES academic_years(id) ON DELETE RESTRICT,
  enrollment_date  TEXT,
  status           TEXT NOT NULL DEFAULT 'active',
  address          TEXT,
  notes            TEXT,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL,
  deleted_at       TEXT,
  UNIQUE (school_id, student_number)
);
CREATE INDEX IF NOT EXISTS idx_students_name    ON students(full_name);
CREATE INDEX IF NOT EXISTS idx_students_section ON students(section_id);

-- ملاحظة العزل: كل جدول مرتبط بمدرسة يحمل school_id، وكل استعلام يُقيَّد به.
-- في PostgreSQL يُفرض ذلك إضافياً بسياسات RLS (انظر db/postgres/schema.sql).
CREATE TABLE IF NOT EXISTS guardians (
  id         TEXT PRIMARY KEY,
  school_id  TEXT NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  full_name  TEXT NOT NULL,
  relation   TEXT,
  phone      TEXT,
  alt_phone  TEXT,
  address    TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_guardians_school ON guardians(school_id);

CREATE TABLE IF NOT EXISTS student_guardians (
  student_id  TEXT NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  guardian_id TEXT NOT NULL REFERENCES guardians(id) ON DELETE CASCADE,
  is_primary  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (student_id, guardian_id)
);

CREATE TABLE IF NOT EXISTS teachers (
  id          TEXT PRIMARY KEY,
  school_id   TEXT NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  employee_no TEXT NOT NULL,
  full_name   TEXT NOT NULL,
  phone       TEXT,
  email       TEXT,
  hire_date   TEXT,
  is_active   INTEGER NOT NULL DEFAULT 1,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  deleted_at  TEXT,
  UNIQUE (school_id, employee_no)
);

CREATE TABLE IF NOT EXISTS subjects (
  id         TEXT PRIMARY KEY,
  school_id  TEXT NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  name       TEXT NOT NULL,
  code       TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  UNIQUE (school_id, name)
);

CREATE TABLE IF NOT EXISTS teacher_assignments (
  id               TEXT PRIMARY KEY,
  teacher_id       TEXT NOT NULL REFERENCES teachers(id) ON DELETE CASCADE,
  subject_id       TEXT NOT NULL REFERENCES subjects(id) ON DELETE CASCADE,
  section_id       TEXT NOT NULL REFERENCES sections(id) ON DELETE CASCADE,
  academic_year_id TEXT NOT NULL REFERENCES academic_years(id) ON DELETE RESTRICT,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL,
  deleted_at       TEXT,
  UNIQUE (teacher_id, subject_id, section_id, academic_year_id)
);

CREATE TABLE IF NOT EXISTS student_movements (
  id               TEXT PRIMARY KEY,
  student_id       TEXT NOT NULL REFERENCES students(id) ON DELETE RESTRICT,
  from_section     TEXT REFERENCES sections(id),
  to_section       TEXT REFERENCES sections(id),
  academic_year_id TEXT REFERENCES academic_years(id),
  moved_at         TEXT NOT NULL,
  moved_by         TEXT,
  reason           TEXT,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL,
  deleted_at       TEXT
);

-- ---------------------------------------------------------------------------
-- 3) المستخدمون والصلاحيات
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
  id            TEXT PRIMARY KEY,
  school_id     TEXT REFERENCES schools(id),
  username      TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  password_salt TEXT,
  full_name     TEXT NOT NULL,
  is_active     INTEGER NOT NULL DEFAULT 1,
  teacher_id    TEXT REFERENCES teachers(id),
  last_login_at TEXT,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  deleted_at    TEXT
);

CREATE TABLE IF NOT EXISTS roles (
  id         TEXT PRIMARY KEY,
  code       TEXT NOT NULL UNIQUE,
  name_ar    TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS permissions (
  id         TEXT PRIMARY KEY,
  code       TEXT NOT NULL UNIQUE,
  name_ar    TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS role_permissions (
  role_id       TEXT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  permission_id TEXT NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE IF NOT EXISTS user_roles (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id TEXT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, role_id)
);

CREATE TABLE IF NOT EXISTS sessions (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL,
  device_id  TEXT REFERENCES devices(id),
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- ---------------------------------------------------------------------------
-- 4) الأجهزة
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS devices (
  id                 TEXT PRIMARY KEY,
  school_id          TEXT REFERENCES schools(id),
  name               TEXT NOT NULL,
  platform           TEXT NOT NULL,
  device_fingerprint TEXT,
  is_trusted         INTEGER NOT NULL DEFAULT 0,
  is_revoked         INTEGER NOT NULL DEFAULT 0,
  last_seen_at       TEXT,
  created_at         TEXT NOT NULL,
  updated_at         TEXT NOT NULL,
  deleted_at         TEXT
);

-- ---------------------------------------------------------------------------
-- 5) إعدادات الدوام والحضور
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS attendance_settings (
  id                   TEXT PRIMARY KEY,
  school_id            TEXT NOT NULL REFERENCES schools(id),
  scope                TEXT NOT NULL DEFAULT 'school',
  scope_id             TEXT,
  day_start            TEXT,
  day_end              TEXT,
  checkin_window_start TEXT,
  checkin_window_end   TEXT,
  late_after           TEXT,
  auto_close_time      TEXT,
  checkout_rules       TEXT,
  working_days         TEXT,
  extra_rules          TEXT,
  created_at           TEXT NOT NULL,
  updated_at           TEXT NOT NULL,
  deleted_at           TEXT,
  UNIQUE (school_id, scope, scope_id)
);

CREATE TABLE IF NOT EXISTS holidays (
  id         TEXT PRIMARY KEY,
  school_id  TEXT NOT NULL REFERENCES schools(id),
  date_from  TEXT NOT NULL,
  date_to    TEXT NOT NULL,
  type       TEXT NOT NULL DEFAULT 'official',
  title      TEXT,
  applies_to TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE IF NOT EXISTS attendance_sessions (
  id           TEXT PRIMARY KEY,
  school_id    TEXT NOT NULL REFERENCES schools(id),
  session_date TEXT NOT NULL,
  session_type TEXT NOT NULL DEFAULT 'morning',
  opened_at    TEXT NOT NULL,
  closed_at    TEXT,
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL,
  UNIQUE (school_id, session_date, session_type)
);

CREATE TABLE IF NOT EXISTS attendance_records (
  id           TEXT PRIMARY KEY,
  student_id   TEXT NOT NULL REFERENCES students(id) ON DELETE RESTRICT,
  session_date TEXT NOT NULL,
  session_type TEXT NOT NULL DEFAULT 'morning',
  status       TEXT NOT NULL,
  recorded_at  TEXT NOT NULL,
  time_source  TEXT NOT NULL DEFAULT 'device',
  source       TEXT NOT NULL DEFAULT 'face',
  device_id    TEXT REFERENCES devices(id),
  client_uuid  TEXT NOT NULL,
  confidence   REAL,
  note         TEXT,
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL,
  deleted_at   TEXT,
  UNIQUE (student_id, session_date, session_type),
  UNIQUE (client_uuid)
);
CREATE INDEX IF NOT EXISTS idx_att_date    ON attendance_records(session_date, status);
CREATE INDEX IF NOT EXISTS idx_att_student ON attendance_records(student_id, session_date);

CREATE TABLE IF NOT EXISTS attendance_audit (
  id                   TEXT PRIMARY KEY,
  attendance_record_id TEXT NOT NULL REFERENCES attendance_records(id) ON DELETE CASCADE,
  old_status           TEXT,
  new_status           TEXT,
  changed_by           TEXT REFERENCES users(id),
  changed_at           TEXT NOT NULL,
  reason               TEXT NOT NULL,
  created_at           TEXT NOT NULL
);

-- ---------------------------------------------------------------------------
-- 6) التعرّف على الوجه — سمات مشفّرة فقط، لا صور أصلية
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS biometric_templates (
  id                 TEXT PRIMARY KEY,
  student_id         TEXT NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  template_encrypted BLOB NOT NULL,
  embedding_dim      INTEGER NOT NULL DEFAULT 128,
  template_version   TEXT NOT NULL DEFAULT 'mobilefacenet-v1',
  quality_score      REAL,
  is_active          INTEGER NOT NULL DEFAULT 1,
  enrolled_by        TEXT REFERENCES users(id),
  enrolled_at        TEXT NOT NULL,
  revoked_at         TEXT,
  created_at         TEXT NOT NULL,
  updated_at         TEXT NOT NULL,
  deleted_at         TEXT
);
CREATE INDEX IF NOT EXISTS idx_bio_student ON biometric_templates(student_id);

CREATE TABLE IF NOT EXISTS recognition_attempts (
  id                 TEXT PRIMARY KEY,
  school_id          TEXT REFERENCES schools(id),
  device_id          TEXT REFERENCES devices(id),
  attempted_at       TEXT NOT NULL,
  result             TEXT NOT NULL,
  matched_student_id TEXT REFERENCES students(id),
  confidence         REAL,
  quality_score      REAL,
  created_at         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_attempts_dev    ON recognition_attempts(device_id, attempted_at);
CREATE INDEX IF NOT EXISTS idx_attempts_school ON recognition_attempts(school_id, attempted_at);

CREATE TABLE IF NOT EXISTS recognition_reviews (
  id              TEXT PRIMARY KEY,
  school_id       TEXT REFERENCES schools(id),
  attempt_id      TEXT REFERENCES recognition_attempts(id) ON DELETE CASCADE,
  student_id      TEXT REFERENCES students(id),
  status          TEXT NOT NULL DEFAULT 'pending',
  resolved_by     TEXT REFERENCES users(id),
  resolved_at     TEXT,
  resolution_note TEXT,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_reviews_school ON recognition_reviews(school_id, status);

-- ---------------------------------------------------------------------------
-- 7) الدرجات والامتحانات
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS exams (
  id               TEXT PRIMARY KEY,
  subject_id       TEXT NOT NULL REFERENCES subjects(id) ON DELETE RESTRICT,
  section_id       TEXT NOT NULL REFERENCES sections(id) ON DELETE RESTRICT,
  academic_year_id TEXT NOT NULL REFERENCES academic_years(id) ON DELETE RESTRICT,
  semester_id      TEXT REFERENCES semesters(id),
  exam_type        TEXT NOT NULL,
  exam_date        TEXT,
  max_score        REAL NOT NULL DEFAULT 100,
  pass_score       REAL,
  weight           REAL NOT NULL DEFAULT 1,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL,
  deleted_at       TEXT
);

CREATE TABLE IF NOT EXISTS exam_grades (
  id         TEXT PRIMARY KEY,
  exam_id    TEXT NOT NULL REFERENCES exams(id) ON DELETE CASCADE,
  student_id TEXT NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  score      REAL,
  entered_by TEXT REFERENCES users(id),
  entered_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  UNIQUE (exam_id, student_id)
);

CREATE TABLE IF NOT EXISTS grade_audit (
  id         TEXT PRIMARY KEY,
  grade_id   TEXT NOT NULL REFERENCES exam_grades(id) ON DELETE CASCADE,
  old_score  REAL,
  new_score  REAL,
  changed_by TEXT REFERENCES users(id),
  changed_at TEXT NOT NULL,
  reason     TEXT,
  created_at TEXT NOT NULL
);

-- ---------------------------------------------------------------------------
-- 8) المزامنة، التدقيق، الإعدادات، النسخ الاحتياطي
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sync_queue (
  id          TEXT PRIMARY KEY,
  client_uuid TEXT NOT NULL UNIQUE,
  entity_type TEXT NOT NULL,
  entity_id   TEXT NOT NULL,
  operation   TEXT NOT NULL,
  payload     TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'pending',
  retry_count INTEGER NOT NULL DEFAULT 0,
  last_error  TEXT,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sync_status ON sync_queue(status);

CREATE TABLE IF NOT EXISTS audit_log (
  id          TEXT PRIMARY KEY,
  user_id     TEXT REFERENCES users(id),
  action      TEXT NOT NULL,
  entity_type TEXT,
  entity_id   TEXT,
  old_value   TEXT,
  new_value   TEXT,
  device_id   TEXT,
  ip_address  TEXT,
  created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_time   ON audit_log(created_at);
CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_log(entity_type, entity_id);

CREATE TABLE IF NOT EXISTS system_settings (
  id         TEXT PRIMARY KEY,
  school_id  TEXT REFERENCES schools(id),
  key        TEXT NOT NULL,
  value      TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (school_id, key)
);

CREATE TABLE IF NOT EXISTS backups (
  id         TEXT PRIMARY KEY,
  created_at TEXT NOT NULL,
  size_bytes INTEGER,
  location   TEXT,
  checksum   TEXT,
  created_by TEXT REFERENCES users(id)
);

-- ---------------------------------------------------------------------------
-- 9) بيانات أولية (Seed)
-- ---------------------------------------------------------------------------
INSERT OR IGNORE INTO roles (id, code, name_ar, created_at, updated_at) VALUES
  ('role-admin',      'admin',      'مسؤول النظام', datetime('now'), datetime('now')),
  ('role-manager',    'manager',    'مدير المدرسة', datetime('now'), datetime('now')),
  ('role-attendance', 'attendance', 'موظف الحضور',  datetime('now'), datetime('now')),
  ('role-teacher',    'teacher',    'معلم',         datetime('now'), datetime('now')),
  ('role-guardian',   'guardian',   'ولي أمر',      datetime('now'), datetime('now'));

INSERT OR IGNORE INTO permissions (id, code, name_ar, created_at, updated_at) VALUES
  ('perm-dashboard-read',   'dashboard.read',    'عرض لوحة التحكم',     datetime('now'), datetime('now')),
  ('perm-student-read',     'student.read',      'عرض الطلاب',          datetime('now'), datetime('now')),
  ('perm-student-write',    'student.write',     'إضافة/تعديل الطلاب',  datetime('now'), datetime('now')),
  ('perm-student-delete',   'student.delete',    'حذف/أرشفة الطلاب',    datetime('now'), datetime('now')),
  ('perm-attendance-read',  'attendance.read',   'عرض الحضور',          datetime('now'), datetime('now')),
  ('perm-attendance-write', 'attendance.write',  'تسجيل/تعديل الحضور',  datetime('now'), datetime('now')),
  ('perm-attendance-screen','attendance.screen', 'تشغيل شاشة الحضور',   datetime('now'), datetime('now')),
  ('perm-grade-read',       'grade.read',        'عرض الدرجات',         datetime('now'), datetime('now')),
  ('perm-grade-write',      'grade.write',       'إدخال/تعديل الدرجات', datetime('now'), datetime('now')),
  ('perm-report-read',      'report.read',       'عرض/تصدير التقارير',  datetime('now'), datetime('now')),
  ('perm-user-manage',      'user.manage',       'إدارة المستخدمين',    datetime('now'), datetime('now')),
  ('perm-settings-manage',  'settings.manage',   'إدارة الإعدادات',     datetime('now'), datetime('now')),
  ('perm-biometric-manage', 'biometric.manage',  'إدارة تسجيل الوجوه',  datetime('now'), datetime('now')),
  ('perm-device-manage',    'device.manage',     'إدارة الأجهزة',       datetime('now'), datetime('now')),
  ('perm-backup-manage',    'backup.manage',     'النسخ الاحتياطي',     datetime('now'), datetime('now')),
  ('perm-audit-read',       'audit.read',        'عرض سجل العمليات',    datetime('now'), datetime('now'));
