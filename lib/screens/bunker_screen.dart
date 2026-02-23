import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../auth/auth_state.dart';
import '../theme.dart';
import '../widgets/manent_app_bar.dart';

// Fake nostrconnect:// URI shown while real NIP-46 logic is not yet implemented
const _fakeNostrConnectUri =
    'nostrconnect://fakepubkey0000000000000000000000000000000000000000000000000000'
    '?relay=wss%3A%2F%2Frelay.damus.io&secret=fakesecret0000000000000000000000000';

class BunkerScreen extends StatefulWidget {
  final Future<void> Function(AuthUser) onLogin;

  const BunkerScreen({super.key, required this.onLogin});

  @override
  State<BunkerScreen> createState() => _BunkerScreenState();
}

class _BunkerScreenState extends State<BunkerScreen> {
  final _bunkerController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _bunkerController.addListener(() => setState(() {}));
  }

  bool get _canLogin => _bunkerController.text.trim().isNotEmpty;

  Future<void> _login() async {
    await widget.onLogin(AuthUser.fake());
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
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
                    data: _fakeNostrConnectUri,
                    size: 260,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _bunkerController,
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
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _canLogin ? _login : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: accent.withOpacity(0.4),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                  child: const Text('Login', style: TextStyle(fontSize: 16)),
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
