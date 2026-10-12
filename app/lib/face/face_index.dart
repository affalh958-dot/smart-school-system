import 'dart:math' as math;
import 'dart:typed_data';

import '../core/config.dart';
import '../data/models.dart';

/// فهرس السمات في الذاكرة — بحث فوري بالتشابه الجيبي.
///
/// مصمّم لـ 5000 طالب: مصفوفة 5000×128 (≈640 ألف عدد) → مطابقة بأجزاء من
/// الميلي ثانية، دون أي بحث خطي على القرص.
class FaceIndex {
  final List<String> _studentIds = [];
  late Float32List _matrix; // [n * dim]
  int _dim = AppConfig.embeddingDim;
  int _count = 0;
  bool _built = false;

  int get size => _count;

  void build(List<BiometricTemplate> templates) {
    _count = templates.length;
    _studentIds
      ..clear()
      ..addAll(templates.map((t) => t.studentId));
    _dim = AppConfig.embeddingDim;
    _matrix = Float32List(math.max(_count, 1) * _dim);
    for (var i = 0; i < _count; i++) {
      final bytes = templates[i].templateEncrypted;
      final f = _bytesToFloats(bytes);
      final n = math.min(f.length, _dim);
      for (var j = 0; j < n; j++) {
        _matrix[i * _dim + j] = f[j];
      }
    }
    _built = true;
  }

  bool get isBuilt => _built;

  /// مطابقة تمثيل واحد: يعيد أفضل تطابق + هامش الفصل + القرار.
  FaceMatch identify(Float32List probe,
      {double threshold = AppConfig.matchThreshold, double margin = AppConfig.matchMargin}) {
    if (_count == 0) {
      return FaceMatch(score: 0, accepted: false, result: 'no_match');
    }
    var bestScore = -1.0;
    var bestIdx = -1;
    var secondScore = -1.0;
    for (var i = 0; i < _count; i++) {
      var dot = 0.0;
      final base = i * _dim;
      for (var j = 0; j < _dim; j++) {
        dot += _matrix[base + j] * probe[j];
      }
      if (dot > bestScore) {
        secondScore = bestScore;
        bestScore = dot;
        bestIdx = i;
      } else if (dot > secondScore) {
        secondScore = dot;
      }
    }

    if (bestScore < threshold) {
      return FaceMatch(score: bestScore, secondScore: secondScore, accepted: false, result: 'no_match');
    }
    // هامش الفصل: إن كان أفضل تطابقين متقاربين جداً → التباس (لا تخمين).
    if ((bestScore - secondScore) < margin && secondScore > threshold) {
      return FaceMatch(score: bestScore, secondScore: secondScore, accepted: false, result: 'ambiguous');
    }
    return FaceMatch(
      studentId: _studentIds[bestIdx],
      score: bestScore,
      secondScore: secondScore,
      accepted: true,
      result: 'matched',
    );
  }

  static Float32List _bytesToFloats(List<int> bytes) {
    final bd = ByteData(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      bd.setUint8(i, bytes[i]);
    }
    final n = bytes.length ~/ 4;
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getFloat32(i * 4, Endian.little);
    }
    return out;
  }

  static List<int> floatsToBytes(Float32List floats) {
    final bd = ByteData(floats.length * 4);
    for (var i = 0; i < floats.length; i++) {
      bd.setFloat32(i * 4, floats[i], Endian.little);
    }
    return bd.buffer.asUint8List();
  }
}
