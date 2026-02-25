import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

// AES-256-GCM helpers for local note storage.
// Wire format: base64( nonce[12] || ciphertext || mac[16] )
class LocalCrypto {
  static final _aes = AesGcm.with256bits();

  static Future<String> encrypt(List<int> key, String plaintext) async {
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(key),
    );
    final out = Uint8List(
        box.nonce.length + box.cipherText.length + box.mac.bytes.length);
    out.setAll(0, box.nonce);
    out.setAll(box.nonce.length, box.cipherText);
    out.setAll(box.nonce.length + box.cipherText.length, box.mac.bytes);
    return base64Encode(out);
  }

  static Future<String?> decrypt(List<int> key, String encoded) async {
    try {
      final bytes = base64Decode(encoded);
      const nonceLen = 12;
      const macLen = 16;
      if (bytes.length < nonceLen + macLen) return null;
      final box = SecretBox(
        bytes.sublist(nonceLen, bytes.length - macLen),
        nonce: bytes.sublist(0, nonceLen),
        mac: Mac(bytes.sublist(bytes.length - macLen)),
      );
      final plain = await _aes.decrypt(box, secretKey: SecretKey(key));
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }
}
