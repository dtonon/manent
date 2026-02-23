import 'package:ndk/ndk.dart';

// Holds the active EventSigner for the current session
class SignerSession {
  static EventSigner? _signer;
  static EventSigner? get signer => _signer;

  static void set(EventSigner signer) => _signer = signer;
  static void clear() => _signer = null;
}
