import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:ndk/data_layer/repositories/verifiers/bip340_event_verifier.dart';
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
  final _pendingDeletions = <String>{};
  final _verifier = Bip340EventVerifier();

  List<DecryptedNote> get _sorted =>
      _map.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  void _emit() => notifier.value = _sorted;

  void updateWriteRelays(List<String> relays) => _writeRelays = relays;

  Future<void> loadAll(
      AppDatabase? db, EventSigner signer, List<String> writeRelays) async {
    try {
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
        String? errorMsg;

        if (localEncoded != null) {
          // Fast path — local AES key, no signer needed
          text = await LocalCrypto.decrypt(_localKey!, localEncoded);
          if (text == null) {
            errorMsg = 'The local decryption failed.';
          }
        } else {
          // Migration path — event stored before local-key support, or pending retry
          final ciphertext = row['encrypted_content'] as String;
          if (ciphertext.isNotEmpty) {
            final result = await _decryptViaSigner(signer, ciphertext);
            text = result.text;
            if (text != null) {
              final cached = await LocalCrypto.encrypt(_localKey!, text);
              await _db!.updateLocalContent(id, cached);
            } else {
              errorMsg =
                  'The remote decryption failed with the error "${result.error}".';
            }
          }
        }

        if (text == null && errorMsg == null) continue;
        final editedAtRaw = row['edited_at'] as int?;
        _map[id] = DecryptedNote(
          id: id,
          nostrId: row['nostr_id'] as String?,
          text: text ?? '',
          error: errorMsg,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
              (row['created_at'] as int) * 1000),
          editedAt: editedAtRaw != null
              ? DateTime.fromMillisecondsSinceEpoch(editedAtRaw * 1000)
              : null,
          syncStatus: SyncStatus.fromInt(row['synced_to_relay'] as int),
        );
      }
      _emit();
    } catch (_) {
      _emit();
    }
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
      syncStatus: SyncStatus.pending,
    );
    _emit();

    _publishToRelays(id, text, now.millisecondsSinceEpoch ~/ 1000);
  }

  Future<void> update(String id, String newText) async {
    if (_localKey == null) return;
    final existing = _map[id];
    if (existing == null || existing.error != null) return;

    final editedAt = DateTime.now();
    final editedAtSeconds = editedAt.millisecondsSinceEpoch ~/ 1000;
    final localContent = await LocalCrypto.encrypt(_localKey!, newText);

    if (_db != null) {
      await _db!.updateForEdit(
        id: id,
        localContent: localContent,
        editedAt: editedAtSeconds,
      );
    }

    _map[id] = DecryptedNote(
      id: id,
      nostrId: existing.nostrId,
      text: newText,
      createdAt: existing.createdAt,
      editedAt: editedAt,
      syncStatus: SyncStatus.pending,
    );
    _emit();

    _publishToRelays(id, newText, editedAtSeconds);
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
        kind: 33301,
        tags: [
          ['d', localId]
        ],
        content: encrypted,
        createdAt: createdAt,
      );
      final signed = await _signer!.sign(event);

      // Set nostrId BEFORE broadcasting so the relay echo is recognised
      // as a duplicate in _onRelayEvent; sync status stays pending until result
      if (_db != null) {
        await _db!.updateNostrId(localId: localId, nostrId: signed.id);
      }
      final existing = _map[localId];
      if (existing != null) {
        _map[localId] = DecryptedNote(
          id: localId,
          nostrId: signed.id,
          text: existing.text,
          createdAt: existing.createdAt,
          syncStatus: SyncStatus.pending,
        );
      }

      final responses = await NostrClient()
          .ndk
          .broadcast
          .broadcast(nostrEvent: signed, specificRelays: _writeRelays)
          .broadcastDoneFuture;

      final newStatus = responses.any((r) => r.broadcastSuccessful)
          ? SyncStatus.synced
          : SyncStatus.failed;

      if (_db != null) {
        await _db!.updateSyncStatus(localId, newStatus.value);
      }
      final updated = _map[localId];
      if (updated != null) {
        _map[localId] = DecryptedNote(
          id: localId,
          nostrId: updated.nostrId,
          text: updated.text,
          createdAt: updated.createdAt,
          syncStatus: newStatus,
        );
        _emit();
      }

      _retryPendingDecryptions();
    } catch (_) {
      if (_db != null) await _db!.updateSyncStatus(localId, SyncStatus.failed.value);
      final existing = _map[localId];
      if (existing != null) {
        _map[localId] = DecryptedNote(
          id: localId,
          nostrId: existing.nostrId,
          text: existing.text,
          createdAt: existing.createdAt,
          syncStatus: SyncStatus.failed,
        );
        _emit();
      }
    }
  }

  Future<void> retrySync(String id) async {
    final existing = _map[id];
    if (existing == null || existing.error != null) return;

    if (_db != null) await _db!.updateSyncStatus(id, SyncStatus.pending.value);
    _map[id] = DecryptedNote(
      id: id,
      nostrId: existing.nostrId,
      text: existing.text,
      createdAt: existing.createdAt,
      syncStatus: SyncStatus.pending,
    );
    _emit();

    final eventTime =
        (existing.editedAt ?? existing.createdAt).millisecondsSinceEpoch ~/
            1000;
    _publishToRelays(id, existing.text, eventTime);
  }

  Future<void> sync() async {
    if (_writeRelays.isEmpty || _signer == null) return;

    await _cancelRelaySubscription();

    final thirtyDaysAgo = DateTime.now()
            .subtract(const Duration(days: 30))
            .millisecondsSinceEpoch ~/
        1000;
    final int? since;
    if (_db != null) {
      final latest = await _db!.getLatestCreatedAt();
      // Always go back at least 30 days to catch notes from other devices
      since = latest != null ? min(latest, thirtyDaysAgo) : thirtyDaysAgo;
    } else {
      // Web has no persistent store; fall back to the same 30-day minimum
      since = thirtyDaysAgo;
    }

    final response = NostrClient().ndk.requests.subscription(
      filter: Filter(
        kinds: [33301, 5],
        authors: [_signer!.getPublicKey()],
        since: since,
      ),
      explicitRelays: _writeRelays,
    );

    _relaySubId = response.requestId;
    _relaySubscription = response.stream.listen((event) async {
      if (event.kind == 5) {
        await _onDeletionEvent(event);
      } else {
        await _onRelayEvent(event);
      }
    });

    // After relays have sent historical events, retry any that failed to decrypt
    Future.delayed(const Duration(seconds: 5), _retryPendingDecryptions);
  }

  Future<void> _onDeletionEvent(Nip01Event event) async {
    final referencedEventIds = event.tags
        .where((t) => t.length >= 2 && t[0] == 'e')
        .map((t) => t[1])
        .toSet();

    // a tags: "33301:<pubkey>:<d-tag>" — extract the d-tag portion
    final referencedDTags = event.tags
        .where((t) => t.length >= 2 && t[0] == 'a')
        .map((t) => t[1].split(':'))
        .where((parts) => parts.length == 3 && parts[0] == '33301')
        .map((parts) => parts[2])
        .toSet();

    if (referencedEventIds.isEmpty && referencedDTags.isEmpty) return;

    final toDelete = _map.values
        .where((n) =>
            (n.nostrId != null && referencedEventIds.contains(n.nostrId)) ||
            referencedDTags.contains(n.id))
        .map((n) => n.id)
        .toList();

    if (toDelete.isEmpty) return;

    // Only verify the signature when it actually targets a known note
    if (!await _verifier.verify(event)) return;

    // Remember so relay echoes arriving later in the same session are ignored
    _pendingDeletions.addAll(referencedEventIds);

    for (final localId in toDelete) {
      if (_db != null) await _db!.delete(localId);
      _map.remove(localId);
    }

    if (toDelete.isNotEmpty) _emit();
  }

  Future<void> _onRelayEvent(Nip01Event event) async {
    if (_signer == null || _localKey == null) return;
    if (_pendingDeletions.contains(event.id)) return;

    // Dedup: prefer DB check; fall back to in-memory map on web
    if (_db != null) {
      if (await _db!.existsByNostrId(event.id)) return;
    } else {
      if (_map.values.any((n) => n.nostrId == event.id)) return;
    }

    // Use d tag as stable local ID so both devices share the same identifier
    final dTag = event.tags.where((t) => t.length >= 2 && t[0] == 'd').firstOrNull;
    final localId = dTag?[1] ?? _generateId();

    // Check if this is an edit of an existing note (same d tag, different event id)
    final existingRow = _db != null ? await _db!.getById(localId) : null;
    final existingNote = _map[localId];
    if (existingRow != null || existingNote != null) {
      final existingVersionTime = existingRow != null
          ? ((existingRow['edited_at'] as int?) ?? (existingRow['created_at'] as int))
          : (existingNote!.editedAt ?? existingNote.createdAt)
              .millisecondsSinceEpoch ~/
              1000;
      if (event.createdAt <= existingVersionTime) return;

      final result = await _decryptViaSigner(_signer!, event.content);
      final text = result.text;
      final localContent =
          text != null ? await LocalCrypto.encrypt(_localKey!, text) : null;

      if (_db != null) {
        await _db!.updateSyncedEdit(
          id: localId,
          nostrId: event.id,
          encryptedContent: event.content,
          localContent: localContent,
          editedAt: event.createdAt,
        );
      }

      final originalCreatedAt = existingRow != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (existingRow['created_at'] as int) * 1000)
          : existingNote!.createdAt;

      _map[localId] = DecryptedNote(
        id: localId,
        nostrId: event.id,
        text: text ?? existingNote?.text ?? '',
        error: text == null
            ? 'The remote decryption failed with the error "${result.error}".'
            : null,
        createdAt: originalCreatedAt,
        editedAt: DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
        syncStatus: SyncStatus.synced,
      );
      _emit();
      return;
    }

    try {
      final result = await _decryptViaSigner(_signer!, event.content);
      final text = result.text;
      final localContent =
          text != null ? await LocalCrypto.encrypt(_localKey!, text) : null;

      // Decode original creation time from the d tag; compare to detect edits
      final originalCreatedAt = _createdAtFromId(localId);
      final originalCreatedAtSeconds =
          originalCreatedAt.millisecondsSinceEpoch ~/ 1000;
      final editedAt = event.createdAt > originalCreatedAtSeconds
          ? DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000)
          : null;

      if (_db != null) {
        await _db!.insertSynced(
          id: localId,
          nostrId: event.id,
          createdAt: originalCreatedAtSeconds,
          encryptedContent: event.content,
          localContent: localContent,
          editedAt: editedAt != null ? event.createdAt : null,
        );
      }

      _map[localId] = DecryptedNote(
        id: localId,
        nostrId: event.id,
        text: text ?? '',
        error: text == null
            ? 'The remote decryption failed with the error "${result.error}".'
            : null,
        createdAt: originalCreatedAt,
        editedAt: editedAt,
        syncStatus: SyncStatus.synced,
      );
      _emit();
    } catch (_) {}
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
      if (_map.containsKey(id) && _map[id]!.error == null) continue;

      final result = await _decryptViaSigner(_signer!, ciphertext);
      if (result.text == null) continue;
      final text = result.text!;

      final localContent = await LocalCrypto.encrypt(_localKey!, text);
      await _db!.updateLocalContent(id, localContent);

      final editedAtRaw = row['edited_at'] as int?;
      _map[id] = DecryptedNote(
        id: id,
        nostrId: row['nostr_id'] as String?,
        text: text,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (row['created_at'] as int) * 1000),
        editedAt: editedAtRaw != null
            ? DateTime.fromMillisecondsSinceEpoch(editedAtRaw * 1000)
            : null,
        syncStatus: SyncStatus.fromInt(row['synced_to_relay'] as int),
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

  Future<bool> retryDecrypt(String id) async {
    if (_localKey == null || _db == null) return false;

    final row = await _db!.getById(id);
    if (row == null) return false;

    // Try local key first (handles transient errors)
    final localEncoded = row['local_content'] as String?;
    if (localEncoded != null) {
      final text = await LocalCrypto.decrypt(_localKey!, localEncoded);
      if (text != null) {
        final editedAtRaw = row['edited_at'] as int?;
        _map[id] = DecryptedNote(
          id: id,
          nostrId: row['nostr_id'] as String?,
          text: text,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
              (row['created_at'] as int) * 1000),
          editedAt: editedAtRaw != null
              ? DateTime.fromMillisecondsSinceEpoch(editedAtRaw * 1000)
              : null,
          syncStatus: SyncStatus.fromInt(row['synced_to_relay'] as int),
        );
        _emit();
        return true;
      }
    }

    // Try signer on encrypted_content
    if (_signer == null) return false;
    final ciphertext = (row['encrypted_content'] as String?) ?? '';
    if (ciphertext.isEmpty) return false;

    final result = await _decryptViaSigner(_signer!, ciphertext);
    if (result.text == null) return false;

    final text = result.text!;
    final localContent = await LocalCrypto.encrypt(_localKey!, text);
    await _db!.updateLocalContent(id, localContent);
    final editedAtRaw = row['edited_at'] as int?;
    _map[id] = DecryptedNote(
      id: id,
      nostrId: row['nostr_id'] as String?,
      text: text,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          (row['created_at'] as int) * 1000),
      editedAt: editedAtRaw != null
          ? DateTime.fromMillisecondsSinceEpoch(editedAtRaw * 1000)
          : null,
      syncStatus: SyncStatus.fromInt(row['synced_to_relay'] as int),
    );
    _emit();
    return true;
  }

  Future<void> delete(String id, {String? nostrId}) async {
    if (_db != null) await _db!.delete(id);
    _map.remove(id);
    _emit();
    if (nostrId != null) _broadcastDeletion(id, nostrId);
  }

  Future<void> _broadcastDeletion(String localId, String nostrId) async {
    if (_writeRelays.isEmpty || _signer == null) return;
    try {
      final pubkey = _signer!.getPublicKey();
      final event = Nip01Event(
        pubKey: pubkey,
        kind: 5,
        tags: [
          ['e', nostrId],
          ['a', '33301:$pubkey:$localId'],
        ],
        content: '',
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      final signed = await _signer!.sign(event);
      await NostrClient()
          .ndk
          .broadcast
          .broadcast(nostrEvent: signed, specificRelays: _writeRelays)
          .broadcastDoneFuture;
    } catch (_) {}
  }

  Future<void> clear() async {
    await _cancelRelaySubscription();
    await _db?.deleteAll();
    _db = null;
    _signer = null;
    _writeRelays = [];
    _localKey = null;
    _map.clear();
    _pendingDeletions.clear();
    notifier.value = [];
  }

  Future<({String? text, String? error})> _decryptViaSigner(
      EventSigner signer, String ciphertext) async {
    try {
      final text = await signer
          .decryptNip44(
            ciphertext: ciphertext,
            senderPubKey: signer.getPublicKey(),
          )
          .timeout(const Duration(seconds: 30));
      return (text: text, error: null);
    } on TimeoutException {
      return (text: null, error: 'signer connection timed out');
    } catch (e) {
      return (text: null, error: e.toString());
    }
  }

  String _generateId() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final rand = Random.secure().nextInt(0xFFFFFF);
    return '${ts.toRadixString(16)}${rand.toRadixString(16).padLeft(6, '0')}';
  }

  // Decodes original creation time from id (format: hex(ts_ms) + 6 hex random chars)
  DateTime _createdAtFromId(String id) {
    if (id.length > 6) {
      final ms = int.tryParse(id.substring(0, id.length - 6), radix: 16);
      if (ms != null) return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    return DateTime.now();
  }
}
