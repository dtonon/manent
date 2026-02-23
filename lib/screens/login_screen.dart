import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:url_launcher/url_launcher.dart';

import '../auth/auth_state.dart';
import '../theme.dart';
import '../widgets/manent_app_bar.dart';
import 'bunker_screen.dart';
import 'nsec_screen.dart';

class LoginScreen extends StatelessWidget {
  final Future<void> Function(AuthUser) onLogin;

  const LoginScreen({super.key, required this.onLogin});

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

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
                  onPressed: () async => onLogin(AuthUser.fake()),
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
