import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// أدوات مشتركة لتحويل إطارات الكاميرا واقتصاص الوجه.
///
/// ملاحظة مهمة عن الدقة: إطارات الكاميرا بصيغة YUV (NV21). الاعتماد على
/// قناة الإضاءة (Y) وحدها ينتج صورة رمادية، وهذا يضعف دقة المطابقة بشدة.
/// لذلك نحوّل YUV → RGB كاملاً قبل استخراج السمات.
class CameraUtils {
  /// قصّ منطقة الوجه مع هامش، من صورة RGB.
  static img.Image? cropFace(img.Image source,
      {required double left, required double top, required double width, required double height}) {
    try {
      final pad = width * 0.15;
      final l = (left - pad).clamp(0, source.width - 1).toInt();
      final t = (top - pad).clamp(0, source.height - 1).toInt();
      final w = (width + pad * 2).clamp(1, source.width - l).toInt();
      final h = (height + pad * 2).clamp(1, source.height - t).toInt();
      return img.copyCrop(source, x: l, y: t, width: w, height: h);
    } catch (_) {
      return null;
    }
  }

  /// قصّ وجه من صورة كاملة باستخدام صندوق إحاطة (بدون الحاجة إلى Face).
  static img.Image? cropBox(img.Image source, double left, double top, double width, double height) =>
      cropFace(source, left: left, top: top, width: width, height: height);

  /// تحويل صورة الكاميرا (NV21/YUV420) إلى RGB.
  static img.Image? yuvToRgb({
    required Uint8List yPlane,
    Uint8List? uPlane,
    Uint8List? vPlane,
    required int width,
    required int height,
    int yRowStride = 0,
    int uvRowStride = 0,
    int uvPixelStride = 1,
  }) {
    try {
      final out = img.Image(width: width, height: height);
      final yStride = yRowStride == 0 ? width : yRowStride;
      final hasUv = uPlane != null && vPlane != null;
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final yIndex = y * yStride + x;
          if (yIndex >= yPlane.length) continue;
          final yValue = yPlane[yIndex];
          int r, g, b;
          if (hasUv) {
            final uvRow = y >> 1;
            final uvCol = x >> 1;
            final uvIndex = uvRow * (uvRowStride == 0 ? (width >> 1) : uvRowStride) + uvCol * uvPixelStride;
            final u = uvIndex < uPlane.length ? uPlane[uvIndex] : 128;
            final v = uvIndex < vPlane.length ? vPlane[uvIndex] : 128;
            final yf = (yValue - 16).clamp(0, 255);
            final uf = u - 128;
            final vf = v - 128;
            r = ((1.164 * yf + 1.596 * vf)).round().clamp(0, 255);
            g = ((1.164 * yf - 0.392 * uf - 0.813 * vf)).round().clamp(0, 255);
            b = ((1.164 * yf + 2.017 * uf)).round().clamp(0, 255);
          } else {
            r = g = b = yValue;
          }
          out.setPixelRgb(x, y, r, g, b);
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// تحويل إطار الكاميرا الكامل إلى RGB باستخدام planes المتاحة.
  static img.Image? frameToRgb(dynamic image) {
    try {
      final planes = image.planes as List;
      final width = image.width as int;
      final height = image.height as int;
      final yPlane = (planes[0].bytes as Uint8List);
      final yRowStride = planes[0].bytesPerRow as int;
      Uint8List? uPlane;
      Uint8List? vPlane;
      var uvRowStride = 0;
      var uvPixelStride = 1;
      if (planes.length >= 3) {
        // YUV420 planar (Android): plane 1 = U, plane 2 = V
        uPlane = planes[1].bytes as Uint8List;
        vPlane = planes[2].bytes as Uint8List;
        uvRowStride = planes[1].bytesPerRow as int;
        uvPixelStride = planes[1].bytesPerPixel as int? ?? 1;
      } else if (planes.length == 2) {
        // NV12/NV21 (iOS/بعض الأجهزة): plane 1 = UV مع تشابك
        final uv = planes[1].bytes as Uint8List;
        uvRowStride = planes[1].bytesPerRow as int;
        uvPixelStride = planes[1].bytesPerPixel as int? ?? 2;
        uPlane = uv;
        vPlane = uv;
      }
      return yuvToRgb(
        yPlane: yPlane,
        uPlane: uPlane,
        vPlane: vPlane,
        width: width,
        height: height,
        yRowStride: yRowStride,
        uvRowStride: uvRowStride,
        uvPixelStride: uvPixelStride,
      );
    } catch (_) {
      return null;
    }
  }
}
