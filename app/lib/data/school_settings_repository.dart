import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'database.dart';

/// عطلة رسمية أو استثناء بتاريخ/فترة.
class Holiday {
  final String id;
  final String dateFrom;
  final String dateTo;
  final String type; // official|exception
  final String? title;
  final String? appliesTo;

  Holiday({
    required this.id,
    required this.dateFrom,
    required this.dateTo,
    this.type = 'official',
    this.title,
    this.appliesTo,
  });

  factory Holiday.fromMap(Map<String, dynamic> m) => Holiday(
        id: m['id'] as String,
        dateFrom: m['date_from'] as String,
        dateTo: m['date_to'] as String,
        type: (m['type'] as String?) ?? 'official',
        title: m['title'] as String?,
        appliesTo: m['applies_to'] as String?,
      );
}

/// استراحة داخل اليوم (تخزين داخل extra_rules).
class BreakSlot {
  final String label;
  final String start;
  final String end;
  BreakSlot({required this.label, required this.start, required this.end});
  Map<String, dynamic> toJson() => {'label': label, 'start': start, 'end': end};
  factory BreakSlot.fromJson(Map<String, dynamic> m) => BreakSlot(
        label: (m['label'] ?? 'استراحة') as String,
        start: (m['start'] ?? '') as String,
        end: (m['end'] ?? '') as String,
      );
}

/// إعدادات دوام المدرسة: الأوقات، أيام الدوام، الاستراحات، العطل.
class SchoolSettingsRepository {
  final _uuid = const Uuid();

  Future<Map<String, dynamic>?> getSettings(String schoolId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('attendance_settings',
        where: 'school_id = ? AND scope = ?', whereArgs: [schoolId, 'school'], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// حفظ الإعدادات (إنشاء الصف إن لم يوجد).
  Future<void> saveSettings(String schoolId, Map<String, dynamic> values) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    final existing = await db.query('attendance_settings',
        columns: ['id'], where: 'school_id = ? AND scope = ?', whereArgs: [schoolId, 'school'], limit: 1);
    final data = {...values, 'updated_at': now};
    if (existing.isEmpty) {
      await db.insert('attendance_settings', {
        'id': _uuid.v4(),
        'school_id': schoolId,
        'scope': 'school',
        'created_at': now,
        ...data,
      });
    } else {
      await db.update('attendance_settings', data, where: 'id = ?', whereArgs: [existing.first['id']]);
    }
  }

  /// أيام الدوام (أرقام dart: DateTime.weekday: 1=الاثنين..7=الأحد).
  /// الافتراضي: الأحد→الخميس = [7,1,2,3,4].
  Future<Set<int>> workingDays(String schoolId) async {
    final s = await getSettings(schoolId);
    final raw = s?['working_days'] as String?;
    if (raw == null || raw.trim().isEmpty) return {7, 1, 2, 3, 4};
    try {
      final list = (jsonDecode(raw) as List).map((e) => (e as num).toInt()).toSet();
      return list.isEmpty ? {7, 1, 2, 3, 4} : list;
    } catch (_) {
      return {7, 1, 2, 3, 4};
    }
  }

  Future<void> saveWorkingDays(String schoolId, Set<int> days) =>
      saveSettings(schoolId, {'working_days': jsonEncode(days.toList()..sort())});

  Future<List<BreakSlot>> breaks(String schoolId) async {
    final s = await getSettings(schoolId);
    final raw = s?['extra_rules'] as String?;
    final slots = await _readExtra(raw, 'breaks');
    return slots.map(BreakSlot.fromJson).toList();
  }

  Future<void> saveBreaks(String schoolId, List<BreakSlot> list) async {
    final s = await getSettings(schoolId);
    final updated = await _writeExtra(s?['extra_rules'] as String?, 'breaks', list.map((e) => e.toJson()).toList());
    await saveSettings(schoolId, {'extra_rules': updated});
  }

  /// شروط قواعد الانصراف (JSON حرّ قابل للضبط دون تعديل الكود).
  Future<Map<String, dynamic>> checkoutRules(String schoolId) async {
    final s = await getSettings(schoolId);
    final raw = s?['checkout_rules'] as String?;
    if (raw == null || raw.trim().isEmpty) {
      return {'min_before_end': 0, 'early_leave_before': '12:00'};
    }
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {'min_before_end': 0, 'early_leave_before': '12:00'};
    }
  }

  Future<void> saveCheckoutRules(String schoolId, Map<String, dynamic> rules) =>
      saveSettings(schoolId, {'checkout_rules': jsonEncode(rules)});

  // ===== العطل =====
  Future<List<Holiday>> holidays(String schoolId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('holidays',
        where: 'school_id = ? AND deleted_at IS NULL',
        whereArgs: [schoolId],
        orderBy: 'date_from ASC');
    return rows.map(Holiday.fromMap).toList();
  }

  Future<String> addHoliday(String schoolId, Holiday h) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    final id = _uuid.v4();
    await db.insert('holidays', {
      'id': id,
      'school_id': schoolId,
      'date_from': h.dateFrom,
      'date_to': h.dateTo,
      'type': h.type,
      'title': h.title,
      'applies_to': h.appliesTo,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  Future<void> removeHoliday(String id) async {
    final db = await AppDatabase.instance.database;
    await db.update('holidays', {'deleted_at': DateTime.now().toUtc().toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
  }

  /// هل التاريخ عطلة (رسمية أو استثناء مطبَّق)؟
  Future<Holiday?> holidayFor(String schoolId, String date) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('holidays',
        where: 'school_id = ? AND deleted_at IS NULL AND date_from <= ? AND date_to >= ?',
        whereArgs: [schoolId, date, date],
        limit: 1);
    return rows.isEmpty ? null : Holiday.fromMap(rows.first);
  }

  /// هل هو يوم دوام فعلّي (ليس عطلة وليس يوم راحة أسبوعية)؟
  Future<bool> isWorkingDay(String schoolId, String date) async {
    final d = DateTime.parse(date);
    if (!(await workingDays(schoolId)).contains(d.weekday)) return false;
    return (await holidayFor(schoolId, date)) == null;
  }

  // ===== أدوات JSON المساعدة لـ extra_rules =====
  Future<List<Map<String, dynamic>>> _readExtra(String? raw, String key) async {
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final obj = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final l = obj[key];
      if (l is List) return l.map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (_) {}
    return [];
  }

  Future<String> _writeExtra(String? raw, String key, List<Map<String, dynamic>> value) async {
    Map<String, dynamic> obj = {};
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        obj = (jsonDecode(raw) as Map).cast<String, dynamic>();
      } catch (_) {}
    }
    obj[key] = value;
    return jsonEncode(obj);
  }

  static String dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
