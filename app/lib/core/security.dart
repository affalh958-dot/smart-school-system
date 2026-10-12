import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

/// أدوات الأمان: تجزئة كلمات المرور (PBKDF2-HMAC-SHA256) وتوليد الملح.
///
/// ملاحظة: هذه الطبقة تُستخدم للحسابات المحلية على الجهاز. على الخادم
/// يُستخدم Argon2id. لا تُخزَّن أي كلمة مرور نصية إطلاقاً.
class Security {
  static const int _iterations = 100000;
  static const int _keyLength = 32;

  static String generateSalt([int bytes = 16]) {
    final rnd = Random.secure();
    final salt = List<int>.generate(bytes, (_) => rnd.nextInt(256));
    return base64Encode(salt);
  }

  /// PBKDF2-HMAC-SHA256
  static String hashPassword(String password, String salt) {
    final saltBytes = base64Decode(salt);
    final key = _pbkdf2(utf8.encode(password), saltBytes, _iterations, _keyLength);
    return base64Encode(key);
  }

  static bool verifyPassword(String password, String salt, String expectedHash) {
    final computed = hashPassword(password, salt);
    // مقارنة ثابتة الزمن
    if (computed.length != expectedHash.length) return false;
    var diff = 0;
    for (var i = 0; i < computed.length; i++) {
      diff |= computed.codeUnitAt(i) ^ expectedHash.codeUnitAt(i);
    }
    return diff == 0;
  }

  static List<int> _pbkdf2(List<int> password, List<int> salt, int iterations, int keyLen) {
    final hmac = Hmac(sha256, password);
    final blocks = (keyLen / 32).ceil();
    final out = <int>[];
    for (var i = 1; i <= blocks; i++) {
      var u = hmac.convert([...salt, ..._intToBytes(i)]).bytes;
      var t = List<int>.from(u);
      for (var j = 1; j < iterations; j++) {
        u = hmac.convert(u).bytes;
        for (var k = 0; k < t.length; k++) {
          t[k] ^= u[k];
        }
      }
      out.addAll(t);
    }
    return out.sublist(0, keyLen);
  }

  static List<int> _intToBytes(int i) =>
      [(i >> 24) & 0xff, (i >> 16) & 0xff, (i >> 8) & 0xff, i & 0xff];
}
