import 'package:ndk/domain_layer/entities/nip_01_event.dart';
import 'package:ndk/domain_layer/repositories/event_signer.dart';

bool nip07Available() => false;

bool nip07SupportsNip44() => false;

Future<String> nip07GetPublicKey() =>
    throw UnsupportedError('NIP-07 is only available on web');

class Nip07EventSigner implements EventSigner {
  final String _pubkey;

  Nip07EventSigner({required String pubkey}) : _pubkey = pubkey;

  @override
  String getPublicKey() => _pubkey;

  @override
  bool canSign() => false;

  @override
  Future<Nip01Event> sign(Nip01Event event) =>
      throw UnsupportedError('NIP-07 is only available on web');

  @override
  @Deprecated('Use nip44 instead')
  Future<String?> encrypt(String msg, String destPubKey, {String? id}) async =>
      null;

  @override
  @Deprecated('Use nip44 instead')
  Future<String?> decrypt(String msg, String destPubKey, {String? id}) async =>
      null;

  @override
  Future<String?> encryptNip44({
    required String plaintext,
    required String recipientPubKey,
  }) =>
      throw UnsupportedError('NIP-07 is only available on web');

  @override
  Future<String?> decryptNip44({
    required String ciphertext,
    required String senderPubKey,
  }) =>
      throw UnsupportedError('NIP-07 is only available on web');
}
