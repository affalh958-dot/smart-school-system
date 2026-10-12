-- ============================================================================
--  نظام إدارة المدرسة الذكي — بذور البيانات + المالك + إنشاء مدرسة معزولة
--  الإصدار: 1.0
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) الصلاحيات الأساسية (تعريفات عامة غير مرتبطة بمدرسة)
-- ---------------------------------------------------------------------------
INSERT INTO permissions (code, name_ar) VALUES
  ('dashboard.read',    'عرض لوحة التحكم'),
  ('student.read',      'عرض الطلاب'),
  ('student.write',     'إضافة/تعديل الطلاب'),
  ('student.delete',    'حذف/أرشفة الطلاب'),
  ('attendance.read',   'عرض الحضور'),
  ('attendance.write',  'تسجيل/تعديل الحضور'),
  ('attendance.screen', 'تشغيل شاشة الحضور'),
  ('grade.read',        'عرض الدرجات'),
  ('grade.write',       'إدخال/تعديل الدرجات'),
  ('report.read',       'عرض/تصدير التقارير'),
  ('user.manage',       'إدارة المستخدمين'),
  ('settings.manage',   'إدارة الإعدادات'),
  ('biometric.manage',  'إدارة تسجيل الوجوه'),
  ('device.manage',     'إدارة الأجهزة'),
  ('backup.manage',     'النسخ الاحتياطي'),
  ('audit.read',        'عرض سجل العمليات'),
  ('tenant.manage',     'إدارة المدارس (المالك فقط)')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2) الأدوار
-- ---------------------------------------------------------------------------
INSERT INTO roles (code, name_ar) VALUES
  ('owner',      'المالك / مسؤول المنصة'),
  ('admin',      'مسؤول النظام'),
  ('manager',    'مدير المدرسة'),
  ('attendance', 'موظف الحضور'),
  ('teacher',    'معلم'),
  ('guardian',   'ولي أمر')
ON CONFLICT (code) DO NOTHING;

-- ربط الصلاحيات بالأدوار
-- المالك: كل الصلاحيات
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r CROSS JOIN permissions p WHERE r.code = 'owner'
ON CONFLICT DO NOTHING;

-- مسؤول النظام: كل شيء عدا إدارة المدارس
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r CROSS JOIN permissions p
WHERE r.code = 'admin' AND p.code <> 'tenant.manage'
ON CONFLICT DO NOTHING;

-- مدير المدرسة
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r JOIN permissions p ON p.code IN
  ('dashboard.read','student.read','student.write','attendance.read','attendance.write',
   'grade.read','report.read','audit.read','settings.manage')
WHERE r.code = 'manager'
ON CONFLICT DO NOTHING;

-- موظف الحضور
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r JOIN permissions p ON p.code IN
  ('dashboard.read','student.read','attendance.read','attendance.write','attendance.screen','report.read')
WHERE r.code = 'attendance'
ON CONFLICT DO NOTHING;

-- المعلم
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r JOIN permissions p ON p.code IN
  ('student.read','grade.read','grade.write','attendance.read')
WHERE r.code = 'teacher'
ON CONFLICT DO NOTHING;

-- ولي الأمر (مستقبلاً)
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r JOIN permissions p ON p.code IN ('attendance.read','grade.read')
WHERE r.code = 'guardian'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3) حساب المالك الثابت (Super Admin) — يدير التطبيق كاملاً
-- ---------------------------------------------------------------------------
-- ملاحظة أمنية مهمة:
--   * لا يُخزَّن أي كلمة مرور نصية. يُخزَّن هاش Argon2id فقط.
--   * يُنشأ الحساب عبر سكربت التهيئة (db/scripts/create_owner) الذي يطلب كلمة مرور
--     قوية، أو عبر متغيّر بيئة، ولا تُكتب في الكود أو في مستودع Git.
--   * يُوصى بتفعيل 2FA للمالك.
CREATE TABLE IF NOT EXISTS platform_admins (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username      text NOT NULL UNIQUE,
  password_hash text NOT NULL,          -- Argon2id
  full_name     text NOT NULL DEFAULT 'مالك النظام',
  is_active     boolean NOT NULL DEFAULT true,
  two_factor_enabled boolean NOT NULL DEFAULT false,
  last_login_at timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 4) دالة إنشاء مدرسة جديدة معزولة بالكامل
--    تُنشئ: مدرسة + إعدادات دوام افتراضية + سنة دراسية حالية + حساب مدير أول.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION provision_school(
  p_name            text,
  p_timezone        text DEFAULT 'Asia/Baghdad',
  p_admin_username  text DEFAULT NULL,
  p_admin_fullname  text DEFAULT NULL
) RETURNS uuid AS $$
DECLARE
  v_school_id uuid;
  v_year_id   uuid;
  v_admin_id  uuid;
BEGIN
  INSERT INTO schools (name, timezone) VALUES (p_name, p_timezone)
  RETURNING id INTO v_school_id;

  -- إعدادات دوام افتراضية
  INSERT INTO attendance_settings (school_id, scope, scope_id, day_start, day_end,
        checkin_window_start, checkin_window_end, late_after, auto_close_time, working_days)
  VALUES (v_school_id, 'school', NULL, '07:30', '13:30', '07:00', '07:45', '07:30', '08:00',
        '["sun","mon","tue","wed","thu"]'::jsonb);

  -- سنة دراسية حالية افتراضية
  INSERT INTO academic_years (school_id, name, start_date, end_date, is_current)
  VALUES (v_school_id, '2025/2026',
          date_trunc('year', now())::date, (date_trunc('year', now()) + interval '1 year - 1 day')::date,
          true)
  RETURNING id INTO v_year_id;

  -- حساب مدير المدرسة (اختياري: يُنشأ عبر سكربت التهيئة بكلمة مرور آمنة)
  IF p_admin_username IS NOT NULL THEN
    INSERT INTO users (school_id, username, password_hash, full_name)
    VALUES (v_school_id, p_admin_username, 'CHANGE_ME_VIA_SCRIPT', coalesce(p_admin_fullname,'مدير المدرسة'))
    RETURNING id INTO v_admin_id;

    INSERT INTO user_roles (user_id, role_id)
    SELECT v_admin_id, id FROM roles WHERE code = 'manager';
  END IF;

  RETURN v_school_id;
END; $$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- 5) إعدادات افتراضية عامة (تُنسخ لكل مدرسة عند الحاجة)
-- ---------------------------------------------------------------------------
-- مثال استخدام:
--   SELECT provision_school('مدرسة النموذج الابتدائية');
--   SET app.current_school_id = '<uuid>';   -- ثم كل الاستعلامات معزولة تلقائياً
