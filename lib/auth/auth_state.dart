import 'package:shared_preferences/shared_preferences.dart';
import '../app_flavor.dart';
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
  static String get _p => AppFlavor.storagePrefix;
  static final _kLoggedIn            = '${_p}logged_in';
  static final _kPubkey              = '${_p}pubkey';
  static final _kName                = '${_p}name';
  static final _kAvatarUrl           = '${_p}avatar_url';
  static final _kSigningMethod       = '${_p}signing_method';
  static final _kWriteRelays         = '${_p}write_relays';
  static final _kAdditionalRelays    = '${_p}additional_write_relays';
  static final _kFallbackPromptShown = '${_p}fallback_relay_prompt_shown';
  static final _kBlossomServers      = '${_p}blossom_servers';
  static final _kImageResizePreset   = '${_p}image_resize_preset';

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

  static Future<List<String>> loadAdditionalRelays() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kAdditionalRelays) ?? [];
  }

  static Future<void> saveAdditionalRelays(List<String> relays) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kAdditionalRelays, relays);
  }

  static Future<List<String>> loadBlossomServers() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kBlossomServers) ?? [];
  }

  static Future<void> saveBlossomServers(List<String> servers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kBlossomServers, servers);
  }

  static Future<bool> getFallbackPromptShown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kFallbackPromptShown) ?? false;
  }

  static Future<void> setFallbackPromptShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kFallbackPromptShown, true);
  }

  static Future<String?> getImageResizePreset() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kImageResizePreset);
  }

  static Future<void> setImageResizePreset(String preset) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kImageResizePreset, preset);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await SignerStore.clear();
  }
}
