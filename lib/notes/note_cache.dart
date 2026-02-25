import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:ndk/domain_layer/entities/filter.dart';
import 'package:ndk/domain_layer/entities/nip_01_event.dart';
import 'package:ndk/domain_layer/repositories/event_signer.dart';

import '../auth/nostr_client.dart';
import 'local_crypto.dart';
import 'local_key_store.dart';
import 'note.dart';
import 'notes_database.dart';

class NoteCache {
  NoteCache._();
  static final instance = NoteCache._();

  final _map = <String, DecryptedNote>{};
  final notifier = ValueNotifier<List<DecryptedNote>>([]);

  AppDatabase? _db;
  EventSigner? _signer;
  List<String> _writeRelays = [];
  List<int>? _localKey;

  StreamSubscription<Nip01Event>? _relaySubscription;
  String? _relaySubId;

  List<DecryptedNote> get _sorted =>
      _map.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  void _emit() => notifier.value = _sorted;

  void updateWriteRelays(List<String> relays) => _writeRelays = relays;

  Future<void> loadAll(
      AppDatabase? db, EventSigner signer, List<String> writeRelays) async {
    _db = db;
    _signer = signer;
    _writeRelays = writeRelays;
    _localKey = await LocalKeyStore.loadOrCreate();
    _map.clear();

    if (_db == null) {
      _emit();
      return;
    }

    final rows = await _db!.getAll();
    for (final row in rows) {
      final id = row['id'] as String;
      final localEncoded = row['local_content'] as String?;
      String? text;

      if (localEncoded != null) {
        // Fast path — local AES key, no signer needed
        text = await LocalCrypto.decrypt(_localKey!, localEncoded);
      } else {
        // Migration path — event stored before local-key support, or pending retry
        final ciphertext = row['encrypted_content'] as String;
        if (ciphertext.isNotEmpty) {
          text = await _decryptViaSigner(signer, ciphertext);
          if (text != null) {
            final cached = await LocalCrypto.encrypt(_localKey!, text);
            await _db!.updateLocalContent(id, cached);
          }
        }
      }

      if (text == null) continue;
      _map[id] = DecryptedNote(
        id: id,
        nostrId: row['nostr_id'] as String?,
        text: text,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (row['created_at'] as int) * 1000),
        syncedToRelay: (row['synced_to_relay'] as int) == 1,
      );
    }
    _emit();
  }

  Future<void> add(String text) async {
    if (_localKey == null) return;

    final localContent = await LocalCrypto.encrypt(_localKey!, text);
    final id = _generateId();
    final now = DateTime.now();

    if (_db != null) {
      await _db!.insert(
        id: id,
        createdAt: now.millisecondsSinceEpoch ~/ 1000,
        localContent: localContent,
      );
    }

    _map[id] = DecryptedNote(
      id: id,
      text: text,
      createdAt: now,
      syncedToRelay: false,
    );
    _emit();

    _publishToRelays(id, text, now.millisecondsSinceEpoch ~/ 1000);
  }

  Future<void> _publishToRelays(
      String localId, String plaintext, int createdAt) async {
    if (_writeRelays.isEmpty || _signer == null) return;
    try {
      final encrypted = await _signer!.encryptNip44(
        plaintext: plaintext,
        recipientPubKey: _signer!.getPublicKey(),
      );
      if (encrypted == null) return;

      if (_db != null) {
        await _db!.updateEncryptedContent(
            localId: localId, encryptedContent: encrypted);
      }

      final event = Nip01Event(
        pubKey: _signer!.getPublicKey(),
        kind: 40001,
        tags: [],
        content: encrypted,
        createdAt: createdAt,
      );
      final signed = await _signer!.sign(event);
      // Update DB and in-memory map BEFORE broadcasting so the relay echo
      // is recognised as a duplicate in _onRelayEvent (both DB and web paths)
      if (_db != null) {
        await _db!.updateSynced(localId: localId, nostrId: signed.id);
      }
      final existing = _map[localId];
      if (existing != null) {
        _map[localId] = DecryptedNote(
          id: localId,
          nostrId: signed.id,
          text: existing.text,
          createdAt: existing.createdAt,
          syncedToRelay: true,
        );
        _emit();
      }
      await NostrClient()
          .ndk
          .broadcast
          .broadcast(nostrEvent: signed, specificRelays: _writeRelays)
          .broadcastDoneFuture;

      // Signer is working — retry events that couldn't be decrypted earlier
      _retryPendingDecryptions();
    } catch (_) {
      // Will retry on next sync pass
    }
  }

  Future<void> sync() async {
    if (_writeRelays.isEmpty || _signer == null) return;

    await _cancelRelaySubscription();

    final since = _db != null ? await _db!.getLatestCreatedAt() : null;

    final response = NostrClient().ndk.requests.subscription(
      filter: Filter(
        kinds: [40001],
        authors: [_signer!.getPublicKey()],
        since: since,
      ),
      explicitRelays: _writeRelays,
    );

    _relaySubId = response.requestId;
    _relaySubscription = response.stream.listen(_onRelayEvent);

    // After relays have sent historical events, retry any that failed to decrypt
    Future.delayed(const Duration(seconds: 5), _retryPendingDecryptions);
  }

  Future<void> _onRelayEvent(Nip01Event event) async {
    if (_signer == null || _localKey == null) return;

    // Dedup: prefer DB check; fall back to in-memory map on web
    if (_db != null) {
      if (await _db!.existsByNostrId(event.id)) return;
    } else {
      if (_map.values.any((n) => n.nostrId == event.id)) return;
    }

    final text = await _decryptViaSigner(_signer!, event.content);
    final localContent =
        text != null ? await LocalCrypto.encrypt(_localKey!, text) : null;
    final localId = _generateId();

    if (_db != null) {
      await _db!.insertSynced(
        id: localId,
        nostrId: event.id,
        createdAt: event.createdAt,
        encryptedContent: event.content,
        localContent: localContent,
      );
    }

    if (text != null) {
      _map[localId] = DecryptedNote(
        id: localId,
        nostrId: event.id,
        text: text,
        createdAt: DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
        syncedToRelay: true,
      );
      _emit();
    }
  }

  // Retries decryption for events stored encrypted-only (local_content is null).
  // Called after a successful signer operation proves the session is alive.
  Future<void> _retryPendingDecryptions() async {
    if (_db == null || _signer == null || _localKey == null) return; // no-op on web

    final rows = await _db!.getAll();
    int retried = 0;

    for (final row in rows) {
      if (row['local_content'] != null) continue;
      final ciphertext = row['encrypted_content'] as String;
      if (ciphertext.isEmpty) continue;

      final id = row['id'] as String;
      if (_map.containsKey(id)) continue;

      final text = await _decryptViaSigner(_signer!, ciphertext);
      if (text == null) continue;

      final localContent = await LocalCrypto.encrypt(_localKey!, text);
      await _db!.updateLocalContent(id, localContent);

      _map[id] = DecryptedNote(
        id: id,
        nostrId: row['nostr_id'] as String?,
        text: text,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (row['created_at'] as int) * 1000),
        syncedToRelay: (row['synced_to_relay'] as int) == 1,
      );
      retried++;
    }

    if (retried > 0) _emit();
  }

  Future<void> _cancelRelaySubscription() async {
    await _relaySubscription?.cancel();
    _relaySubscription = null;
    if (_relaySubId != null) {
      await NostrClient().ndk.requests.closeSubscription(_relaySubId!);
      _relaySubId = null;
    }
  }

  Future<void> delete(String id) async {
    if (_db != null) await _db!.delete(id);
    _map.remove(id);
    _emit();
  }

  Future<void> clear() async {
    await _cancelRelaySubscription();
    _db = null;
    _signer = null;
    _writeRelays = [];
    _localKey = null;
    _map.clear();
    notifier.value = [];
  }

  Future<String?> _decryptViaSigner(
      EventSigner signer, String ciphertext) async {
    try {
      return await signer.decryptNip44(
        ciphertext: ciphertext,
        senderPubKey: signer.getPublicKey(),
      );
    } catch (_) {
      return null;
    }
  }

  String _generateId() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final rand = Random.secure().nextInt(0xFFFFFF);
    return '${ts.toRadixString(16)}${rand.toRadixString(16).padLeft(6, '0')}';
  }
}
