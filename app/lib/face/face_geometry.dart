import 'dart:ui';

/// رياضيات تحديد موضع الوجه — دوال نقية قابلة للاختبار بدون كاميرا.
///
/// صندوق ML Kit يُعطى في إحداثيات **الصورة المدوّرة**، بينما نبني صورة RGB في
/// اتجاه المستشعر الأصلي. لذلك نحوّل الإحداثيات رياضياً، وإلا كان الاقتصاص
/// خاطئاً وترتفع نسبة فشل التعرّف.
class FaceGeometry {
  /// زاوية دوران الإطار من المستشعر إلى ما يحلّله ML Kit (0/90/180/270).
  static int rotationDegrees({
    required bool isFront,
    required int sensorOrientation,
    required int deviceOrientation,
  }) {
    if (isFront) {
      return (sensorOrientation + deviceOrientation) % 360;
    }
    return (sensorOrientation - deviceOrientation + 360) % 360;
  }

  /// يحوّل صندوقاً في إحداثيات الصورة المدوّرة إلى إحداثيات صورة المستشعر
  /// (بأبعاد sensorSize) لإجراء الاقتصاص الصحيح.
  static Rect rotatedBoxToSensor(
      Rect box, Size sensorSize, int rotationDegrees) {
    final f = sensorSize.width;
    final h = sensorSize.height;
    final bx = box.left, by = box.top, bw = box.width, bh = box.height;
    switch (rotationDegrees % 360) {
      case 90:
        // دوران عكس عقارب الساعة: العرض المُدوّر = عرض المستشعر.
        return Rect.fromLTWH(by, f - bx - bw, bh, bw);
      case 270:
        return Rect.fromLTWH(f - by - bh, bx, bh, bw);
      case 180:
        return Rect.fromLTWH(f - bx - bw, h - by - bh, bw, bh);
      default:
        return Rect.fromLTWH(bx, by, bw, bh);
    }
  }

  /// مستطيل نسبي (0..1) للصورة المدوّرة (لرسم المربّع فوق الوجه بدقّة).
  static Rect rotatedBoxToFraction(Rect box, Size sensorSize, int rotationDegrees) {
    final rot = rotationDegrees % 360;
    final r = rotatedBoxToSensor(box, sensorSize, rot);
    final rotatedW = (rot == 90 || rot == 270) ? sensorSize.height : sensorSize.width;
    final rotatedH = (rot == 90 || rot == 270) ? sensorSize.width : sensorSize.height;
    return Rect.fromLTWH(
      r.left / rotatedW,
      r.top / rotatedH,
      r.width / rotatedW,
      r.height / rotatedH,
    );
  }
}
