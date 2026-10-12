import 'package:uuid/uuid.dart';

/// ثوابت النظام وإعدادات التعرّف على الوجه القابلة للضبط.
class AppConfig {
  static const String appName = 'نظام إدارة المدرسة الذكي';
  static const String timezone = 'Asia/Baghdad';

  // نموذج التعرّف على الوجه
  static const String faceModelAsset = 'assets/models/mobilefacenet.tflite';
  static const String livenessModelAsset = 'assets/models/liveness_antispoof.tflite';
  static const int faceInputSize = 112;     // MobileFaceNet
  static const int embeddingDim = 128;
  static const int livenessInputSize = 256;

  // عتبات المطابقة (قابلة للضبط من الإعدادات)
  static const double matchThreshold = 0.45;   // الحد الأدنى للتشابه الجيبي
  static const double matchMargin = 0.05;      // هامش الفصل بين أفضل تطابقين
  static const double spoofThreshold = 0.20;   // > القيمة = محاولة انتحال
  static const int cooldownSeconds = 6;        // منع احتساب الوجه نفسه مراراً

  /// تفعيل منع الانتحال فعلياً. الافتراضي **معطّل** لأن مخرجات نموذج الحيوية
  /// غير معايَرة لبياناتنا؛ تفعيله بعتبة خاطئة يرفض الوجوه الحقيقية فيعطّل
  /// التعرّف بالكامل. نبقيه استرشادياً حتى معايرته على صور المدرسة الفعلية.
  static const bool enforceLiveness = false;

  static const Uuid uuid = Uuid();

  static String newId() => uuid.v4();
}
