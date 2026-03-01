import 'package:ndk/ndk.dart';

// Skips expensive sig verification for kinds we control:
// - 33301: NIP-44 encryption already authenticates content
// - 5: subscription filters by our own pubkey; deletion handler checks _map
class _ManentEventVerifier implements EventVerifier {
  final EventVerifier _delegate = Bip340EventVerifier();

  @override
  Future<bool> verify(Nip01Event event) {
    if (event.kind == 33301 || event.kind == 5) return Future.value(true);
    return _delegate.verify(event);
  }
}

// Singleton NDK instance used for relay operations (NIP-46 bunker connections)
class NostrClient {
  static final NostrClient _instance = NostrClient._();
  factory NostrClient() => _instance;
  NostrClient._();

  late final Ndk ndk;

  void init() {
    ndk = Ndk(NdkConfig(
      cache: MemCacheManager(),
      eventVerifier: _ManentEventVerifier(),
      bootstrapRelays: [],
    ));
  }
}
