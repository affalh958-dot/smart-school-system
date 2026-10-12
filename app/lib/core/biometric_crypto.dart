import 'dart:convert';
import 'dart:math';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// تشفير قوالب الوجه (السمات) في قاعدة البيانات — AES-256-CBC.
///
/// - مفتاح التشفير يُولَّد عشوائياً مرة واحدة ويُخزَّن في المخزن الآمن للنظام
///   (`flutter_secure_storage`): Keystore على أندرويد، DPAPI على ويندوز.
///   لا يُخزَّن المفتاح أبداً داخل قاعدة البيانات أو الكود.
/// - كل قالب يُشفَّر بمتجه تهيئة (IV) عشوائي جديد، ويُخزَّن على الشكل:
///   `encv1:` + base64(iv) + `:` + base64(ciphertext).
/// - للحفاظ على التوافق، أي قيمة لا تبدأ بـ`encv1:` تُقرأ كما هي (قوالب قديمة).
class BiometricCrypto {
  BiometricCrypto._();
  static final BiometricCrypto instance = BiometricCrypto._();

  static const _prefix = 'encv1';
  static const _keyName = 'school_biometric_key_v1';

  final _storage = const FlutterSecureStorage();

  enc.Key? _key;

  Future<enc.Key> _ensureKey() async {
    if (_key != null) return _key!;
    String? stored;
    try {
      stored = await _storage.read(key: _keyName);
    } catch (e) {
      debugPrint('تعذّر قراءة مفتاح التشفير: $e');
    }
    if (stored == null || stored.isEmpty) {
      final rnd = Random.secure();
      final bytes = Uint8List.fromList(List<int>.generate(32, (_) => rnd.nextInt(256)));
      stored = base64Encode(bytes);
      try {
        await _storage.write(key: _keyName, value: stored);
      } catch (e) {
        debugPrint('تعذّر حفظ مفتاح التشفير: $e');
      }
    }
    _key = enc.Key(base64Decode(stored));
    return _key!;
  }

  /// تشفير بايتات قالب → سلسلة جاهزة للتخزين.
  Future<String> encryptTemplate(List<int> plain) async {
    final key = await _ensureKey();
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
    final ct = encrypter.encryptBytes(plain, iv: iv);
    return '$_prefix:${base64Encode(iv.bytes)}:${ct.base64}';
  }

  /// فك تشفير قيمة مخزّنة → بايتات القالب. يعيد القيمة كما هي إن كانت غير مشفّرة (تراثية).
  Future<Uint8List> decryptTemplate(String stored) async {
    if (!stored.startsWith('$_prefix:')) {
      return Uint8List.fromList(utf8.encode(stored));
    }
    final parts = stored.split(':');
    if (parts.length != 3) throw const FormatException('قيمة قالب غير صالحة');
    final key = await _ensureKey();
    final iv = enc.IV(base64Decode(parts[1]));
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
    return Uint8List.fromList(encrypter.decryptBytes(enc.Encrypted(base64Decode(parts[2])), iv: iv));
  }
}
