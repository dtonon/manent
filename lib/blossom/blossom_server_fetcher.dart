import 'package:ndk/ndk.dart';

import '../auth/nostr_client.dart';
import '../auth/relay_constants.dart';

class BlossomServerFetcher {
  // Fetches BUD-03 kind:10063 user server list.
  // Returns server URLs in tag order; returns empty list if none configured.
  static Future<List<String>> getServers(String pubkey) async {
    try {
      final response = NostrClient().ndk.requests.query(
            filter: Filter(
              authors: [pubkey],
              kinds: [10063],
              limit: 1,
            ),
            explicitRelays: discoveryRelays,
          );
      final events =
          await response.future.timeout(const Duration(seconds: 10));
      if (events.isEmpty) return [];
      return events.first.tags
          .where((t) => t.length >= 2 && t[0] == 'server')
          .map((t) => t[1])
          .toList();
    } catch (_) {
      return [];
    }
  }
}
