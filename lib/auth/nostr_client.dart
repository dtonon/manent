import 'package:ndk/ndk.dart';

// Singleton NDK instance used for relay operations (NIP-46 bunker connections)
class NostrClient {
  static final NostrClient _instance = NostrClient._();
  factory NostrClient() => _instance;
  NostrClient._();

  late final Ndk ndk;

  void init() {
    ndk = Ndk.emptyBootstrapRelaysConfig();
  }
}
