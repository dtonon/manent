import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Persists a 32-byte AES key for local note encryption.
// macOS uses SharedPreferences (UserDefaults) — keychain requires dev certificate.
class LocalKeyStore {
  static const _storage = FlutterSecureStorage();
  static const _kKey = 'local_notes_key';

  static bool get _isMacOS =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  static Future<List<int>> loadOrCreate() async {
    final existing = await _read(_kKey);
    if (existing != null) return base64Decode(existing);
    final key = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    await _write(_kKey, base64Encode(key));
    return key;
  }

  static Future<void> _write(String key, String value) async {
    if (_isMacOS) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('notes_$key', value);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  static Future<String?> _read(String key) async {
    if (_isMacOS) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('notes_$key');
    }
    return _storage.read(key: key);
  }

  static Future<void> clear() async {
    if (_isMacOS) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('notes_$_kKey');
    } else {
      await _storage.delete(key: _kKey);
    }
  }
}
