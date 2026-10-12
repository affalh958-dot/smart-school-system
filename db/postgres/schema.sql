-- ============================================================================
--  نظام إدارة المدرسة الذكي — مخطط قاعدة البيانات المركزي (PostgreSQL 15+)
--  الإصدار: 1.0
--  الميزة الأساسية: عزل كامل بين المدارس (Multi-tenant) عبر Row Level Security.
--  المنطقة الزمنية: تُخزَّن الأوقات timestamptz (UTC) وتُعرض Asia/Baghdad.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "pg_trgm";    -- بحث سريع بالاسم

-- ---------------------------------------------------------------------------
-- 0) دالة تحديث updated_at تلقائياً
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- 1) المدارس + الهيكل المدرسي
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schools (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  timezone    text NOT NULL DEFAULT 'Asia/Baghdad',
  logo_path   text,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz
);

CREATE TABLE IF NOT EXISTS academic_years (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id   uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  name        text NOT NULL,
  start_date  date NOT NULL,
  end_date    date NOT NULL,
  is_current  boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  UNIQUE (school_id, name)
);

CREATE TABLE IF NOT EXISTS semesters (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id        uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  academic_year_id uuid NOT NULL REFERENCES academic_years(id) ON DELETE RESTRICT,
  name             text NOT NULL,
  start_date       date NOT NULL,
  end_date         date NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  UNIQUE (academic_year_id, name)
);

CREATE TABLE IF NOT EXISTS stages (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id   uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  name        text NOT NULL,
  order_index int NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  UNIQUE (school_id, name)
);

CREATE TABLE IF NOT EXISTS grades (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id   uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  stage_id    uuid NOT NULL REFERENCES stages(id) ON DELETE RESTRICT,
  name        text NOT NULL,
  order_index int NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  UNIQUE (stage_id, name)
);

CREATE TABLE IF NOT EXISTS sections (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id        uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  grade_id         uuid NOT NULL REFERENCES grades(id) ON DELETE RESTRICT,
  academic_year_id uuid NOT NULL REFERENCES academic_years(id) ON DELETE RESTRICT,
  name             text NOT NULL,
  capacity         int,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  UNIQUE (grade_id, academic_year_id, name)
);

-- ---------------------------------------------------------------------------
-- 2) الأشخاص
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS students (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id        uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  student_number   text NOT NULL,
  full_name        text NOT NULL,
  gender           text,
  birth_date       date,
  photo_path       text,
  section_id       uuid REFERENCES sections(id) ON DELETE RESTRICT,
  academic_year_id uuid REFERENCES academic_years(id) ON DELETE RESTRICT,
  enrollment_date  date,
  status           text NOT NULL DEFAULT 'active'
                     CHECK (status IN ('active','transferred','graduated','withdrawn')),
  address          text,
  notes            text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  UNIQUE (school_id, student_number)
);
CREATE INDEX IF NOT EXISTS idx_students_name    ON students USING gin (full_name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_students_school  ON students(school_id);

CREATE TABLE IF NOT EXISTS guardians (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id  uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  full_name  text NOT NULL,
  relation   text,
  phone      text,
  alt_phone  text,
  address    text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

CREATE TABLE IF NOT EXISTS student_guardians (
  school_id   uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  student_id  uuid NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  guardian_id uuid NOT NULL REFERENCES guardians(id) ON DELETE CASCADE,
  is_primary  boolean NOT NULL DEFAULT false,
  PRIMARY KEY (student_id, guardian_id)
);

CREATE TABLE IF NOT EXISTS teachers (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id   uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  employee_no text NOT NULL,
  full_name   text NOT NULL,
  phone       text,
  email       text,
  hire_date   date,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  UNIQUE (school_id, employee_no)
);

CREATE TABLE IF NOT EXISTS subjects (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id  uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  name       text NOT NULL,
  code       text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  UNIQUE (school_id, name)
);

CREATE TABLE IF NOT EXISTS teacher_assignments (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id        uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  teacher_id       uuid NOT NULL REFERENCES teachers(id) ON DELETE CASCADE,
  subject_id       uuid NOT NULL REFERENCES subjects(id) ON DELETE CASCADE,
  section_id       uuid NOT NULL REFERENCES sections(id) ON DELETE CASCADE,
  academic_year_id uuid NOT NULL REFERENCES academic_years(id) ON DELETE RESTRICT,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  UNIQUE (teacher_id, subject_id, section_id, academic_year_id)
);

CREATE TABLE IF NOT EXISTS student_movements (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id        uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  student_id       uuid NOT NULL REFERENCES students(id) ON DELETE RESTRICT,
  from_section     uuid REFERENCES sections(id),
  to_section       uuid REFERENCES sections(id),
  academic_year_id uuid REFERENCES academic_years(id),
  moved_at         timestamptz NOT NULL DEFAULT now(),
  moved_by         uuid,
  reason           text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz
);

-- ---------------------------------------------------------------------------
-- 3) المستخدمون والصلاحيات
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id     uuid REFERENCES schools(id),
  username      text NOT NULL UNIQUE,
  password_hash text NOT NULL,
  full_name     text NOT NULL,
  is_active     boolean NOT NULL DEFAULT true,
  teacher_id    uuid REFERENCES teachers(id),
  last_login_at timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz
);

