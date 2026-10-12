import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:school_app/core/config.dart';
import 'package:school_app/data/models.dart';
import 'package:school_app/face/face_index.dart';

/// يثبت أن مطابقة الوجه تعمل فعلاً على متجهات حقيقية:
///  - تمييز الطالب الصحيح بأعلى تشابه.
///  - رفض غير المعروف (تحت الحد).
///  - رفض الالتباس بين شخصين متقاربين (لا تخمين).
Float32List _unit(List<double> v) {
  var n = 0.0;
  for (final x in v) {
    n += x * x;
  }
  n = math.sqrt(n);
  final out = Float32List(v.length);
  for (var i = 0; i < v.length; i++) {
    out[i] = v[i] / n;
  }
  return out;
}

Float32List _seed(int seed, {double noise = 0}) {
  final rnd = math.Random(seed);
  final dim = AppConfig.embeddingDim;
  return _unit(List.generate(dim, (_) => rnd.nextDouble() - 0.5 + noise));
}

BiometricTemplate _tpl(String studentId, Float32List vec) => BiometricTemplate(
      id: 't_$studentId',
      studentId: studentId,
      templateEncrypted: Float32List.fromList(vec).buffer.asUint8List(),
      embeddingDim: AppConfig.embeddingDim,
      templateVersion: 'mobilefacenet-v1',
      isActive: true,
    );

void main() {
  group('مطابقة الوجه (FaceIndex)', () {
    late FaceIndex index;
    late Float32List a, b, c;

    setUp(() {
      a = _seed(1);
      b = _seed(2);
      c = _seed(3);
      index = FaceIndex()
        ..build([
          _tpl('student-A', a),
          _tpl('student-B', b),
          _tpl('student-C', c),
        ]);
    });

    test('يتعرّف على الطالب الصحيح من نفس المتجه (تشابه = 1)', () {
      final m = index.identify(a);
      expect(m.accepted, isTrue);
      expect(m.studentId, 'student-A');
      expect(m.score, closeTo(1.0, 1e-6));
    });

    test('يقبل صورة مشوّشة قليلاً لنفس الطالب (متانة)', () {
      // إزاحة صغيرة لا تغيّر الهوية.
      final noisy = _unit(List.generate(AppConfig.embeddingDim, (i) => a[i] + 0.02 * (i.isEven ? 1 : -1)));
      final m = index.identify(noisy);
      expect(m.accepted, isTrue);
      expect(m.studentId, 'student-A');
    });

    test('يرفض غير المعروف (أقل من الحد) ولا يخمّن', () {
      final unknown = _seed(999);
      final m = index.identify(unknown, threshold: 0.9);
      expect(m.accepted, isFalse);
      expect(m.result, 'no_match');
    });

    test('يرفض الالتباس عندما يكون أفضل تطابقين متقاربين جداً', () {
      // طالبان متطابقان تقريباً → يجب رفض لا اختيار عشوائي.
      final twinA = _seed(7);
      final twinB = _unit(List.generate(AppConfig.embeddingDim, (i) => twinA[i] + 0.001 * (i.isEven ? 1 : -1)));
      final idx = FaceIndex()..build([_tpl('X', twinA), _tpl('Y', twinB)]);
      final m = idx.identify(twinA, threshold: 0.1, margin: 0.5);
      expect(m.accepted, isFalse);
      expect(m.result, 'ambiguous');
    });

    test('الفهرس الفارغ لا يقبل شيئاً', () {
      final empty = FaceIndex()..build([]);
      final m = empty.identify(a);
      expect(m.accepted, isFalse);
      expect(m.result, 'no_match');
    });
  });
}
