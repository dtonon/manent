import 'package:flutter/material.dart';
import 'package:ndk/ndk.dart';
import 'package:ndk/shared/nips/nip01/bip340.dart';

import '../auth/auth_state.dart';
import '../auth/profile_fetcher.dart';
import '../auth/signer_session.dart';
import '../auth/signer_store.dart';
import '../theme.dart';
import '../widgets/manent_app_bar.dart';

class NsecScreen extends StatefulWidget {
  final Future<void> Function(AuthUser) onLogin;

  const NsecScreen({super.key, required this.onLogin});

  @override
  State<NsecScreen> createState() => _NsecScreenState();
}

class _NsecScreenState extends State<NsecScreen> {
  final _nsecController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nsecController.addListener(() => setState(() {}));
  }

  bool get _canLogin =>
      !_loading && Nip19.isPrivateKey(_nsecController.text.trim());

  Future<void> _login() async {
    final text = _nsecController.text.trim();
    setState(() { _loading = true; _error = null; });
    try {
      final privkey = Nip19.decode(text);
      if (privkey.isEmpty) throw 'decode failed';
      final pubkey = Bip340.getPublicKey(privkey);
      await SignerStore.saveNsecPrivkey(privkey);
      SignerSession.set(Bip340EventSigner(privateKey: privkey, publicKey: pubkey));
      final profile = await ProfileFetcher.fetch(pubkey);
      final user = AuthUser(
        pubkey: pubkey,
        name: profile.name,
        avatarUrl: profile.avatarUrl,
        signingMethod: SigningMethod.nsec,
      );
      await widget.onLogin(user);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (_) {
      if (mounted) {
        setState(() { _error = 'Invalid nsec key'; _loading = false; });
      }
    }
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
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(),
              const Text(
                'Enter your nsec\nNote: this option is not suggested, using a bunker or a signer is the preferred solution',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.black87),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _nsecController,
                minLines: 4,
                maxLines: 6,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  hintText: 'nsec1....',
                  hintStyle: TextStyle(color: Colors.grey[400]),
                  filled: true,
                  fillColor: Colors.white,
                  hoverColor: Colors.transparent,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.all(16),
                  alignLabelWithHint: true,
                ),
                style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(fontSize: 14, color: Colors.red),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _canLogin ? _login : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: accent.withValues(alpha: 0.4),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                  child: _loading
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
    _nsecController.dispose();
    super.dispose();
  }
}
