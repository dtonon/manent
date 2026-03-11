import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ndk/ndk.dart';
import 'package:window_manager/window_manager.dart';
import 'package:ndk/shared/nips/nip01/bip340.dart';
import 'package:ndk/data_layer/repositories/signers/nip46_event_signer.dart';

import 'app_flavor.dart';
import 'auth/amber_event_signer.dart';
import 'auth/nip07_event_signer.dart';
import 'auth/auth_state.dart';
import 'auth/nostr_client.dart';
import 'auth/profile_fetcher.dart';
import 'auth/relay_fetcher.dart';
import 'blossom/blossom_server_fetcher.dart';
import 'auth/signer_session.dart';
import 'auth/signer_store.dart';
import 'notes/note_cache.dart';
import 'notes/notes_database.dart';
import 'screens/login_screen.dart';
import 'screens/notes_screen.dart';
import 'theme.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  if (args.firstOrNull == 'multi_window') {
    await windowManager.ensureInitialized();
    final controller = await WindowController.fromCurrentEngine();
    final argument = jsonDecode(controller.arguments) as Map<String, dynamic>;
    final filePath = argument['path'] as String;
    final filename = argument['filename'] as String;
    const options = WindowOptions(
      size: Size(900, 700),
      center: true,
      backgroundColor: Colors.black,
    );
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setTitle(filename);
      await windowManager.show();
      await windowManager.focus();
    });
    runApp(_ImageViewerApp(filePath: filePath, filename: filename));
    return;
  }

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
  List<String> _blossomServers = [];

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
    _blossomServers = await AuthService.loadBlossomServers();
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
    final relaysFuture = RelayFetcher.fetchWriteRelays(user.pubkey);
    final blossomFuture = BlossomServerFetcher.getServers(user.pubkey);
    final relays = await relaysFuture;
    final fetchedBlossom = await blossomFuture;
    // Both futures run concurrently since we started them before awaiting
    // Prefer kind:10063 servers; fall back to user-saved servers
    final effectiveBlossom =
        fetchedBlossom.isNotEmpty ? fetchedBlossom : _blossomServers;
    NoteCache.instance.updateBlossomServers(effectiveBlossom);
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

  Future<void> _onBlossomServersChanged(List<String> servers) async {
    setState(() => _blossomServers = servers);
    await AuthService.saveBlossomServers(servers);
    NoteCache.instance.updateBlossomServers(servers);
  }

  Future<void> _onLogout() async {
    await NoteCache.instance.clear();
    SignerSession.clear();
    setState(() {
      _user = null;
      _additionalRelays = [];
      _blossomServers = [];
    });
    await AuthService.clear();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppFlavor.appName,
      builder: (context, child) {
        final isMobile = defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android;
        Widget result = isMobile
            ? MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(1.2),
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
              blossomServers: _blossomServers,
              onBlossomServersChanged: _onBlossomServersChanged,
              onLogout: _onLogout,
            ),
    );
  }
}

class _ImageViewerApp extends StatefulWidget {
  final String filePath;
  final String filename;

  const _ImageViewerApp({required this.filePath, required this.filename});

  @override
  State<_ImageViewerApp> createState() => _ImageViewerAppState();
}

class _ImageViewerAppState extends State<_ImageViewerApp> {
  Uint8List? _bytes;
  late String _filename;

  @override
  void initState() {
    super.initState();
    _filename = widget.filename;
    _load(widget.filePath);
    _setupMethodHandler();
  }

  Future<void> _load(String path) async {
    final b = await File(path).readAsBytes();
    if (mounted) setState(() => _bytes = b);
  }

  Future<void> _setupMethodHandler() async {
    final controller = await WindowController.fromCurrentEngine();
    await controller.setWindowMethodHandler((call) async {
      if (call.method == 'loadImage') {
        final data =
            jsonDecode(call.arguments as String) as Map<String, dynamic>;
        if (mounted) setState(() => _filename = data['filename'] as String);
        await windowManager.setTitle(data['filename'] as String);
        await windowManager.show();
        await windowManager.focus();
        _load(data['path'] as String);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            windowManager.close();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: _bytes != null
              ? InteractiveViewer(
                  minScale: 0.1,
                  maxScale: 10.0,
                  child: Center(
                    child: Image.memory(
                      _bytes!,
                      fit: BoxFit.contain,
                      semanticLabel: _filename,
                    ),
                  ),
                )
              : const Center(child: CircularProgressIndicator()),
        ),
      ),
    );
  }
}