CREATE TABLE IF NOT EXISTS roles (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code       text NOT NULL UNIQUE,
  name_ar    text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS permissions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code       text NOT NULL UNIQUE,
  name_ar    text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS role_permissions (
  role_id       uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  permission_id uuid NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE IF NOT EXISTS user_roles (
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, role_id)
);

CREATE TABLE IF NOT EXISTS sessions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash text NOT NULL,
  device_id  uuid REFERENCES devices(id),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 4) الأجهزة
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS devices (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id          uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  name               text NOT NULL,
  platform           text NOT NULL CHECK (platform IN ('android','windows','web')),
  device_fingerprint text,
  is_trusted         boolean NOT NULL DEFAULT false,
  is_revoked         boolean NOT NULL DEFAULT false,
  last_seen_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  deleted_at         timestamptz
);

-- ---------------------------------------------------------------------------
-- 5) الدوام والحضور
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS attendance_settings (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id            uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  scope                text NOT NULL DEFAULT 'school' CHECK (scope IN ('school','stage','grade')),
  scope_id             uuid,
  day_start            time,
  day_end              time,
  checkin_window_start time,
  checkin_window_end   time,
  late_after           time,
  auto_close_time      time,
  checkout_rules       jsonb,
  working_days         jsonb,
  extra_rules          jsonb,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  UNIQUE (school_id, scope, scope_id)
);

CREATE TABLE IF NOT EXISTS holidays (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id  uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  date_from  date NOT NULL,
  date_to    date NOT NULL,
  type       text NOT NULL DEFAULT 'official' CHECK (type IN ('official','leave','exception')),
  title      text,
  applies_to jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

CREATE TABLE IF NOT EXISTS attendance_sessions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id    uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  session_date date NOT NULL,
  session_type text NOT NULL DEFAULT 'morning' CHECK (session_type IN ('morning','checkout','period')),
  opened_at    timestamptz NOT NULL DEFAULT now(),
  closed_at    timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (school_id, session_date, session_type)
);

CREATE TABLE IF NOT EXISTS attendance_records (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id    uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  student_id   uuid NOT NULL REFERENCES students(id) ON DELETE RESTRICT,
  session_date date NOT NULL,
  session_type text NOT NULL DEFAULT 'morning' CHECK (session_type IN ('morning','checkout')),
  status       text NOT NULL
                 CHECK (status IN ('present','late','absent','excused','early_leave')),
  recorded_at  timestamptz NOT NULL DEFAULT now(),
  time_source  text NOT NULL DEFAULT 'server' CHECK (time_source IN ('server','device')),
  source       text NOT NULL DEFAULT 'face' CHECK (source IN ('face','manual','api')),
  device_id    uuid REFERENCES devices(id),
  client_uuid  uuid NOT NULL,
  confidence   numeric,
  note         text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  deleted_at   timestamptz,
  UNIQUE (student_id, session_date, session_type),   -- منع التكرار
  UNIQUE (client_uuid)                               -- Idempotency
);
CREATE INDEX IF NOT EXISTS idx_att_date    ON attendance_records(school_id, session_date, status);
CREATE INDEX IF NOT EXISTS idx_att_student ON attendance_records(student_id, session_date);

CREATE TABLE IF NOT EXISTS attendance_audit (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id            uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  attendance_record_id uuid NOT NULL REFERENCES attendance_records(id) ON DELETE CASCADE,
  old_status           text,
  new_status           text,
  changed_by           uuid REFERENCES users(id),
  changed_at           timestamptz NOT NULL DEFAULT now(),
  reason               text NOT NULL,
  created_at           timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 6) التعرّف على الوجه (سمات مشفّرة فقط)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS biometric_templates (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id          uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  student_id         uuid NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  template_encrypted bytea NOT NULL,
  embedding_dim      int NOT NULL DEFAULT 128,
  template_version   text NOT NULL DEFAULT 'mobilefacenet-v1',
  quality_score      numeric,
  is_active          boolean NOT NULL DEFAULT true,
  enrolled_by        uuid REFERENCES users(id),
  enrolled_at        timestamptz NOT NULL DEFAULT now(),
  revoked_at         timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  deleted_at         timestamptz
);
CREATE INDEX IF NOT EXISTS idx_bio_student ON biometric_templates(student_id);

