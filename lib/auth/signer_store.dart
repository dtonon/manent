import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

// OS-encrypted storage for sensitive auth credentials.
// macOS and web use SharedPreferences — keychain requires dev certificate on macOS,
// and FlutterSecureStorage has no web support.
// nsec is never persisted on web (session-only).
class SignerStore {
  static const _storage = FlutterSecureStorage();
  static const _kNsecPrivkey = 'nsec_privkey';
  static const _kBunkerConnection = 'bunker_connection';
  static const _kAndroidPackage = 'android_package';

  // True on platforms where SharedPreferences is used instead of secure storage
  static bool get _useSharedPrefs =>
      kIsWeb || (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS);

  static Future<void> _write(String key, String value) async {
    if (_useSharedPrefs) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('signer_$key', value);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  static Future<String?> _read(String key) async {
    if (_useSharedPrefs) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('signer_$key');
    }
    return _storage.read(key: key);
  }

  // nsec is not persisted on web — private key must not be stored in localStorage
  static Future<void> saveNsecPrivkey(String hexPrivkey) async {
    if (kIsWeb) return;
    await _write(_kNsecPrivkey, hexPrivkey);
  }

  static Future<String?> loadNsecPrivkey() async {
    if (kIsWeb) return null;
    return _read(_kNsecPrivkey);
  }

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
    if (_useSharedPrefs) {
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
