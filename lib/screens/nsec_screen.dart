import 'package:flutter/material.dart';

import '../auth/auth_state.dart';
import '../widgets/manent_app_bar.dart';

class NsecScreen extends StatefulWidget {
  final Future<void> Function(AuthUser) onLogin;

  const NsecScreen({super.key, required this.onLogin});

  @override
  State<NsecScreen> createState() => _NsecScreenState();
}

class _NsecScreenState extends State<NsecScreen> {
  final _nsecController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _nsecController.addListener(() => setState(() {}));
  }

  bool get _canLogin => _nsecController.text.trim().isNotEmpty;

  Future<void> _login() async {
    await widget.onLogin(AuthUser.fake());
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    const pink = Color(0xFFe32a6d);
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
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
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _canLogin ? _login : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: pink,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: pink.withOpacity(0.4),
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
    _nsecController.dispose();
    super.dispose();
  }
}