CREATE TABLE IF NOT EXISTS recognition_attempts (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id          uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  device_id          uuid REFERENCES devices(id),
  attempted_at       timestamptz NOT NULL DEFAULT now(),
  result             text NOT NULL
                       CHECK (result IN ('matched','no_match','ambiguous','low_quality','spoof')),
  matched_student_id uuid REFERENCES students(id),
  confidence         numeric,
  quality_score      numeric,
  created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_attempts_dev ON recognition_attempts(school_id, device_id, attempted_at);

CREATE TABLE IF NOT EXISTS recognition_reviews (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id       uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  attempt_id      uuid REFERENCES recognition_attempts(id) ON DELETE CASCADE,
  student_id      uuid REFERENCES students(id),
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','resolved','rejected')),
  resolved_by     uuid REFERENCES users(id),
  resolved_at     timestamptz,
  resolution_note text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 7) الدرجات
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS exams (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id        uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  subject_id       uuid NOT NULL REFERENCES subjects(id) ON DELETE RESTRICT,
  section_id       uuid NOT NULL REFERENCES sections(id) ON DELETE RESTRICT,
  academic_year_id uuid NOT NULL REFERENCES academic_years(id) ON DELETE RESTRICT,
  semester_id      uuid REFERENCES semesters(id),
  exam_type        text NOT NULL,
  exam_date        date,
  max_score        numeric NOT NULL DEFAULT 100,
  pass_score       numeric,
  weight           numeric NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz
);

CREATE TABLE IF NOT EXISTS exam_grades (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id  uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  exam_id    uuid NOT NULL REFERENCES exams(id) ON DELETE CASCADE,
  student_id uuid NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  score      numeric CHECK (score IS NULL OR score >= 0),
  entered_by uuid REFERENCES users(id),
  entered_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  UNIQUE (exam_id, student_id)
);

CREATE TABLE IF NOT EXISTS grade_audit (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id  uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  grade_id   uuid NOT NULL REFERENCES exam_grades(id) ON DELETE CASCADE,
  old_score  numeric,
  new_score  numeric,
  changed_by uuid REFERENCES users(id),
  changed_at timestamptz NOT NULL DEFAULT now(),
  reason     text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 8) المزامنة والتدقيق والإعدادات والنسخ الاحتياطي
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sync_meta (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id   uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  device_id   uuid REFERENCES devices(id),
  client_uuid uuid NOT NULL,
  entity_type text NOT NULL,
  status      text NOT NULL DEFAULT 'accepted'
                CHECK (status IN ('accepted','duplicate','rejected','conflict')),
  payload_hash text,
  received_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sync_meta_uuid ON sync_meta(client_uuid);

CREATE TABLE IF NOT EXISTS audit_log (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id   uuid REFERENCES schools(id),
  user_id     uuid REFERENCES users(id),
  action      text NOT NULL,
  entity_type text,
  entity_id   uuid,
  old_value   jsonb,
  new_value   jsonb,
  device_id   uuid,
  ip_address  inet,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_audit_time   ON audit_log(created_at);
CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_log(entity_type, entity_id);

CREATE TABLE IF NOT EXISTS system_settings (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id  uuid NOT NULL REFERENCES schools(id) ON DELETE RESTRICT,
  key        text NOT NULL,
  value      jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (school_id, key)
);

CREATE TABLE IF NOT EXISTS backups (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id  uuid REFERENCES schools(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  size_bytes bigint,
  location   text,
  checksum   text,
  created_by uuid REFERENCES users(id)
);

-- ============================================================================
--  9) العزل بين المدارس — Row Level Security (RLS)
--  الفكرة: كل جلسة قاعدة بيانات تحمل متغيّراً app.current_school_id.
--  لا يمكن لأي استعلام رؤية أو تعديل صفوف مدرسة أخرى، حتى لو أخطأ الكود.
-- ============================================================================
DO $$
DECLARE
  t text;
  tenant_tables text[] := ARRAY[
    'academic_years','semesters','stages','grades','sections','students','guardians',
    'student_guardians','teachers','subjects','teacher_assignments','student_movements',
    'users','devices','attendance_settings','holidays','attendance_sessions',
    'attendance_records','attendance_audit','biometric_templates','recognition_attempts',
    'recognition_reviews','exams','exam_grades','grade_audit','sync_meta',
    'audit_log','system_settings'
  ];
BEGIN
  FOREACH t IN ARRAY tenant_tables LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY;', t);
    -- سياسة موحّدة: الصف مرئي فقط إذا كان school_id مطابقاً لمدرسة الجلسة.
    EXECUTE format($f$
      DROP POLICY IF EXISTS tenant_isolation ON %I;
      CREATE POLICY tenant_isolation ON %I
        USING (school_id = current_setting('app.current_school_id', true)::uuid)
        WITH CHECK (school_id = current_setting('app.current_school_id', true)::uuid);
    $f$, t, t);
  END LOOP;
END $$;

-- جدول المدارس نفسه: يُدار من دور أعلى فقط (superuser/app_owner).
ALTER TABLE schools ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS schools_visible ON schools;
CREATE POLICY schools_visible ON schools
  USING (id = current_setting('app.current_school_id', true)::uuid);

-- ملاحظة تشغيلية:
--   SET app.current_school_id = '<uuid-of-school>';   -- يُنفَّذ لكل جلسة/معاملة
--   وبذلك تُعزل بيانات كل مدرسة تماماً عن غيرها.
