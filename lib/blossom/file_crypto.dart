import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

// AES-256-GCM for per-file encryption.
// Wire format: nonce[12] || ciphertext || mac[16] as raw bytes.
class FileCrypto {
  static final _aes = AesGcm.with256bits();

  static List<int> generateKey() {
    final rng = Random.secure();
    return List<int>.generate(32, (_) => rng.nextInt(256));
  }

  static Future<Uint8List> encrypt(List<int> key, Uint8List data) async {
    final box = await _aes.encrypt(data, secretKey: SecretKey(key));
    final out = Uint8List(
        box.nonce.length + box.cipherText.length + box.mac.bytes.length);
    out.setAll(0, box.nonce);
    out.setAll(box.nonce.length, box.cipherText);
    out.setAll(box.nonce.length + box.cipherText.length, box.mac.bytes);
    return out;
  }

  static Future<Uint8List?> decrypt(List<int> key, Uint8List data) async {
    try {
      const nonceLen = 12;
      const macLen = 16;
      if (data.length < nonceLen + macLen) return null;
      final box = SecretBox(
        data.sublist(nonceLen, data.length - macLen),
        nonce: data.sublist(0, nonceLen),
        mac: Mac(data.sublist(data.length - macLen)),
      );
      final plain = await _aes.decrypt(box, secretKey: SecretKey(key));
      return Uint8List.fromList(plain);
    } catch (_) {
      return null;
    }
  }

  // Returns hex-encoded SHA-256 of the given bytes
  static Future<String> sha256Hex(Uint8List data) async {
    final hash = await Sha256().hash(data);
    return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // Encodes key bytes as lowercase hex
  static String keyToHex(List<int> key) =>
      key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  // Decodes hex key back to bytes
  static List<int> hexToKey(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }
}
