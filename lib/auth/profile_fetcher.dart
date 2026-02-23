import 'dart:convert';
import 'package:ndk/ndk.dart';
import 'nostr_client.dart';

class ProfileFetcher {
  static const _relays = [
    'wss://relay.damus.io',
    'wss://relay.nostr.band',
    'wss://nos.lol',
  ];

  // Fetches NIP-01 kind:0 metadata. Falls back to truncated pubkey on any error.
  static Future<({String name, String? avatarUrl})> fetch(String pubkey) async {
    try {
      final response = NostrClient().ndk.requests.query(
        filter: Filter(authors: [pubkey], kinds: [0], limit: 1),
        explicitRelays: _relays,
      );
      final events =
          await response.future.timeout(const Duration(seconds: 6));
      if (events.isEmpty) return _fallback(pubkey);
      final content =
          jsonDecode(events.first.content) as Map<String, dynamic>;
      final name = ((content['name'] as String?)?.trim().isNotEmpty == true
              ? content['name'] as String
              : (content['display_name'] as String?)?.trim())
          ?.trim();
      final avatarUrl = content['picture'] as String?;
      return (
        name: (name?.isNotEmpty == true) ? name! : pubkey.substring(0, 8),
        avatarUrl: avatarUrl,
      );
    } catch (_) {
      return _fallback(pubkey);
    }
  }

  static ({String name, String? avatarUrl}) _fallback(String pubkey) =>
      (name: pubkey.substring(0, 8), avatarUrl: null);
}
