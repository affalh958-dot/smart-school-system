import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../face/face_geometry.dart';

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

  /// يبني بايتات NV21 كاملة (Y + VU متشابكة) من planes إطار الكاميرا.
  ///
  /// هذه الخطوة ضرورية: ML Kit يحتاج الصورة كاملةً (الإضاءة + اللون). تمرير
  /// قناة Y وحدها يجعل الكشف ضعيفاً وغير موثوق. نقصّ أي حشوة (padding) في
  /// الصفوف حتى تكون الأبعاد مطابقة تماماً لما يعرفه ML Kit.
  static Uint8List? toNv21Bytes(CameraImage image) {
    try {
      final width = image.width;
      final height = image.height;
      final out = Uint8List(width * height * 3 ~/ 2);
      final yPlane = image.planes[0];
      final ySrc = yPlane.bytes;
      final yRowStride = yPlane.bytesPerRow;
      final yPixelStride = yPlane.bytesPerPixel ?? 1;

      var pos = 0;
      for (var y = 0; y < height; y++) {
        var srcRow = y * yRowStride;
        for (var x = 0; x < width; x++) {
          out[pos++] = ySrc[srcRow + x * yPixelStride];
        }
      }

      if (image.planes.length >= 3) {
        // YUV420 planar: U ثم V — والمطلوب VU (NV21).
        final uSrc = image.planes[1].bytes;
        final vSrc = image.planes[2].bytes;
        final uRowStride = image.planes[1].bytesPerRow;
        final uPixelStride = image.planes[1].bytesPerPixel ?? 1;
        final vRowStride = image.planes[2].bytesPerRow;
        final vPixelStride = image.planes[2].bytesPerPixel ?? 1;
        final uvH = height ~/ 2, uvW = width ~/ 2;
        for (var y = 0; y < uvH; y++) {
          for (var x = 0; x < uvW; x++) {
            out[pos++] = vSrc[y * vRowStride + x * vPixelStride];
            out[pos++] = uSrc[y * uRowStride + x * uPixelStride];
          }
        }
      } else if (image.planes.length >= 2) {
        // NV21/NV12 جاهزة (بعض الأجهزة): نستخدم UV المتشابك مباشرة.
        final uvSrc = image.planes[1].bytes;
        final uvRowStride = image.planes[1].bytesPerRow;
        final uvPixelStride = image.planes[1].bytesPerPixel ?? 2;
        final uvH = height ~/ 2, uvW = width ~/ 2;
        for (var y = 0; y < uvH; y++) {
          for (var x = 0; x < uvW; x++) {
            final idx = y * uvRowStride + x * uvPixelStride;
            out[pos++] = uvSrc[idx];
            out[pos++] = uvSrc[idx + 1];
          }
        }
      } else {
        // لا لون متاح: نملأ الرمادي المحايد (128) بدل إسقاط الكشف.
        final rest = width * height ~/ 2;
        for (var i = 0; i < rest; i++) {
          out[pos++] = 128;
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// زاوية دوران الإطار المطلوبة لـ ML Kit حسب اتجاه الكاميرا واتجاه الجهاز.
  static InputImageRotation rotationFor(
      CameraLensDirection lens, int sensorOrientation, int deviceOrientation) {
    int rotationCompensation;
    switch (deviceOrientation) {
      case 0:
        rotationCompensation = 0;
        break;
      case 90:
        rotationCompensation = 90;
        break;
      case 180:
        rotationCompensation = 180;
        break;
      default:
        rotationCompensation = 270;
        break;
    }
    final int result;
    if (lens == CameraLensDirection.front) {
      result = (sensorOrientation + rotationCompensation) % 360;
    } else {
      result = (sensorOrientation - rotationCompensation + 360) % 360;
    }
    switch (result) {
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        return InputImageRotation.rotation0deg;
    }
  }

  /// يبني InputImage صحيحاً (NV21 كامل + دوران مناسب) لكشف الوجه بـ ML Kit.
  static InputImage? toInputImage(CameraImage image, CameraDescription camera, int deviceOrientation) {
    final nv21 = toNv21Bytes(image);
    if (nv21 == null) return null;
    return InputImage.fromBytes(
      bytes: nv21,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotationFor(camera.lensDirection, camera.sensorOrientation, deviceOrientation),
        format: InputImageFormat.nv21,
        bytesPerRow: image.width,
      ),
    );
  }

  /// درجة دوران الإطار من مستشعر الكاميرا إلى الصورة التي يحلّلها ML Kit.
  static int rotationDegrees(CameraDescription camera, int deviceOrientation) =>
      FaceGeometry.rotationDegrees(
        isFront: camera.lensDirection == CameraLensDirection.front,
        sensorOrientation: camera.sensorOrientation,
        deviceOrientation: deviceOrientation,
      );

  /// يقتصّ وجه ML Kit من صورة RGB مبنية في اتجاه المستشعر، مع تحويل صحيح
  /// للإحداثيات حسب الدوران (وإلا كان الاقتصاص خاطئاً وترتفع نسبة الفشل).
  static img.Image? cropFaceRotated(CameraImage image, dynamic face, int rot) {
    try {
      final full = frameToRgb(image);
      if (full == null) return null;
      final sensor = Size(image.width.toDouble(), image.height.toDouble());
      final r = FaceGeometry.rotatedBoxToSensor(face.boundingBox as Rect, sensor, rot);
      return cropBox(full, r.left, r.top, r.width, r.height);
    } catch (_) {
      return null;
    }
  }

  /// يحوّل صندوق ML Kit إلى مستطيل نسبي (0..1) داخل الصورة المدوّرة.
  static Rect? boxToFraction(Face face, Size sensor, int rot) {
    try {
      return FaceGeometry.rotatedBoxToFraction(face.boundingBox, sensor, rot);
    } catch (_) {
      return null;
    }
  }
}
