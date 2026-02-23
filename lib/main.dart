import 'package:flutter/material.dart';
import 'package:ndk/ndk.dart';
import 'package:ndk/shared/nips/nip01/bip340.dart';
import 'package:ndk/data_layer/repositories/signers/nip46_event_signer.dart';

import 'auth/amber_event_signer.dart';
import 'auth/auth_state.dart';
import 'auth/nostr_client.dart';
import 'auth/profile_fetcher.dart';
import 'auth/signer_session.dart';
import 'auth/signer_store.dart';
import 'screens/login_screen.dart';
import 'screens/notes_screen.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  NostrClient().init();
  final user = await AuthService.loadUser();
  if (user != null) await _restoreSession(user);
  runApp(ManentApp(initialUser: user));
}

Future<void> _restoreSession(AuthUser user) async {
  switch (user.signingMethod) {
    case SigningMethod.nsec:
      final privkey = await SignerStore.loadNsecPrivkey();
      if (privkey != null) {
        final pubkey = Bip340.getPublicKey(privkey);
        SignerSession.set(Bip340EventSigner(privateKey: privkey, publicKey: pubkey));
      }
    case SigningMethod.bunker:
      final json = await SignerStore.loadBunkerConnection();
      if (json != null) {
        final connection = BunkerConnection.fromJson(json);
        final ndk = NostrClient().ndk;
        // Reconstruct signer with cached pubkey — avoids a network round-trip on startup
        final signer = Nip46EventSigner(
          connection: connection,
          requests: ndk.requests,
          broadcast: ndk.broadcast,
          cachedPublicKey: user.pubkey,
        );
        SignerSession.set(signer);
      }
    case SigningMethod.androidSigner:
      SignerSession.set(AmberEventSigner(pubkey: user.pubkey));
  }
}

class ManentApp extends StatefulWidget {
  final AuthUser? initialUser;

  const ManentApp({super.key, this.initialUser});

  @override
  State<ManentApp> createState() => _ManentAppState();
}

class _ManentAppState extends State<ManentApp> {
  AuthUser? _user;

  @override
  void initState() {
    super.initState();
    _user = widget.initialUser;
    if (_user != null) _refreshProfile();
  }

  Future<void> _refreshProfile() async {
    final profile = await ProfileFetcher.fetch(_user!.pubkey);
    if (!mounted) return;
    if (profile.name == _user!.name && profile.avatarUrl == _user!.avatarUrl) {
      return;
    }
    final updated = AuthUser(
      pubkey: _user!.pubkey,
      name: profile.name,
      avatarUrl: profile.avatarUrl,
      signingMethod: _user!.signingMethod,
    );
    await AuthService.save(updated);
    if (mounted) setState(() => _user = updated);
  }

  Future<void> _onLogin(AuthUser user) async {
    await AuthService.save(user);
    setState(() => _user = user);
  }

  Future<void> _onLogout() async {
    SignerSession.clear();
    setState(() => _user = null);
    await AuthService.clear();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Manent',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
        ),
        useMaterial3: true,
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: _user == null
          ? LoginScreen(onLogin: _onLogin)
          : NotesScreen(user: _user!, onLogout: _onLogout),
    );
  }
}
