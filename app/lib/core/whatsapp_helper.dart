import 'package:url_launcher/url_launcher.dart';

/// أدوات إرسال رسائل واتساب الجاهزة عبر رابط wa.me (لا تحتاج API مدفوع).
class WhatsappHelper {
  /// تنظيف رقم الهاتف وتحويله للصيغة الدولية (بافتراض العراق 964 افتراضياً).
  static String normalize(String raw, {String defaultCountry = '964'}) {
    var digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return '';
    if (digits.startsWith('00')) digits = digits.substring(2);
    if (digits.startsWith(defaultCountry)) return digits;
    if (digits.startsWith('0')) digits = digits.substring(1);
    return '$defaultCountry$digits';
  }

  /// فتح واتساب برسالة جاهزة. يعيد false إذا تعذّر الفتح.
  static Future<bool> send({required String phone, required String message}) async {
    final normalized = normalize(phone);
    if (normalized.isEmpty) return false;
    final url = Uri.parse('https://wa.me/$normalized?text=${Uri.encodeComponent(message)}');
    if (await canLaunchUrl(url)) {
      return launchUrl(url, mode: LaunchMode.externalApplication);
    }
    return false;
  }

  /// يبني رسالة تقييم جاهزة لطالب من ملخّص مواده.
  static String evaluationMessage({
    required String schoolName,
    required String studentName,
    required String className,
    required List<Map<String, dynamic>> subjects,
    double? overall,
    String? note,
  }) {
    final b = StringBuffer();
    b.writeln('تحية طيبة،');
    b.writeln('تقييم الطالب/ة: $studentName');
    if (className.isNotEmpty) b.writeln('الصف: $className');
    if (schoolName.isNotEmpty) b.writeln('المدرسة: $schoolName');
    b.writeln('-----------------------------');
    if (subjects.isEmpty) {
      b.writeln('لا توجد تقييمات مسجّلة بعد.');
    } else {
      b.writeln('التقييم التراكمي حسب المادة:');
      for (final s in subjects) {
        final avg = s['weighted_avg'];
        final max = s['max_score'] ?? 10;
        final weeks = s['weeks'] ?? 0;
        final val = avg == null ? '-' : '${(avg as num).toStringAsFixed(1)}/$max';
        b.writeln('• ${s['subject_name']}: $val  ($weeks أسبوع)');
      }
    }
    if (overall != null) {
      b.writeln('-----------------------------');
      b.writeln('المعدّل العام: ${overall.toStringAsFixed(1)}%');
    }
    if (note != null && note.trim().isNotEmpty) {
      b.writeln('ملاحظة: $note');
    }
    b.writeln('مع التقدير.');
    return b.toString();
  }
}
