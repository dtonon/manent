import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:ndk/data_layer/repositories/verifiers/bip340_event_verifier.dart';
import 'package:ndk/domain_layer/entities/filter.dart';
import 'package:ndk/domain_layer/entities/nip_01_event.dart';
import 'package:ndk/domain_layer/repositories/event_signer.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:thumbhash/thumbhash.dart';

import '../auth/nostr_client.dart';
import '../blossom/blossom_client.dart';
import '../blossom/file_crypto.dart';
import 'local_crypto.dart';
import 'local_key_store.dart';
import 'note.dart';
import 'note_attachment.dart';
import 'notes_database.dart';

class NoteCache {
  NoteCache._();
  static final instance = NoteCache._();

  final _map = <String, DecryptedNote>{};
  final notifier = ValueNotifier<List<DecryptedNote>>([]);
  final loading = ValueNotifier<bool>(true);
  // Fires true when a publish attempt finds zero accepting relays
  final promptFallbackRelays = ValueNotifier<bool>(false);

  AppDatabase? _db;
  EventSigner? _signer;
  List<String> _writeRelays = [];
  List<int>? _localKey;
  List<String> _blossomServers = [];

  List<String> get blossomServers => List.unmodifiable(_blossomServers);

  // In-memory decrypted file bytes keyed by sha256
  final _fileCache = <String, Uint8List>{};

  StreamSubscription<Nip01Event>? _relaySubscription;
  String? _relaySubId;
  Timer? _syncLoadingTimer;
  final _pendingDeletions = <String>{};
  final _verifier = Bip340EventVerifier();

  List<DecryptedNote> get _sorted =>
      _map.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  void _emit() => notifier.value = _sorted;

  void updateWriteRelays(List<String> relays) => _writeRelays = relays;

  void updateBlossomServers(List<String> servers) {
    _blossomServers =
        servers.map((s) => s.trim().replaceAll(RegExp(r'/+$'), '')).toList();
  }

