import 'package:ndk/ndk.dart';

import '../notes/ndk_log_output.dart';

// Skips expensive sig verification for kinds we control:
// - 33301, 33302: NIP-44 encryption already authenticates content
// - 5: subscription filters by our own pubkey; deletion handler checks _map
class _ManentEventVerifier implements EventVerifier {
  final EventVerifier _delegate = Bip340EventVerifier();

  static const _trustedKinds = {33301, 33302, 5, 22242};

  @override
  Future<bool> verify(Nip01Event event) {
    if (_trustedKinds.contains(event.kind)) return Future.value(true);
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
    Logger.log.addOutput(SyncDiagnosticsLogOutput());
    ndk = Ndk(NdkConfig(
      cache: MemCacheManager(),
      eventVerifier: _ManentEventVerifier(),
      bootstrapRelays: [],
    ));
  }
}
