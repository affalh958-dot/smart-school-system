# AGENTS.md — نظام إدارة المدرسة الذكي

## نظرة عامة
نظام إدارة مدرسي حقيقي (Flutter) لتطبيق Android وتطبيق Windows سطح مكتب حقيقي،
مع قاعدة بيانات SQLite محلية (Offline-first) جاهزة للربط بـ PostgreSQL لاحقاً.
الواجهة عربية بالكامل مع دعم RTL وخط NotoNaskhArabic.

## أهم الميزة
الحضور التلقائي بالتعرّف على الوجه، محلياً على الجهاز (بلا APIs مدفوعة، بلا شبكة):
- كشف الوجه: `google_mlkit_face_detection`.
- استخراج السمات: MobileFaceNet TFLite (128 بُعداً، مدخل 112×112)، تطبيع L2، مطابقة جيبية.
- كشف الحيوية: `liveness_antispoof.tflite` (اختياري).
- فهرس في الذاكرة (`FaceIndex`) للبحث الفوري — مصمّم لـ 5000 طالب دون بحث خطي على القرص.

## البناء والاختبار
من مجلد `app/`:
```bash
export PATH=$PATH:/home/openhands/tools/flutter/bin
flutter analyze                 # يجب أن يكون نظيفاً
flutter test                    # كل الاختبارات ناجحة (core_test.dart + export_test.dart)
flutter build apk --debug       # ينتج build/app/outputs/flutter-apk/app-debug.apk
# ملاحظة: flutter build windows يعمل على مضيف Windows فقط.
```

## بناء برنامج ويندوز (حقيقي)
- **لا يمكن بناء exe ويندوز على لينكس** (Flutter يتطلب MSVC + Windows). الحل المعتمد: GitHub Actions على `windows-latest`.
- المستودع الخاص: `affalh958-dot/smart-school-system`. الـworkflow: `.github/workflows/build-windows-desktop.yml`.
- بناء محلي على أي جهاز ويندوز: `scripts/build_windows.bat` (Flutter + VS2022 C++ workload) → `app/build/windows/x64/runner/Release/school_app.exe`.
- آخر نسخة منشورة (release): وسم `v1.0.1-win`:
  - **المثبّت (الأفضل):** `SmartSchool-Setup.exe` → تشغيل ثم نعم، وينشئ اختصاراً على سطح المكتب.
  - **المحمولة:** `SmartSchool-Windows-portable.zip` (فك الضغط → تشغيل `school_app.exe` مباشرةً مع بقاء مجلد `data` وملفات `dll` بجانبه؛ بلا تثبيت).
  - سبب تعذّر فتح البرنامج سابقاً بالنقر: غياب مكتبات Microsoft Visual C++؛ صارت الآن **مُحزَّمة داخل المجلد** (vcruntime140/msvcp140...) فيعمل على أي جهاز.
  - تحقّق من سلامة الملفات (SHA-256): `SmartSchool-Setup.exe` = `a7457c5f...c48eeb8`، `SmartSchool-Windows-portable.zip` = `8e28e76b...4892c1f`.
- شاشة تسجيل الوجه والكاميرا معطّلة على سطح المكتب برسالة واضحة (التعرّف يتم على الأندرويد عند المدخل).

## المعمارية
- `lib/core/` — الحالة (`app_state`)، الصلاحيات (`permissions`)، الأمان (`security`)، الثيم.
- `lib/data/` — النماذج (`models`) والمستودعات (students, attendance, biometric, academic, grades, reports, audit, student_columns) + `database.dart` (SQLite + ترحيلات) + `export/xlsx_writer.dart`.
- `lib/face/` — `face_engine` (TFLite) و`face_index` (مطابقة في الذاكرة).
- `lib/ui/screens/` — الشاشات حسب الدور.
- `assets/db/schema.sql` — المخطط الكامل (يُنسخ إلى `db/sqlite/schema.sql`، يجب إبقاؤهما متطابقين).

## إضافات حديثة
- **بوابة الطالب** (`student_home_screen.dart`): تقرأ فقط ملف الطالب المرتبط بـ`users.student_id` وتقييماته التراكمية؛ لا تعديل ولا رؤية لبيانات طالب آخر.
- **التقييم الأسبوعي التراكمي** (`evaluation_repository.dart` + `evaluations_screen.dart` + `weekly_evaluations`): upsert على (طالب+مادة+أسبوع)، تحقق من النطاق، ومعدّل مرجّح.
- **ترحيل نهاية السنة** (`promotion_screen.dart`): الناجح لشعبة جديدة والراسب يبقى، مع توثيق كل حركة في `student_movements`.
- **واتساب** (`whatsapp_helper.dart`): تطبيع أرقام عراقية للصيغة الدولية + رسالة تقييم جاهزة (deep link، بلا خدمات مدفوعة).
- **هوامش صحية/ملاحظات** (`class_roster_screen.dart`): فلتر «الطلاب ذوو الحالات الخاصة» + شارات الحالة الصحية والملاحظات.
- **تسليم حساب المدير** (`school_detail_screen.dart`): المالك ينشئ مدير المدرسة عبر `AuthRepository.createUser` ويعرض بيانات الدخول مرة واحدة.
- **ترحيل المخطط**: عند إضافة أعمدة جديدة (`users.student_id`, `students.health_status`, `students.user_id`) تُضاف في `_addColumnIfMissing` مع رفع إصدار القاعدة.
- كل الشاشات الجديدة مربوطة بلوحة التحكم (`dashboard_screen.dart`) حسب الصلاحية (`evaluationWrite`, `studentWrite`).

## قرارات مهمة
- قاعدة البيانات SQLite للإصدار 3. عند إضافة جداول/أعمدة: **حدّث كلاً من** `app/assets/db/schema.sql` و`db/sqlite/schema.sql`، وأضف ترحيلاً في `_create` (onUpgrade) مع رفع `version`. **تأكد أن الملفين متطابقان** (`diff app/assets/db/schema.sql db/sqlite/schema.sql`) — فالتطبيق يقرأ `assets/db/schema.sql` بينما الاختبار القديم قد يقرأ الآخر.
- عزل المدارس (Multi-tenant): كل جدول يحمل `school_id`، والاستعلامات مقيّدة به.
- منع التكرار على مستوى القاعدة (قيود UNIQUE) + مهلة لكل طالب.
- الأعمال الحساسة تُسجَّل في `audit_log` و`attendance_audit`.
- بعد أي تعديل واجهات شغّل `flutter analyze` قبل الالتزام.
