import 'package:shared_preferences/shared_preferences.dart';
import 'signer_store.dart';

enum SigningMethod { nsec, bunker, androidSigner, browserExtension }

class AuthUser {
  final String pubkey;
  final String name;
  final String? avatarUrl;
  final SigningMethod signingMethod;
  final List<String> writeRelays;

  const AuthUser({
    required this.pubkey,
    required this.name,
    this.avatarUrl,
    required this.signingMethod,
    this.writeRelays = const [],
  });
}

class AuthService {
  static const _kLoggedIn = 'logged_in';
  static const _kPubkey = 'pubkey';
  static const _kName = 'name';
  static const _kAvatarUrl = 'avatar_url';
  static const _kSigningMethod = 'signing_method';
  static const _kWriteRelays = 'write_relays';

  static Future<AuthUser?> loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kLoggedIn) != true) return null;
    final methodStr = prefs.getString(_kSigningMethod) ?? 'nsec';
    return AuthUser(
      pubkey: prefs.getString(_kPubkey) ?? '',
      name: prefs.getString(_kName) ?? 'Unknown',
      avatarUrl: prefs.getString(_kAvatarUrl),
      signingMethod: SigningMethod.values.firstWhere(
        (m) => m.name == methodStr,
        orElse: () => SigningMethod.nsec,
      ),
      writeRelays: prefs.getStringList(_kWriteRelays) ?? [],
    );
  }

  static Future<void> save(AuthUser user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLoggedIn, true);
    await prefs.setString(_kPubkey, user.pubkey);
    await prefs.setString(_kName, user.name);
    await prefs.setString(_kSigningMethod, user.signingMethod.name);
    if (user.avatarUrl != null) {
      await prefs.setString(_kAvatarUrl, user.avatarUrl!);
    }
    await prefs.setStringList(_kWriteRelays, user.writeRelays);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await SignerStore.clear();
  }
}
