import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:amberflutter/amberflutter.dart';
import 'package:ndk/shared/nips/nip19/nip19.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/amber_event_signer.dart';
import '../auth/auth_state.dart';
import '../auth/nip07_event_signer.dart';
import '../auth/profile_fetcher.dart';
import '../auth/signer_session.dart';
import '../theme.dart';
import '../widgets/manent_app_bar.dart';
import 'bunker_screen.dart';
import 'nsec_screen.dart';

class LoginScreen extends StatelessWidget {
  final Future<void> Function(AuthUser) onLogin;

  const LoginScreen({super.key, required this.onLogin});

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  Future<void> _loginWithBrowserExtension(BuildContext context) async {
    if (!nip07Available()) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No Nostr browser extension found')),
      );
      return;
    }
    if (!nip07SupportsNip44()) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Your extension does not support NIP-44 encryption, which is required by Manent',
          ),
        ),
      );
      return;
    }
    try {
      final pubkey = await nip07GetPublicKey();
      if (!context.mounted) return;
      SignerSession.set(Nip07EventSigner(pubkey: pubkey));
      final profile = await ProfileFetcher.fetch(pubkey);
      await onLogin(AuthUser(
        pubkey: pubkey,
        name: profile.name,
        avatarUrl: profile.avatarUrl,
        signingMethod: SigningMethod.browserExtension,
      ));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _loginWithAndroidSigner(BuildContext context) async {
    final amber = Amberflutter();
    final installed = await amber.isAppInstalled();
    if (!installed) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Amber signer app is not installed')),
      );
      return;
    }
    final result = await amber.getPublicKey(permissions: [
      const Permission(type: 'sign_event'),
      const Permission(type: 'nip44_encrypt'),
      const Permission(type: 'nip44_decrypt'),
    ]);
    final npub = result['signature'] as String? ?? '';
    if (npub.isEmpty || !context.mounted) return;
    final pubkey = Nip19.decode(npub);
    SignerSession.set(AmberEventSigner(pubkey: pubkey));
    final profile = await ProfileFetcher.fetch(pubkey);
    await onLogin(AuthUser(
      pubkey: pubkey,
      name: profile.name,
      avatarUrl: profile.avatarUrl,
      signingMethod: SigningMethod.androidSigner,
    ));
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
                'Manent allows you to share notes, securely encrypted, across your devices.\nKeep your ideas flow!',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, height: 1.3, color: Colors.black87),
              ),
              const SizedBox(height: 48),
              const Text(
                'Login with your Nostr account:',
                style: TextStyle(fontSize: 16, color: Colors.black87),
              ),
              const SizedBox(height: 24),
              if (kIsWeb && nip07Available()) ...[
                _Button(
                  label: 'Browser Extension',
                  onPressed: () => _loginWithBrowserExtension(context),
                ),
                const SizedBox(height: 16),
              ],
              _Button(
                label: 'Nostr Connect / Bunker',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => BunkerScreen(onLogin: onLogin)),
                ),
              ),
              if (_isAndroid) ...[
                const SizedBox(height: 16),
                _Button(
                  label: 'Android Signer',
                  onPressed: () => _loginWithAndroidSigner(context),
                ),
              ],
              const SizedBox(height: 24),
              Semantics(
                button: true,
                child: GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => NsecScreen(onLogin: onLogin)),
                  ),
                  child: const Text(
                    'Or use your nsec',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.black87,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.3),
                  children: [
                    const TextSpan(text: 'Are you new to Nostr? '),
                    TextSpan(
                      text: 'Read more',
                      style: const TextStyle(
                        color: accent,
                        decoration: TextDecoration.underline,
                        decorationColor: accent,
                      ),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () => launchUrl(
                              Uri.parse('https://njump.me'),
                              mode: LaunchMode.platformDefault,
                            ),
                    ),
                    const TextSpan(text: '\nabout the protocol or immediately\n'),
                    TextSpan(
                      text: 'create a free account',
                      style: const TextStyle(
                        color: accent,
                        decoration: TextDecoration.underline,
                        decorationColor: accent,
                      ),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () => launchUrl(
                              Uri.parse('https://nstart.me'),
                              mode: LaunchMode.platformDefault,
                            ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _Button({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          elevation: 0,
        ),
        child: Text(label, style: const TextStyle(fontSize: 16)),
      ),
    );
  }
}
