import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ndk/ndk.dart';
import 'package:ndk/shared/nips/nip01/bip340.dart';
import 'package:ndk/data_layer/repositories/signers/nip46_event_signer.dart';

import 'auth/amber_event_signer.dart';
import 'auth/nip07_event_signer.dart';
import 'auth/auth_state.dart';
import 'auth/nostr_client.dart';
import 'auth/profile_fetcher.dart';
import 'auth/relay_fetcher.dart';
import 'auth/signer_session.dart';
import 'auth/signer_store.dart';
import 'notes/note_cache.dart';
import 'notes/notes_database.dart';
import 'screens/login_screen.dart';
import 'screens/notes_screen.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  NostrClient().init();
  AuthUser? user = await AuthService.loadUser();
  if (user != null) {
    // nsec private key is never stored on web — treat session as expired
    if (kIsWeb && user.signingMethod == SigningMethod.nsec) {
      user = null;
    } else {
      await _restoreSession(user);
    }
  }
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
    case SigningMethod.browserExtension:
      if (kIsWeb) SignerSession.set(Nip07EventSigner(pubkey: user.pubkey));
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
  List<String> _additionalRelays = [];

  @override
  void initState() {
    super.initState();
    _user = widget.initialUser;
    if (_user != null) {
      _refreshProfile();
      _refreshRelays();
      _initNotes();
    }
  }

  List<String> _mergedRelays() {
    if (_user == null) return [];
    return {..._user!.writeRelays, ..._additionalRelays}.toList();
  }

  Future<void> _initNotes() async {
    _additionalRelays = await AuthService.loadAdditionalRelays();
    if (mounted) setState(() {});
    await _loadNotes();
  }

  Future<void> _loadNotes() async {
    final signer = SignerSession.signer;
    if (signer == null) return;
    final db = kIsWeb ? null : AppDatabase.instance;
    await NoteCache.instance.loadAll(db, signer, _mergedRelays());
    NoteCache.instance.sync(showLoading: true);
  }

  Future<void> _onAdditionalRelaysChanged(List<String> relays) async {
    setState(() => _additionalRelays = relays);
    await AuthService.saveAdditionalRelays(relays);
    NoteCache.instance.updateWriteRelays(_mergedRelays());
    if (relays.isNotEmpty) {
      NoteCache.instance.retryAllFailed();
      NoteCache.instance.sync(showLoading: true);
    }
  }

  Future<void> _refreshProfile() async {
    final user = _user;
    if (user == null) return;
    final profile = await ProfileFetcher.fetch(user.pubkey);
    if (!mounted || _user == null) return;
    if (profile.name == user.name && profile.avatarUrl == user.avatarUrl) {
      return;
    }
    final updated = AuthUser(
      pubkey: user.pubkey,
      name: profile.name,
      avatarUrl: profile.avatarUrl,
      signingMethod: user.signingMethod,
      writeRelays: user.writeRelays,
    );
    await AuthService.save(updated);
    if (mounted) setState(() => _user = updated);
  }

  Future<void> _onLogin(AuthUser user) async {
    await AuthService.save(user);
    _additionalRelays = await AuthService.loadAdditionalRelays();
    setState(() => _user = user);
    _refreshRelays();
    _loadNotes();
  }

  Future<void> _refreshRelays() async {
    final user = _user;
    if (user == null) return;
    final relays = await RelayFetcher.fetchWriteRelays(user.pubkey);
    if (!mounted || _user == null) return;
    if (relays.isEmpty) {
      if (user.writeRelays.isEmpty && _additionalRelays.isEmpty) {
        NoteCache.instance.promptFallbackRelays.value = true;
      }
      return;
    }
    final current = user.writeRelays;
    if (relays.length == current.length && relays.every(current.contains)) {
      return;
    }
    final updated = AuthUser(
      pubkey: user.pubkey,
      name: user.name,
      avatarUrl: user.avatarUrl,
      signingMethod: user.signingMethod,
      writeRelays: relays,
    );
    await AuthService.save(updated);
    NoteCache.instance.updateWriteRelays([...relays, ..._additionalRelays]);
    NoteCache.instance.sync();
    if (mounted) setState(() => _user = updated);
  }

  Future<void> _onLogout() async {
    await NoteCache.instance.clear();
    SignerSession.clear();
    setState(() {
      _user = null;
      _additionalRelays = [];
    });
    await AuthService.clear();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Manent',
      builder: (context, child) {
        final isMobile = defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android;
        Widget result = isMobile
            ? MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(1.2),
                ),
                child: child!,
              )
            : child!;
        if (kIsWeb) {
          result = ColoredBox(
            color: const Color(0xFFAAAAAA),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: result,
              ),
            ),
          );
        }
        return result;
      },
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
        ),
        useMaterial3: true,
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: _user == null
          ? LoginScreen(onLogin: _onLogin)
          : NotesScreen(
              user: _user!,
              additionalRelays: _additionalRelays,
              onAdditionalRelaysChanged: _onAdditionalRelaysChanged,
              onLogout: _onLogout,
            ),
    );
  }
}
