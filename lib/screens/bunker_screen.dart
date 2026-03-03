import 'dart:async';
import 'dart:convert';
import 'dart:math';

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
  // relay.nsec.app is the dedicated NIP-46 relay — accepts kind 24133 subscriptions
  // without restrictive filter policies. relay.damus.io may send CLOSED for
  // broad kind 24133 subscriptions without an authors filter.
  static const _nostrConnectRelays = [
    'wss://relay.primal.net',
    'wss://relay.nsec.app',
    'wss://nostr.oxtr.dev',
  ];

  // NDK's secret is base64 with '==' padding — signer URL parsers split on '=' producing garbage.
  // Generate a hex secret (no special chars) and use it in the URL and handshake.
  static String _makeSecret() {
    const hex = '0123456789abcdef';
    final r = Random.secure();
    return List.generate(32, (_) => hex[r.nextInt(16)]).join();
  }

  final _secret = _makeSecret();

  final _nostrConnect = NostrConnect(
    relays: _nostrConnectRelays,
    appName: 'Manent',
    perms: ['get_public_key', 'nip44_decrypt', 'nip44_encrypt', 'sign_event:33301', 'sign_event:5'],
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

  void _waitForNostrConnect() async {
    try {
      final connection = await _nostrConnectHandshake();
      if (connection == null && mounted && !_done) {
        setState(() => _error =
            'Relay closed the subscription. Try entering a bunker:// URL instead.');
        return;
      }
      await _onConnected(connection);
    } catch (e, s) {
      _onError(e, s);
    }
  }

  Future<BunkerConnection?> _nostrConnectHandshake() async {
    final keypair = _nostrConnect.keyPair;
    final secret = _secret;
    final relays = _nostrConnect.relays;
    final localSigner = Bip340EventSigner(
        privateKey: keypair.privateKey, publicKey: keypair.publicKey);
    final sub = NostrClient().ndk.requests.subscription(
          explicitRelays: relays,
          filter: Filter(
              kinds: [24133],
              pTags: [keypair.publicKey],
              since: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 300),
        );

    // Tracks state for legacy flow: after signer sends result==secret,
    // we send a connect RPC and wait for the signer's ack on the same stream.
    String? pendingConnectId;
    String? pendingSignerPubkey;

    try {
      await for (final event
          in sub.stream.timeout(const Duration(seconds: 600))) {
        try {
          final plain = await localSigner.decryptNip44(
              ciphertext: event.content, senderPubKey: event.pubKey);
          if (plain == null) continue;
          final data = jsonDecode(plain) as Map<String, dynamic>;

          // Legacy phase 2: waiting for signer's ack to our connect RPC
          if (pendingConnectId != null) {
            if (data['id'] == pendingConnectId && data['result'] == 'ack') {
              return BunkerConnection(
                  privateKey: keypair.privateKey!,
                  remotePubkey: pendingSignerPubkey!,
                  relays: relays);
            }
            continue;
          }

          // Modern NIP-46: signer sends connect request, we ack
          if (data['method'] == 'connect') {
            final params = data['params'] as List?;
            if (params != null &&
                params.length >= 2 &&
                params[1].toString() == secret) {
              final signerPubkey = params[0].toString();
              await _sendAck(localSigner, data['id']?.toString() ?? '',
                  signerPubkey, relays);
              return BunkerConnection(
                  privateKey: keypair.privateKey!,
                  remotePubkey: signerPubkey,
                  relays: relays);
            }
            continue;
          }

          // Legacy phase 1: signer sends result==secret, we follow up with a connect RPC
          if (data['result']?.toString() == secret) {
            pendingSignerPubkey = event.pubKey;
            pendingConnectId = await _sendConnectRpc(
                localSigner, event.pubKey, secret, relays);
          }
        } catch (_) {
          continue;
        }
      }
    } finally {
      NostrClient().ndk.requests.closeSubscription(sub.requestId);
    }
    return null;
  }

  Future<void> _sendAck(Bip340EventSigner signer, String requestId,
      String signerPubkey, List<String> relays) async {
    await _broadcastEncrypted(
        signer,
        jsonEncode({'id': requestId, 'result': 'ack', 'error': ''}),
        signerPubkey,
        relays);
  }

  Future<String> _sendConnectRpc(Bip340EventSigner signer, String signerPubkey,
      String secret, List<String> relays) async {
    final id = _secret.substring(0, 16);
    await _broadcastEncrypted(
        signer,
        jsonEncode({
          'id': id,
          'method': 'connect',
          // Third param requests specific permissions from the bunker
          'params': [
            signerPubkey,
            secret,
            'get_public_key,nip44_decrypt,nip44_encrypt,sign_event:33301,sign_event:5'
          ]
        }),
        signerPubkey,
        relays);
    return id;
  }

  Future<void> _broadcastEncrypted(Bip340EventSigner signer, String payload,
      String recipientPubkey, List<String> relays) async {
    final encrypted = await signer.encryptNip44(
        plaintext: payload, recipientPubKey: recipientPubkey);
    if (encrypted == null) return;
    final event = Nip01Event(
        pubKey: signer.publicKey,
        kind: 24133,
        tags: [
          ['p', recipientPubkey]
        ],
        content: encrypted);
    NostrClient().ndk.broadcast.broadcast(
        nostrEvent: await signer.sign(event), specificRelays: relays);
  }

  // Build URL with our hex secret — NDK's secret is base64 with '==' which signer parsers mangle.
  String get _nostrConnectURL {
    final pubkey = _nostrConnect.keyPair.publicKey;
    final params = <String>[];
    for (final relay in _nostrConnect.relays) {
      params.add('relay=${Uri.encodeComponent(relay)}');
    }
    params.add('secret=$_secret');
    if (_nostrConnect.perms != null && _nostrConnect.perms!.isNotEmpty) {
      params.add('perms=${_nostrConnect.perms!.join(',')}');
    }
    params.add('name=Manent');
    return 'nostrconnect://$pubkey?${params.join('&')}';
  }

  bool get _canLogin =>
      !_connectingWithUrl &&
      _bunkerController.text.trim().startsWith('bunker://');

  Future<void> _loginWithBunkerUrl() async {
    setState(() {
      _connectingWithUrl = true;
      _error = null;
    });
    try {
      final connection = await NostrClient()
          .ndk
          .bunkers
          .connectWithBunkerUrl(_bunkerController.text.trim())
          .timeout(const Duration(seconds: 30));
      await _onConnected(connection);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _friendlyError(e);
          _connectingWithUrl = false;
        });
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
        setState(() {
          _error = _friendlyError(e);
          _connectingWithUrl = false;
        });
      }
    }
  }

  void _onError(Object e, StackTrace _) {
    if (!mounted || _done) return;
    setState(() {
      _error = _friendlyError(e);
    });
  }

  String _friendlyError(Object e) {
    if (e is TimeoutException) {
      return 'Connection timed out. Your signer may have rejected the request or is unreachable.';
    }
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
                style:
                    TextStyle(fontSize: 16, height: 1.3, color: Colors.black87),
              ),
              const SizedBox(height: 32),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: Semantics(
                  label: 'Nostr Connect QR code — scan with your signer app',
                  image: true,
                  child: QrImageView(
                    data: _nostrConnectURL,
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