  Future<void> loadAll(
      AppDatabase? db, EventSigner signer, List<String> writeRelays) async {
    loading.value = true;
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
        final rowKind = (row['kind'] as int?) ?? 33301;
        final kind = NoteKind.fromEventKind(rowKind);
        final localEncoded = row['local_content'] as String?;
        String? text;
        String? errorMsg;
        NoteAttachment? attachment;

        if (localEncoded != null) {
          final decoded = await LocalCrypto.decrypt(_localKey!, localEncoded);
          if (decoded == null) {
            errorMsg = 'The local decryption failed.';
          } else if (kind == NoteKind.file) {
            try {
              attachment =
                  NoteAttachment.fromJson(jsonDecode(decoded) as Map<String, dynamic>);
              text = '';
            } catch (_) {
              errorMsg = 'Failed to parse file metadata.';
            }
          } else {
            text = decoded;
          }
        } else {
          // Migration / pending retry path
          final ciphertext = row['encrypted_content'] as String;
          if (ciphertext.isNotEmpty) {
            final result = await _decryptViaSigner(signer, ciphertext);
            final plain = result.text;
            if (plain != null) {
              if (kind == NoteKind.file) {
                try {
                  attachment = NoteAttachment.fromJson(
                      jsonDecode(plain) as Map<String, dynamic>);
                  text = '';
                } catch (_) {
                  errorMsg = 'Failed to parse file metadata.';
                }
              } else {
                text = plain;
              }
              if (errorMsg == null) {
                final cached = await LocalCrypto.encrypt(_localKey!, plain);
                await _db!.updateLocalContent(id, cached);
              }
            } else {
              errorMsg =
                  'The remote decryption failed with the error "${result.error}".';
            }
          }
        }

        if (text == null && attachment == null && errorMsg == null) continue;
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
          kind: kind,
          attachment: attachment,
        );
      }
      _emit();
      if (_map.isNotEmpty) loading.value = false;
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

  Future<void> addFile(Uint8List bytes, String filename,
      {String? comment}) async {
    if (_localKey == null) return;

    filename = p.basename(filename);
    final mimeType = lookupMimeType(filename) ?? 'application/octet-stream';
    final key = FileCrypto.generateKey();
    final encryptedBytes = await FileCrypto.encrypt(key, bytes);
    final sha256 = await FileCrypto.sha256Hex(encryptedBytes);
    final keyHex = FileCrypto.keyToHex(key);

    // Compute thumbhash for images
    String? thumbhash;
    if (mimeType.startsWith('image/')) {
      thumbhash = await _computeThumbhash(bytes);
    }

    final isInline = encryptedBytes.length < 32 * 1024;

    NoteAttachment attachment;
    if (isInline) {
      attachment = NoteAttachment(
        data: base64Encode(encryptedBytes),
        filename: filename,
        mimeType: mimeType,
        size: bytes.length,
        sha256: sha256,
        key: keyHex,
        thumbhash: thumbhash,
        comment: comment,
      );
    } else {
      // Save encrypted file to disk cache for later display
      if (!kIsWeb) {
        final dir = await _filesCacheDir();
        final encFile = File(p.join(dir, '$sha256.enc'));
        await encFile.writeAsBytes(encryptedBytes);
      }
      attachment = NoteAttachment(
        filename: filename,
        mimeType: mimeType,
        size: bytes.length,
        sha256: sha256,
        key: keyHex,
        thumbhash: thumbhash,
        comment: comment,
      );
    }

    // Cache decrypted bytes in memory
    _fileCache[sha256] = bytes;

    final metaJson = attachment.toJsonString();
    final localContent = await LocalCrypto.encrypt(_localKey!, metaJson);
    final id = _generateId();
    final now = DateTime.now();

    if (_db != null) {
      await _db!.insert(
        id: id,
        createdAt: now.millisecondsSinceEpoch ~/ 1000,
        localContent: localContent,
        kind: 33302,
      );
    }

    _map[id] = DecryptedNote(
      id: id,
      text: '',
      createdAt: now,
      syncStatus: SyncStatus.pending,
      kind: NoteKind.file,
      attachment: attachment,
    );
    _emit();

    if (isInline) {
      _publishFileEvent(id, attachment, now.millisecondsSinceEpoch ~/ 1000);
    } else {
      _uploadFileAndPublish(id, attachment, encryptedBytes, now.millisecondsSinceEpoch ~/ 1000);
    }
  }

  // Returns decrypted file bytes for an attachment.
  Future<Uint8List?> getFileBytes(NoteAttachment attachment) async {
    // Check memory cache
    final cached = _fileCache[attachment.sha256];
    if (cached != null) return cached;

    final key = FileCrypto.hexToKey(attachment.key);

    // Inline data
    if (attachment.isInline && attachment.data != null) {
      final encBytes = base64Decode(attachment.data!);
      final plain = await FileCrypto.decrypt(key, encBytes);
      if (plain != null) _fileCache[attachment.sha256] = plain;
      return plain;
    }

    // Check disk cache
    if (!kIsWeb) {
      final dir = await _filesCacheDir();
      final encFile = File(p.join(dir, '${attachment.sha256}.enc'));
      if (await encFile.exists()) {
        final encBytes = await encFile.readAsBytes();
        final plain = await FileCrypto.decrypt(key, encBytes);
        if (plain != null) _fileCache[attachment.sha256] = plain;
        return plain;
      }
    }

    // Download from Blossom
    if (attachment.url == null) return null;
    final encBytes = await BlossomClient.download(attachment.url!);
    if (encBytes == null) return null;

    // Save to disk cache
    if (!kIsWeb) {
      final dir = await _filesCacheDir();
      final encFile = File(p.join(dir, '${attachment.sha256}.enc'));
      await encFile.writeAsBytes(encBytes);
    }

    final plain = await FileCrypto.decrypt(key, encBytes);
    if (plain != null) _fileCache[attachment.sha256] = plain;
    return plain;
  }

  Future<void> _retryUploadAndPublish(
    String localId,
    NoteAttachment attachment,
    int createdAt,
  ) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'files', '${attachment.sha256}.enc'));
      if (!await file.exists()) return;
      final encryptedBytes = await file.readAsBytes();
      await _uploadFileAndPublish(localId, attachment, encryptedBytes, createdAt);
    } catch (_) {}
  }

  Future<void> _uploadFileAndPublish(
    String localId,
    NoteAttachment attachment,
    Uint8List encryptedBytes,
    int createdAt,
  ) async {
    if (_signer == null || _blossomServers.isEmpty) return;

    String? url;
    for (final server in _blossomServers) {
      url = await BlossomClient.upload(
        server: server,
        data: encryptedBytes,
        sha256: attachment.sha256,
        signer: _signer!,
      );
      if (url != null) break;
    }

    if (url == null) {
      if (_db != null) await _db!.updateSyncStatus(localId, SyncStatus.failed.value);
      final existing = _map[localId];
      if (existing != null) {
        _map[localId] = _withSyncStatus(existing, SyncStatus.failed);
        _emit();
      }
      return;
    }

    final updated = attachment.copyWith(url: url);

    // Update local_content with the URL
    if (_localKey != null && _db != null) {
      final metaJson = updated.toJsonString();
      final localContent = await LocalCrypto.encrypt(_localKey!, metaJson);
      await _db!.updateLocalContent(localId, localContent);
    }

    // Update in-memory note
    final existing = _map[localId];
    if (existing != null) {
      _map[localId] = DecryptedNote(
        id: localId,
        nostrId: existing.nostrId,
        text: '',
        createdAt: existing.createdAt,
        syncStatus: SyncStatus.pending,
        kind: NoteKind.file,
        attachment: updated,
      );
    }

    await _publishFileEvent(localId, updated, createdAt);
  }

  Future<void> _publishFileEvent(
    String localId,
    NoteAttachment attachment,
    int createdAt,
  ) async {
    if (_signer == null) return;
    // Never publish a remote file note that hasn't been uploaded yet
    if (!attachment.isInline && attachment.url == null) return;
    if (_writeRelays.isEmpty) {
      promptFallbackRelays.value = true;
      if (_db != null) await _db!.updateSyncStatus(localId, SyncStatus.failed.value);
      final existing = _map[localId];
      if (existing != null) {
        _map[localId] = _withSyncStatus(existing, SyncStatus.failed);
        _emit();
      }
      return;
    }
    try {
      final metaJson = attachment.toJsonString();
      final encrypted = await _signer!.encryptNip44(
        plaintext: metaJson,
        recipientPubKey: _signer!.getPublicKey(),
      );
      if (encrypted == null) return;

      if (_db != null) {
        await _db!.updateEncryptedContent(
            localId: localId, encryptedContent: encrypted);
      }

      final event = Nip01Event(
        pubKey: _signer!.getPublicKey(),
        kind: 33302,
        tags: [
          ['d', localId]
        ],
        content: encrypted,
        createdAt: createdAt,
      );
      final signed = await _signer!.sign(event);

      if (_db != null) {
        await _db!.updateNostrId(localId: localId, nostrId: signed.id);
      }
      final existing = _map[localId];
      if (existing != null) {
        _map[localId] = DecryptedNote(
          id: localId,
          nostrId: signed.id,
          text: '',
          createdAt: existing.createdAt,
          syncStatus: SyncStatus.pending,
          kind: NoteKind.file,
          attachment: existing.attachment,
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

      if (newStatus == SyncStatus.failed) promptFallbackRelays.value = true;

      if (_db != null) {
        await _db!.updateSyncStatus(localId, newStatus.value);
      }
      final updated = _map[localId];
      if (updated != null) {
        _map[localId] = _withSyncStatus(updated, newStatus);
        _emit();
      }

      _retryPendingDecryptions();
    } catch (_) {
      if (_db != null) await _db!.updateSyncStatus(localId, SyncStatus.failed.value);
      final existing = _map[localId];
      if (existing != null) {
        _map[localId] = _withSyncStatus(existing, SyncStatus.failed);
        _emit();
      }
    }
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
    if (_signer == null) return;
    if (_writeRelays.isEmpty) {
      promptFallbackRelays.value = true;
      if (_db != null) await _db!.updateSyncStatus(localId, SyncStatus.failed.value);
      final existing = _map[localId];
      if (existing != null) {
        _map[localId] = _withSyncStatus(existing, SyncStatus.failed);
        _emit();
      }
      return;
    }
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
          editedAt: existing.editedAt,
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

      if (newStatus == SyncStatus.failed) promptFallbackRelays.value = true;

      if (_db != null) {
        await _db!.updateSyncStatus(localId, newStatus.value);
      }
      final updated = _map[localId];
      if (updated != null) {
        _map[localId] = _withSyncStatus(updated, newStatus);
        _emit();
      }

      _retryPendingDecryptions();
    } catch (_) {
      if (_db != null) await _db!.updateSyncStatus(localId, SyncStatus.failed.value);
      final existing = _map[localId];
      if (existing != null) {
        _map[localId] = _withSyncStatus(existing, SyncStatus.failed);
        _emit();
      }
    }
  }

  Future<void> retrySync(String id) async {
    final existing = _map[id];
    if (existing == null || existing.error != null) return;

    if (_db != null) await _db!.updateSyncStatus(id, SyncStatus.pending.value);
    _map[id] = _withSyncStatus(existing, SyncStatus.pending);
    _emit();

    if (existing.kind == NoteKind.file && existing.attachment != null) {
      final att = existing.attachment!;
      final eventTime =
          (existing.editedAt ?? existing.createdAt).millisecondsSinceEpoch ~/
              1000;
      if (att.isInline || att.url != null) {
        _publishFileEvent(id, att, eventTime);
      } else {
        // Encrypted file never uploaded — re-read from disk and retry upload
        _retryUploadAndPublish(id, att, eventTime);
      }
    } else {
      final eventTime =
          (existing.editedAt ?? existing.createdAt).millisecondsSinceEpoch ~/
              1000;
      _publishToRelays(id, existing.text, eventTime);
    }
  }

  Future<void> sync({bool showLoading = false}) async {
    _syncLoadingTimer?.cancel();

    if (_writeRelays.isEmpty || _signer == null) {
      if (showLoading) loading.value = false;
      return;
    }

    if (showLoading && _map.isEmpty) loading.value = true;
    await _cancelRelaySubscription();

    final thirtyDaysAgo = DateTime.now()
            .subtract(const Duration(days: 30))
            .millisecondsSinceEpoch ~/
        1000;
    final int? since;
    if (_db != null) {
      final latest = await _db!.getLatestCreatedAt();
      since = latest != null ? min(latest, thirtyDaysAgo) : thirtyDaysAgo;
    } else {
      since = thirtyDaysAgo;
    }

    final response = NostrClient().ndk.requests.subscription(
      filter: Filter(
        kinds: [33301, 33302, 5],
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
      if (showLoading && _map.isNotEmpty) _clearSyncLoading();
    });

    if (showLoading) {
      _syncLoadingTimer =
          Timer(const Duration(seconds: 10), () => loading.value = false);
    }

    Future.delayed(const Duration(seconds: 10), _retryPendingDecryptions);
  }

  void _clearSyncLoading() {
    if (!loading.value) return;
    _syncLoadingTimer?.cancel();
    _syncLoadingTimer = null;
    loading.value = false;
  }

  Future<void> _onDeletionEvent(Nip01Event event) async {
    final referencedEventIds = event.tags
        .where((t) => t.length >= 2 && t[0] == 'e')
        .map((t) => t[1])
        .toSet();

    // a tags: "33301:<pubkey>:<d-tag>" or "33302:<pubkey>:<d-tag>"
    final referencedDTags = event.tags
        .where((t) => t.length >= 2 && t[0] == 'a')
        .map((t) => t[1].split(':'))
        .where((parts) =>
            parts.length == 3 &&
            (parts[0] == '33301' || parts[0] == '33302'))
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

    if (!await _verifier.verify(event)) return;

    _pendingDeletions.addAll(referencedEventIds);

    for (final localId in toDelete) {
      final note = _map[localId];
      if (note?.attachment != null) {
        await _deleteEncFile(note!.attachment!.sha256);
        _deleteFromBlossom(note.attachment!);
      }
      if (_db != null) await _db!.delete(localId);
      _map.remove(localId);
    }

    if (toDelete.isNotEmpty) _emit();
  }

  Future<void> _onRelayEvent(Nip01Event event) async {
    if (_signer == null || _localKey == null) return;
    if (_pendingDeletions.contains(event.id)) return;

    if (_db != null) {
      if (await _db!.existsByNostrId(event.id)) return;
    } else {
      if (_map.values.any((n) => n.nostrId == event.id)) return;
    }

    final kind = NoteKind.fromEventKind(event.kind);
    final dTag = event.tags
        .where((t) => t.length >= 2 && t[0] == 'd')
        .firstOrNull;
    final localId = dTag?[1] ?? _generateId();

    final existingRow = _db != null ? await _db!.getById(localId) : null;
    final existingNote = _map[localId];
    if (existingRow != null || existingNote != null) {
      final existingVersionTime = existingRow != null
          ? ((existingRow['edited_at'] as int?) ??
              (existingRow['created_at'] as int))
          : (existingNote!.editedAt ?? existingNote.createdAt)
                  .millisecondsSinceEpoch ~/
              1000;
      if (event.createdAt <= existingVersionTime) return;

      final result = await _decryptViaSigner(_signer!, event.content);
      final plain = result.text;
      NoteAttachment? attachment;
      String? errorMsg;

      if (plain != null) {
        if (kind == NoteKind.file) {
          try {
            attachment = NoteAttachment.fromJson(
                jsonDecode(plain) as Map<String, dynamic>);
          } catch (_) {
            errorMsg = 'Failed to parse file metadata.';
          }
        }
      } else {
        errorMsg = 'The remote decryption failed with the error "${result.error}".';
      }

      final localContent =
          plain != null ? await LocalCrypto.encrypt(_localKey!, plain) : null;

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
        text: kind == NoteKind.file ? '' : (plain ?? existingNote?.text ?? ''),
        error: errorMsg,
        createdAt: originalCreatedAt,
        editedAt: DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
        syncStatus: SyncStatus.synced,
        kind: kind,
        attachment: attachment,
      );
      _emit();
      return;
    }

    try {
      final result = await _decryptViaSigner(_signer!, event.content);
      final plain = result.text;
      NoteAttachment? attachment;
      String? errorMsg;

      if (plain != null) {
        if (kind == NoteKind.file) {
          try {
            attachment = NoteAttachment.fromJson(
                jsonDecode(plain) as Map<String, dynamic>);
          } catch (_) {
            errorMsg = 'Failed to parse file metadata.';
          }
        }
      } else {
        errorMsg =
            'The remote decryption failed with the error "${result.error}".';
      }

      final localContent =
          plain != null ? await LocalCrypto.encrypt(_localKey!, plain) : null;

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
          kind: event.kind,
        );
      }

      _map[localId] = DecryptedNote(
        id: localId,
        nostrId: event.id,
        text: kind == NoteKind.file ? '' : (plain ?? ''),
        error: errorMsg,
        createdAt: originalCreatedAt,
        editedAt: editedAt,
        syncStatus: SyncStatus.synced,
        kind: kind,
        attachment: attachment,
      );
      _emit();
    } catch (_) {}
  }

  Future<void> _retryPendingDecryptions() async {
    if (_db == null || _signer == null || _localKey == null) return;

    final rows = await _db!.getAll();
    int retried = 0;

    for (final row in rows) {
      if (row['local_content'] != null) continue;
      final ciphertext = row['encrypted_content'] as String;
      if (ciphertext.isEmpty) continue;

      final id = row['id'] as String;
      if (_map.containsKey(id) && _map[id]!.error == null) continue;

      final rowKind = (row['kind'] as int?) ?? 33301;
      final kind = NoteKind.fromEventKind(rowKind);

      final result = await _decryptViaSigner(_signer!, ciphertext);
      if (result.text == null) continue;
      final plain = result.text!;

      NoteAttachment? attachment;
      if (kind == NoteKind.file) {
        try {
          attachment =
              NoteAttachment.fromJson(jsonDecode(plain) as Map<String, dynamic>);
        } catch (_) {
          continue;
        }
      }

      final localContent = await LocalCrypto.encrypt(_localKey!, plain);
      await _db!.updateLocalContent(id, localContent);

      final editedAtRaw = row['edited_at'] as int?;
      _map[id] = DecryptedNote(
        id: id,
        nostrId: row['nostr_id'] as String?,
        text: kind == NoteKind.file ? '' : plain,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (row['created_at'] as int) * 1000),
        editedAt: editedAtRaw != null
            ? DateTime.fromMillisecondsSinceEpoch(editedAtRaw * 1000)
            : null,
        syncStatus: SyncStatus.fromInt(row['synced_to_relay'] as int),
        kind: kind,
        attachment: attachment,
      );
      retried++;
    }

    if (retried > 0) _emit();
  }

  Future<void> _cancelRelaySubscription() async {
    _syncLoadingTimer?.cancel();
    _syncLoadingTimer = null;
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

    final rowKind = (row['kind'] as int?) ?? 33301;
    final kind = NoteKind.fromEventKind(rowKind);

    final localEncoded = row['local_content'] as String?;
    if (localEncoded != null) {
      final plain = await LocalCrypto.decrypt(_localKey!, localEncoded);
      if (plain != null) {
        NoteAttachment? attachment;
        if (kind == NoteKind.file) {
          try {
            attachment =
                NoteAttachment.fromJson(jsonDecode(plain) as Map<String, dynamic>);
          } catch (_) {
            return false;
          }
        }
        final editedAtRaw = row['edited_at'] as int?;
        _map[id] = DecryptedNote(
          id: id,
          nostrId: row['nostr_id'] as String?,
          text: kind == NoteKind.file ? '' : plain,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
              (row['created_at'] as int) * 1000),
          editedAt: editedAtRaw != null
              ? DateTime.fromMillisecondsSinceEpoch(editedAtRaw * 1000)
              : null,
          syncStatus: SyncStatus.fromInt(row['synced_to_relay'] as int),
          kind: kind,
          attachment: attachment,
        );
        _emit();
        return true;
      }
    }

    if (_signer == null) return false;
    final ciphertext = (row['encrypted_content'] as String?) ?? '';
    if (ciphertext.isEmpty) return false;

    final result = await _decryptViaSigner(_signer!, ciphertext);
    if (result.text == null) return false;

    final plain = result.text!;
    NoteAttachment? attachment;
    if (kind == NoteKind.file) {
      try {
        attachment =
            NoteAttachment.fromJson(jsonDecode(plain) as Map<String, dynamic>);
      } catch (_) {
        return false;
      }
    }

    final localContent = await LocalCrypto.encrypt(_localKey!, plain);
    await _db!.updateLocalContent(id, localContent);
    final editedAtRaw = row['edited_at'] as int?;
    _map[id] = DecryptedNote(
      id: id,
      nostrId: row['nostr_id'] as String?,
      text: kind == NoteKind.file ? '' : plain,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          (row['created_at'] as int) * 1000),
      editedAt: editedAtRaw != null
          ? DateTime.fromMillisecondsSinceEpoch(editedAtRaw * 1000)
          : null,
      syncStatus: SyncStatus.fromInt(row['synced_to_relay'] as int),
      kind: kind,
      attachment: attachment,
    );
    _emit();
    return true;
  }

  Future<void> delete(String id, {String? nostrId}) async {
    final note = _map[id];
    if (note?.attachment != null) {
      await _deleteEncFile(note!.attachment!.sha256);
      _deleteFromBlossom(note.attachment!);
    }
    if (_db != null) await _db!.delete(id);
    _map.remove(id);
    _emit();
    if (nostrId != null) _broadcastDeletion(id, nostrId, note?.kind ?? NoteKind.text);
  }

  void retryAllFailed() {
    final failed = _map.values
        .where((n) => n.error == null && n.syncStatus == SyncStatus.failed)
        .map((n) => n.id)
        .toList();
    for (final id in failed) {
      retrySync(id);
    }
  }

  Future<void> _broadcastDeletion(String localId, String nostrId, NoteKind kind) async {
    if (_writeRelays.isEmpty || _signer == null) return;
    try {
      final pubkey = _signer!.getPublicKey();
      final kindNum = kind.eventKind;
      final event = Nip01Event(
        pubKey: pubkey,
        kind: 5,
        tags: [
          ['e', nostrId],
          ['a', '$kindNum:$pubkey:$localId'],
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
    _fileCache.clear();
    _map.clear();
    _pendingDeletions.clear();
    notifier.value = [];
    loading.value = false;
    promptFallbackRelays.value = false;
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

  DateTime _createdAtFromId(String id) {
    if (id.length > 6) {
      final ms = int.tryParse(id.substring(0, id.length - 6), radix: 16);
      if (ms != null) return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    return DateTime.now();
  }

  DecryptedNote _withSyncStatus(DecryptedNote n, SyncStatus s) => DecryptedNote(
        id: n.id,
        nostrId: n.nostrId,
        text: n.text,
        error: n.error,
        createdAt: n.createdAt,
        editedAt: n.editedAt,
        syncStatus: s,
        kind: n.kind,
        attachment: n.attachment,
      );

  Future<String> _filesCacheDir() async {
    final dir = await getApplicationSupportDirectory();
    final filesDir = Directory(p.join(dir.path, 'files'));
    if (!await filesDir.exists()) await filesDir.create(recursive: true);
    return filesDir.path;
  }

  Future<void> _deleteFromBlossom(NoteAttachment attachment) async {
    if (_signer == null || attachment.url == null) return;
    for (final server in _blossomServers) {
      BlossomClient.delete(
        server: server,
        sha256: attachment.sha256,
        signer: _signer!,
      );
    }
  }

  Future<void> _deleteEncFile(String sha256) async {
    if (kIsWeb) return;
    try {
      final dir = await _filesCacheDir();
      final f = File(p.join(dir, '$sha256.enc'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // Computes a thumbhash from raw image bytes; returns base64 or null on error.
  static Future<String?> _computeThumbhash(Uint8List imageBytes) async {
    try {
      final codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final w = image.width;
      final h = image.height;
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (byteData == null) return null;
      final hash = rgbaToThumbHash(w, h, byteData.buffer.asUint8List());
      return base64Encode(hash);
    } catch (_) {
      return null;
    }
  }
}
