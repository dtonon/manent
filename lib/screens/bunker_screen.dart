import 'package:flutter/material.dart';
import 'package:ndk/ndk.dart';
import 'package:ndk/data_layer/repositories/signers/nip46_event_signer.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../auth/auth_state.dart';
import '../auth/nostr_client.dart';
import '../auth/profile_fetcher.dart';
import '../auth/signer_session.dart';
import '../auth/signer_store.dart';
import '../theme.dart';
import '../widgets/manent_app_bar.dart';

class BunkerScreen extends StatefulWidget {
  final Future<void> Function(AuthUser) onLogin;

  const BunkerScreen({super.key, required this.onLogin});

  @override
  State<BunkerScreen> createState() => _BunkerScreenState();
}

class _BunkerScreenState extends State<BunkerScreen> {
  final _bunkerController = TextEditingController();
  // Client-initiated connection — used for the QR code
  final _nostrConnect = NostrConnect(
    relays: ['wss://relay.damus.io'],
    appName: 'Manent',
    perms: ['nip44_encrypt', 'nip44_decrypt'],
  );

  bool _connectingWithUrl = false;
  String? _error;
  // Prevents double-login if both flows resolve simultaneously
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _bunkerController.addListener(() => setState(() {}));
    _waitForNostrConnect();
  }

  // Start listening for a signer scanning the QR code
  void _waitForNostrConnect() {
    NostrClient().ndk.bunkers
        .connectWithNostrConnect(_nostrConnect)
        .then(_onConnected)
        .catchError(_onError);
  }

  bool get _canLogin =>
      !_connectingWithUrl && _bunkerController.text.trim().startsWith('bunker://');

  Future<void> _loginWithBunkerUrl() async {
    setState(() { _connectingWithUrl = true; _error = null; });
    try {
      final connection = await NostrClient().ndk.bunkers
          .connectWithBunkerUrl(_bunkerController.text.trim());
      await _onConnected(connection);
    } catch (e) {
      if (mounted) {
        setState(() { _error = _friendlyError(e); _connectingWithUrl = false; });
      }
    }
  }

  Future<void> _onConnected(BunkerConnection? connection) async {
    if (_done || !mounted || connection == null) return;
    _done = true;
    try {
      final ndk = NostrClient().ndk;
      final Nip46EventSigner signer = ndk.bunkers.createSigner(connection);
      final pubkey = await signer.getPublicKeyAsync();
      await SignerStore.saveBunkerConnection(connection.toJson());
      SignerSession.set(signer);
      final profile = await ProfileFetcher.fetch(pubkey);
      final user = AuthUser(
        pubkey: pubkey,
        name: profile.name,
        avatarUrl: profile.avatarUrl,
        signingMethod: SigningMethod.bunker,
      );
      await widget.onLogin(user);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      _done = false;
      if (mounted) {
        setState(() { _error = _friendlyError(e); _connectingWithUrl = false; });
      }
    }
  }

  void _onError(Object e, StackTrace _) {
    if (!mounted || _done) return;
    setState(() { _error = _friendlyError(e); });
  }

  String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains('Invalid payload size') ||
        msg.contains('invalid padding')) {
      return 'This signer uses NIP-04 encryption, which is not supported. Use a NIP-44 compatible signer.';
    }
    return msg;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: background,
      appBar: manentAppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 60),
          child: Column(
            children: [
              const Spacer(),
              const Text(
                'Scan the QR Code with your signer app or enter a bunker URL',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, height: 1.3, color: Colors.black87),
              ),
              const SizedBox(height: 32),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: Semantics(
                  label: 'Nostr Connect QR code — scan with your signer app',
                  image: true,
                  child: QrImageView(
                    data: _nostrConnect.nostrConnectURL,
                    size: 260,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Waiting for signer to scan…',
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _bunkerController,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  hintText: 'bunker://....',
                  hintStyle: TextStyle(color: Colors.grey[400]),
                  filled: true,
                  fillColor: Colors.white,
                  hoverColor: Colors.transparent,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(fontSize: 13, color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _canLogin ? _loginWithBunkerUrl : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: accent.withValues(alpha: 0.4),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                  child: _connectingWithUrl
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text('Login', style: TextStyle(fontSize: 16)),
                ),
              ),
              const Spacer(),
              Semantics(
                button: true,
                child: GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: const Text(
                    'Go back to the login screen',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.black87,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _bunkerController.dispose();
    super.dispose();
  }
}
