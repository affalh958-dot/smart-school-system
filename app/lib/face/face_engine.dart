import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../core/config.dart';

/// محرّك التعرّف على الوجه — يعمل محلياً على الجهاز (لا شبكة، لا API مدفوع).
///
/// - استخراج السمات: MobileFaceNet (مدخل 112×112×3، مخرج 128 بُعداً).
/// - كشف الحيوية: نموذج Deep-Tree (مدخل 256×256×3).
///
/// المعالجة المطبَّقة مطابقة للمرجع مفتوح المصدر:
///   pixels -> (p - 127.5) / 128  ثم تطبيع L2.
class FaceEngine {
  Interpreter? _embedder;
  Interpreter? _liveness;
  bool _ready = false;

  bool get isReady => _ready;

  Future<void> load() async {
    if (_ready) return;
    try {
      _embedder = await Interpreter.fromAsset(AppConfig.faceModelAsset);
      try {
        _liveness = await Interpreter.fromAsset(AppConfig.livenessModelAsset);
      } catch (e) {
        debugPrint('نموذج الحيوية غير متاح: $e');
      }
      _ready = _embedder != null;
      debugPrint('تم تحميل محرّك الوجه: embeddings=${_embedder != null}, liveness=${_liveness != null}');
    } catch (e) {
      debugPrint('فشل تحميل محرّك الوجه: $e');
      _ready = false;
    }
  }

  /// استخراج تمثيل السمات (L2-normalized) لصورة وجه RGB بحجم 112×112.
  Float32List? embed(img.Image faceRgb) {
    if (_embedder == null) return null;
    final resized = img.copyResize(faceRgb, width: AppConfig.faceInputSize, height: AppConfig.faceInputSize);
    final input = _toFloatInput(resized, normalize: true);
    final output = List.filled(AppConfig.embeddingDim, 0.0).reshape([1, AppConfig.embeddingDim]);
    _embedder!.run(input, output);

    final vec = Float32List(AppConfig.embeddingDim);
    var norm = 0.0;
    for (var i = 0; i < AppConfig.embeddingDim; i++) {
      vec[i] = (output[0] as List)[i] as double;
      norm += vec[i] * vec[i];
    }
    norm = math.sqrt(norm);
    if (norm > 0) {
      for (var i = 0; i < vec.length; i++) {
        vec[i] = vec[i] / norm;
      }
    }
    return vec;
  }

  /// درجة الانتحال (أعلى = أكثر شبهة). يعيد null إن لم يتوفر النموذج.
  double? spoofScore(img.Image faceRgb) {
    if (_liveness == null) return null;
    final resized = img.copyResize(faceRgb, width: AppConfig.livenessInputSize, height: AppConfig.livenessInputSize);
    final input = _toFloatInput(resized, normalize: false, scale255: true);
    final preds = List.filled(8, 0.0).reshape([1, 8]);
    final mask = List.filled(8, 0.0).reshape([1, 8]);
    try {
      _liveness!.run(input, [preds, mask]);
    } catch (_) {
      _liveness!.run(input, preds);
      return null;
    }
    var score = 0.0;
    for (var i = 0; i < 8; i++) {
      score += (((preds[0] as List)[i] as double).abs()) * ((mask[0] as List)[i] as double);
    }
    return score;
  }

  List<List<List<List<double>>>> _toFloatInput(img.Image im, {required bool normalize, bool scale255 = false}) {
    final h = im.height, w = im.width;
    return List.generate(1, (_) {
      return List.generate(h, (y) {
        return List.generate(w, (x) {
          final px = im.getPixel(x, y);
          final r = px.r.toDouble(), g = px.g.toDouble(), b = px.b.toDouble();
          if (scale255) return [r / 255.0, g / 255.0, b / 255.0];
          if (normalize) return [(r - 127.5) / 128.0, (g - 127.5) / 128.0, (b - 127.5) / 128.0];
          return [r, g, b];
        });
      });
    });
  }

  void dispose() {
    _embedder?.close();
    _liveness?.close();
    _ready = false;
  }
}
