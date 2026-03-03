import 'package:ndk/ndk.dart';
import 'package:ndk/entities.dart' as entities;
import 'nostr_client.dart';
import 'relay_constants.dart';

class RelayFetcher {

  // Fetches NIP-65 kind:10002 and returns write relay URLs. Returns [] on any error.
  static Future<List<String>> fetchWriteRelays(String pubkey) async {
    try {
      final response = NostrClient().ndk.requests.query(
            filter: Filter(
              authors: [pubkey],
              kinds: [entities.Nip65.kKind],
              limit: 1,
            ),
            explicitRelays: discoveryRelays,
          );
      final events = await response.future.timeout(const Duration(seconds: 6));
      if (events.isEmpty) return [];
      final nip65 = entities.Nip65.fromEvent(events.first);
      return nip65.relays.entries
          .where((e) => e.value.isWrite)
          .map((e) => e.key)
          .toList();
    } catch (_) {
      return [];
    }
  }
}
