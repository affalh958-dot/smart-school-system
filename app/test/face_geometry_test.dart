import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:school_app/face/face_geometry.dart';

/// يثبّت إصلاح دقّة التعرّف: الروتاسيون وتحويل إحداثيات الوجه.
void main() {
  group('هندسة الوجه: الدوران', () {
    test('خلفية، عمودي (device=0)، مستشعر 90 → 90', () {
      expect(
        FaceGeometry.rotationDegrees(
            isFront: false, sensorOrientation: 90, deviceOrientation: 0),
        90,
      );
    });

    test('خلفية، أفقي (device=90)، مستشعر 90 → 0 (بلا دوران)', () {
      expect(
        FaceGeometry.rotationDegrees(
            isFront: false, sensorOrientation: 90, deviceOrientation: 90),
        0,
      );
    });

    test('أمامية، عمودي، مستشعر 270 → 270', () {
      expect(
        FaceGeometry.rotationDegrees(
            isFront: true, sensorOrientation: 270, deviceOrientation: 0),
        270,
      );
    });

    test('الزاوية دائماً ضمن [0,360)', () {
      for (final front in [true, false]) {
        for (final s in [0, 90, 180, 270]) {
          for (final d in [0, 90, 180, 270]) {
            final r = FaceGeometry.rotationDegrees(
                isFront: front, sensorOrientation: s, deviceOrientation: d);
            expect(r >= 0 && r < 360, isTrue);
          }
        }
      }
    });
  });

  group('هندسة الوجه: تحويل الصندوق', () {
    final sensor = const Size(100, 200);

    test('بلا دوران: الصندوق كما هو', () {
      final box = const Rect.fromLTWH(10, 20, 30, 40);
      expect(
        FaceGeometry.rotatedBoxToSensor(box, sensor, 0),
        const Rect.fromLTWH(10, 20, 30, 40),
      );
    });

    test('دوران 90: العرض والارتفاع يتبادلان والإحداثيات صحيحة', () {
      final box = const Rect.fromLTWH(10, 20, 30, 40);
      // left=by=20, top=f-bx-bw=100-10-30=60, w=bh=40, h=bw=30
      expect(
        FaceGeometry.rotatedBoxToSensor(box, sensor, 90),
        const Rect.fromLTWH(20, 60, 40, 30),
      );
    });

    test('دوران 270: مرآة 90', () {
      final box = const Rect.fromLTWH(10, 20, 30, 40);
      // left=f-by-bh=100-20-40=40, top=bx=10, w=bh=40, h=bw=30
      expect(
        FaceGeometry.rotatedBoxToSensor(box, sensor, 270),
        const Rect.fromLTWH(40, 10, 40, 30),
      );
    });

    test('دوران 180: مرآة كاملة', () {
      final box = const Rect.fromLTWH(10, 20, 30, 40);
      // left=100-10-30=60, top=200-20-40=140
      expect(
        FaceGeometry.rotatedBoxToSensor(box, sensor, 180),
        const Rect.fromLTWH(60, 140, 30, 40),
      );
    });

    test('المستطيل النسبي داخل [0,1] وبعيد عن الحواف المضلّلة', () {
      final box = const Rect.fromLTWH(10, 20, 30, 40);
      final frac = FaceGeometry.rotatedBoxToFraction(box, sensor, 90);
      expect(frac.left, greaterThanOrEqualTo(0));
      expect(frac.top, greaterThanOrEqualTo(0));
      expect(frac.right, lessThanOrEqualTo(1.0));
      expect(frac.bottom, lessThanOrEqualTo(1.0));
    });
  });
}
