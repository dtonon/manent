import 'dart:js_interop';
import 'dart:convert';
import 'package:ndk/domain_layer/entities/nip_01_event.dart';
import 'package:ndk/domain_layer/repositories/event_signer.dart';

extension type _NostrJs._(JSObject _) implements JSObject {
  external JSPromise<JSString> getPublicKey();
  external JSPromise<JSAny> signEvent(JSAny event);
  external _Nip44Js? get nip44;
}

extension type _Nip44Js._(JSObject _) implements JSObject {
  external JSPromise<JSString> encrypt(JSString pubkey, JSString plaintext);
  external JSPromise<JSString> decrypt(JSString pubkey, JSString ciphertext);
}

extension type _JsonJs._(JSObject _) implements JSObject {
  external JSAny parse(JSString text);
  external JSString stringify(JSAny obj);
}

@JS('nostr')
external _NostrJs? get _nostr;

@JS('JSON')
external _JsonJs get _jsonJs;

bool nip07Available() => _nostr != null;

bool nip07SupportsNip44() => _nostr?.nip44 != null;

Future<String> nip07GetPublicKey() async {
  final nostr = _nostr ?? (throw Exception('window.nostr not available'));
  return (await nostr.getPublicKey().toDart).toDart;
}

class Nip07EventSigner implements EventSigner {
  final String _pubkey;

  Nip07EventSigner({required String pubkey}) : _pubkey = pubkey;

  @override
  String getPublicKey() => _pubkey;

  @override
  bool canSign() => true;

  @override
  Future<Nip01Event> sign(Nip01Event event) async {
    final nostr = _nostr ?? (throw Exception('window.nostr not available'));
    final jsEvent = _jsonJs.parse(jsonEncode({
      'pubkey': _pubkey,
      'created_at': event.createdAt,
      'kind': event.kind,
      'tags': event.tags,
      'content': event.content,
    }).toJS);
    final signed = await nostr.signEvent(jsEvent).toDart;
    final map =
        jsonDecode(_jsonJs.stringify(signed).toDart) as Map<String, dynamic>;
    return event.copyWith(id: map['id'] as String, sig: map['sig'] as String);
  }

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
  }) async {
    final nostr = _nostr ?? (throw Exception('window.nostr not available'));
    final nip44 = nostr.nip44 ??
        (throw Exception('NIP-44 not supported by this extension'));
    return (await nip44.encrypt(recipientPubKey.toJS, plaintext.toJS).toDart)
        .toDart;
  }

  @override
  Future<String?> decryptNip44({
    required String ciphertext,
    required String senderPubKey,
  }) async {
    final nostr = _nostr ?? (throw Exception('window.nostr not available'));
    final nip44 = nostr.nip44 ??
        (throw Exception('NIP-44 not supported by this extension'));
    return (await nip44.decrypt(senderPubKey.toJS, ciphertext.toJS).toDart)
        .toDart;
  }
}
