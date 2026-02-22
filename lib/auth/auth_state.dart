import 'package:shared_preferences/shared_preferences.dart';

class AuthUser {
  final String pubkey;
  final String name;
  final String? avatarUrl;

  const AuthUser({
    required this.pubkey,
    required this.name,
    this.avatarUrl,
  });

  factory AuthUser.fake() => const AuthUser(
        pubkey:
            'npub1satoshi0000000000000000000000000000000000000000000000000000000',
        name: 'Satoshi',
        avatarUrl: 'https://i.pravatar.cc/150?img=3',
      );
}

class AuthService {
  static const _kLoggedIn = 'logged_in';
  static const _kPubkey = 'pubkey';
  static const _kName = 'name';
  static const _kAvatarUrl = 'avatar_url';

  static Future<AuthUser?> loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kLoggedIn) != true) return null;
    return AuthUser(
      pubkey: prefs.getString(_kPubkey) ?? '',
      name: prefs.getString(_kName) ?? 'Unknown',
      avatarUrl: prefs.getString(_kAvatarUrl),
    );
  }

  static Future<void> save(AuthUser user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLoggedIn, true);
    await prefs.setString(_kPubkey, user.pubkey);
    await prefs.setString(_kName, user.name);
    if (user.avatarUrl != null) {
      await prefs.setString(_kAvatarUrl, user.avatarUrl!);
    }
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }
}
