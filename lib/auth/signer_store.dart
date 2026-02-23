import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

// OS-encrypted storage for sensitive auth credentials.
// macOS uses SharedPreferences (UserDefaults) — keychain requires dev certificate.
class SignerStore {
  static const _storage = FlutterSecureStorage();
  static const _kNsecPrivkey = 'nsec_privkey';
  static const _kBunkerConnection = 'bunker_connection';
  static const _kAndroidPackage = 'android_package';

  static bool get _isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static Future<void> _write(String key, String value) async {
    if (_isMacOS) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('signer_$key', value);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  static Future<String?> _read(String key) async {
    if (_isMacOS) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('signer_$key');
    }
    return _storage.read(key: key);
  }

  static Future<void> saveNsecPrivkey(String hexPrivkey) =>
      _write(_kNsecPrivkey, hexPrivkey);

  static Future<String?> loadNsecPrivkey() => _read(_kNsecPrivkey);

  static Future<void> saveBunkerConnection(Map<String, dynamic> json) =>
      _write(_kBunkerConnection, jsonEncode(json));

  static Future<Map<String, dynamic>?> loadBunkerConnection() async {
    final raw = await _read(_kBunkerConnection);
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  static Future<void> saveAndroidPackage(String packageName) =>
      _write(_kAndroidPackage, packageName);

  static Future<String?> loadAndroidPackage() => _read(_kAndroidPackage);

  static Future<void> clear() async {
    if (_isMacOS) {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.remove('signer_$_kNsecPrivkey'),
        prefs.remove('signer_$_kBunkerConnection'),
        prefs.remove('signer_$_kAndroidPackage'),
      ]);
    } else {
      await _storage.deleteAll();
    }
  }
}
