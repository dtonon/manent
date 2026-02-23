import 'dart:convert';
import 'package:amberflutter/amberflutter.dart';
import 'package:ndk/domain_layer/entities/nip_01_event.dart';
import 'package:ndk/domain_layer/repositories/event_signer.dart';

// EventSigner implementation that delegates all crypto ops to the Amber Android signer app
class AmberEventSigner implements EventSigner {
  final String _pubkey;
  final _amber = Amberflutter();

  AmberEventSigner({required String pubkey}) : _pubkey = pubkey;

  @override
  String getPublicKey() => _pubkey;

  @override
  bool canSign() => true;

  @override
  Future<Nip01Event> sign(Nip01Event event) async {
    final eventMap = {
      'pubkey': _pubkey,
      'created_at': event.createdAt,
      'kind': event.kind,
      'tags': event.tags,
      'content': event.content,
    };
    final result = await _amber.signEvent(
      currentUser: _pubkey,
      eventJson: jsonEncode(eventMap),
    );
    return event.copyWith(
      id: result['id'] as String,
      sig: result['signature'] as String,
    );
  }

  @override
  @Deprecated('Use nip44 instead')
  Future<String?> encrypt(String msg, String destPubKey, {String? id}) async {
    final result = await _amber.nip04Encrypt(
      plaintext: msg,
      currentUser: _pubkey,
      pubKey: destPubKey,
    );
    return result['result'] as String?;
  }

  @override
  @Deprecated('Use nip44 instead')
  Future<String?> decrypt(String msg, String destPubKey, {String? id}) async {
    final result = await _amber.nip04Decrypt(
      ciphertext: msg,
      currentUser: _pubkey,
      pubKey: destPubKey,
    );
    return result['result'] as String?;
  }

  @override
  Future<String?> encryptNip44({
    required String plaintext,
    required String recipientPubKey,
  }) async {
    final result = await _amber.nip44Encrypt(
      plaintext: plaintext,
      currentUser: _pubkey,
      pubKey: recipientPubKey,
    );
    return result['result'] as String?;
  }

  @override
  Future<String?> decryptNip44({
    required String ciphertext,
    required String senderPubKey,
  }) async {
    final result = await _amber.nip44Decrypt(
      ciphertext: ciphertext,
      currentUser: _pubkey,
      pubKey: senderPubKey,
    );
    return result['result'] as String?;
  }
}
