import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ndk/data_layer/repositories/verifiers/bip340_event_verifier.dart';
import 'package:ndk/domain_layer/entities/broadcast_state.dart';
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
import 'sync_diagnostics.dart';

class NoteCache {
  NoteCache._();
  static final instance = NoteCache._();

  final _map = <String, DecryptedNote>{};
  final notifier = ValueNotifier<List<DecryptedNote>>([]);
  final loading = ValueNotifier<bool>(true);
  final loadingOlder = ValueNotifier<bool>(false);
  // Fires true when a publish attempt finds zero accepting relays
  final promptFallbackRelays = ValueNotifier<bool>(false);
  // Fires true when an upload is refused by every configured Blossom server
  final promptFallbackBlossom = ValueNotifier<bool>(false);

  static const _olderHistoryCompleteKey = 'older_history_complete';
  static const _olderHistoryBatchSize = 250;

  AppDatabase? _db;
  EventSigner? _signer;
  List<String> _writeRelays = [];
  List<int>? _localKey;
  List<String> _blossomServers = [];

  List<String> get blossomServers => List.unmodifiable(_blossomServers);

  // In-memory decrypted file bytes keyed by sha256
  final _fileCache = <String, Uint8List>{};

  // Servers that refused our content outright; skipped for the rest of the
  // session so every file does not pay for a guaranteed rejection
  final _refusingServers = <String>{};

  // Limit concurrent Blossom downloads to avoid flooding on large feeds
  static const _maxConcurrentDownloads = 3;
  int _activeDownloads = 0;
  final _downloadWaiters = <Completer<void>>[];

  Future<void> _acquireDownloadSlot() async {
    while (_activeDownloads >= _maxConcurrentDownloads) {
      final c = Completer<void>();
      _downloadWaiters.add(c);
      await c.future;
    }
    _activeDownloads++;
  }

  void _releaseDownloadSlot() {
    _activeDownloads--;
    if (_downloadWaiters.isNotEmpty) {
      _downloadWaiters.removeAt(0).complete();
    }
  }

  StreamSubscription<Nip01Event>? _relaySubscription;
  String? _relaySubId;
  Timer? _syncLoadingTimer;
  final _pendingDeletions = <String>{};
  final _verifier = Bip340EventVerifier();
  bool _isRetrying = false;

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
              attachment = NoteAttachment.fromJson(
                  jsonDecode(decoded) as Map<String, dynamic>);
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
              bool payloadSensitive = false;
              if (kind == NoteKind.file) {
                try {
                  attachment = NoteAttachment.fromJson(
                      jsonDecode(plain) as Map<String, dynamic>);
                  text = '';
                } catch (_) {
                  errorMsg = 'Failed to parse file metadata.';
                }
              } else {
                final payload = _extractPayload(plain);
                text = payload.text;
                payloadSensitive = payload.sensitive;
              }
              if (errorMsg == null) {
                final toCache = kind == NoteKind.file ? plain : text!;
                final cached = await LocalCrypto.encrypt(_localKey!, toCache);
                // Persist the sensitive flag without touching sync status
                await _db!.updateLocalContent(id, cached,
                    sensitive: kind == NoteKind.text ? payloadSensitive : null);
              }
            } else {
              errorMsg =
                  'The remote decryption failed with the error "${result.error}".';
            }
          }
        }

        if (text == null && attachment == null && errorMsg == null) continue;
        final editedAtRaw = row['edited_at'] as int?;
        final sensitive = kind == NoteKind.file
            ? (attachment?.sensitive ?? false)
            : (row['sensitive'] as int? ?? 0) == 1;
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
          syncStatus: _loadedSyncStatus(row['synced_to_relay'] as int),
          kind: kind,
          attachment: attachment,
          sensitive: sensitive,
        );
      }
      _emit();
      if (_map.isNotEmpty) loading.value = false;
    } catch (_) {
      _emit();
    }
  }

  // Returns the local id of the new note so callers can track it
  Future<String?> add(String text) async {
    if (_localKey == null) return null;

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
    return id;
  }

  Future<String?> addFile(Uint8List bytes, String filename,
      {String? caption}) async {
    if (_localKey == null) return null;

    filename = p.basename(filename);
    final mimeType = lookupMimeType(filename) ?? 'application/octet-stream';
    final key = FileCrypto.generateKey();
    final encryptedBytes = await FileCrypto.encrypt(key, bytes);
    final sha256 = await FileCrypto.sha256Hex(encryptedBytes);
    final keyHex = FileCrypto.keyToHex(key);

    // Compute thumbhash and dimensions for images
    String? thumbhash;
    String? dim;
    if (rasterImageMimeTypes.contains(mimeType)) {
      final info = await _computeImageInfo(bytes);
      thumbhash = info.thumbhash;
      dim = info.dim;
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
        caption: caption,
        dim: dim,
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
        caption: caption,
        dim: dim,
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
      _uploadFileAndPublish(
          id, attachment, encryptedBytes, now.millisecondsSinceEpoch ~/ 1000);
    }
    return id;
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

    // Download from Blossom (rate-limited). Blobs are content addressed, so any
    // configured server can serve one; the stored url is only the first guess.
    final candidates = <String>{
      if (attachment.url != null) attachment.url!,
      for (final s in _blossomServers) '$s/${attachment.sha256}',
    };
    if (candidates.isEmpty) return null;

    Uint8List? encBytes;
    await _acquireDownloadSlot();
    try {
      for (final url in candidates) {
        encBytes = await BlossomClient.download(url);
        if (encBytes != null) break;
      }
    } finally {
      _releaseDownloadSlot();
    }
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
      if (!await file.exists()) {
        _diag(localId, 'retry aborted: cache file missing at ${file.path}');
        return;
      }
      final encryptedBytes = await file.readAsBytes();
      await _uploadFileAndPublish(
          localId, attachment, encryptedBytes, createdAt);
    } catch (e) {
      _diag(localId, 'retry threw ${SyncDiagnostics.detail(e)}');
    }
  }

  Future<void> _uploadFileAndPublish(
    String localId,
    NoteAttachment attachment,
    Uint8List encryptedBytes,
    int createdAt,
  ) async {
    if (_signer == null || _blossomServers.isEmpty) {
      _diag(localId,
          'upload skipped: signer=${_signer != null}, servers=$_blossomServers');
      return;
    }

    _diag(
        localId,
        'upload start: ${encryptedBytes.length} encrypted bytes, '
        'mime=${attachment.mimeType}, servers=$_blossomServers');
    String? url;
    String? uploadedTo;
    final failedHere = <String>{};
    for (final server in _blossomServers) {
      if (_refusingServers.contains(server)) {
        _diag(localId, '$server skipped: refused our content earlier');
        continue;
      }
      final result = await BlossomClient.upload(
        server: server,
        data: encryptedBytes,
        sha256: attachment.sha256,
        signer: _signer!,
      );
      url = result.url;
      _diag(localId,
          url != null ? '$server OK → $url' : '$server failed: ${result.error}');
      if (url != null) {
        uploadedTo = server;
        break;
      }
      failedHere.add(server);
      if (result.rejected) _refusingServers.add(server);
    }

    if (url == null) {
      _diag(localId, 'all ${_blossomServers.length} server(s) failed');
      promptFallbackBlossom.value = true;
      if (_db != null)
        await _db!.updateSyncStatus(localId, SyncStatus.failed.value);
      final existing = _map[localId];
      if (existing != null) {
        _map[localId] = _withSyncStatus(existing, SyncStatus.failed);
        _emit();
      }
      return;
    }

    // One copy is enough to publish; the others are filled in behind the note
    _mirrorToOtherServers(localId, url, attachment.sha256, encryptedBytes,
        skip: {uploadedTo!, ...failedHere});

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
        sensitive: updated.sensitive,
      );
    }

    await _publishFileEvent(localId, updated, createdAt);
  }

  Future<void> _publishFileEvent(
    String localId,
    NoteAttachment attachment,
    int createdAt,
  ) async {
    if (_signer == null) {
      _diag(localId, 'publish aborted: no signer');
      await _markSyncFailed(localId);
      return;
    }
    // Never publish a remote file note that hasn't been uploaded yet
    if (!attachment.isInline && attachment.url == null) {
      _diag(localId, 'publish skipped: not inline and url is null');
      return;
    }
    if (_writeRelays.isEmpty) {
      _diag(localId, 'publish aborted: no write relays');
      promptFallbackRelays.value = true;
      if (_db != null)
        await _db!.updateSyncStatus(localId, SyncStatus.failed.value);
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
      if (encrypted == null) {
        _diag(localId, 'publish aborted: NIP-44 encryption returned null');
        await _markSyncFailed(localId);
        return;
      }

      _diag(
          localId,
          'publish: inline=${attachment.isInline} url=${attachment.url ?? "-"} '
          'nip44_payload=${encrypted.length} chars');

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
          sensitive: attachment.sensitive,
        );
      }

      final responses = await NostrClient()
          .ndk
          .broadcast
          .broadcast(nostrEvent: signed, specificRelays: _writeRelays)
          .broadcastDoneFuture;

      _recordRelayResponses(localId, signed, responses);

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
    } catch (e) {
      _diag(localId, 'publish threw ${SyncDiagnostics.detail(e)}');
      if (_db != null)
        await _db!.updateSyncStatus(localId, SyncStatus.failed.value);
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

    NoteAttachment? updatedAttachment;
    String localContent;

    if (existing.kind == NoteKind.file && existing.attachment != null) {
      final att = existing.attachment!;
      updatedAttachment = NoteAttachment(
        url: att.url,
        data: att.data,
        filename: att.filename,
        mimeType: att.mimeType,
        size: att.size,
        sha256: att.sha256,
        key: att.key,
        thumbhash: att.thumbhash,
        caption: newText.isEmpty ? null : newText,
      );
      localContent = await LocalCrypto.encrypt(
          _localKey!, updatedAttachment.toJsonString());
    } else {
      localContent = await LocalCrypto.encrypt(_localKey!, newText);
    }

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
      text: existing.kind == NoteKind.file ? '' : newText,
      createdAt: existing.createdAt,
      editedAt: editedAt,
      syncStatus: SyncStatus.pending,
      kind: existing.kind,
      attachment: updatedAttachment ?? existing.attachment,
      sensitive: existing.sensitive,
    );
    _emit();

    if (existing.kind == NoteKind.file) {
      _publishFileEvent(id, updatedAttachment!, editedAtSeconds);
    } else {
      _publishToRelays(id, newText, editedAtSeconds,
          sensitive: existing.sensitive);
    }
  }

  Future<void> _publishToRelays(String localId, String plaintext, int createdAt,
      {bool sensitive = false}) async {
    if (_signer == null) {
      await _markSyncFailed(localId);
      return;
    }
    if (_writeRelays.isEmpty) {
      promptFallbackRelays.value = true;
      if (_db != null)
        await _db!.updateSyncStatus(localId, SyncStatus.failed.value);
      final existing = _map[localId];
      if (existing != null) {
        _map[localId] = _withSyncStatus(existing, SyncStatus.failed);
        _emit();
      }
      return;
    }
    try {
      final encrypted = await _signer!.encryptNip44(
        plaintext: jsonEncode({
          'text': plaintext,
          if (sensitive) 'sensitive': true,
        }),
        recipientPubKey: _signer!.getPublicKey(),
      );
      if (encrypted == null) {
        await _markSyncFailed(localId);
        return;
      }

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
          sensitive: existing.sensitive,
        );
      }

      final responses = await NostrClient()
          .ndk
          .broadcast
          .broadcast(nostrEvent: signed, specificRelays: _writeRelays)
          .broadcastDoneFuture;

      _recordRelayResponses(localId, signed, responses);

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
    } catch (e) {
      _diag(localId, 'publish threw ${SyncDiagnostics.detail(e)}');
      if (_db != null)
        await _db!.updateSyncStatus(localId, SyncStatus.failed.value);
      final existing = _map[localId];
      if (existing != null) {
        _map[localId] = _withSyncStatus(existing, SyncStatus.failed);
        _emit();
      }
    }
  }

  // Copies an uploaded blob to the remaining servers so a file stays reachable
  // if one of them drops it. Best-effort: failures never affect sync status.
  // `skip` holds the server that already has it plus any that just failed it.
  Future<void> _mirrorToOtherServers(
      String localId, String url, String sha256, Uint8List encryptedBytes,
      {required Set<String> skip}) async {
    for (final server in _blossomServers) {
      if (skip.contains(server) || _refusingServers.contains(server)) continue;
      if (_signer == null) return;
      var ok = await BlossomClient.mirror(
        server: server,
        sourceUrl: url,
        sha256: sha256,
        signer: _signer!,
      );
      // Not every server implements /mirror, or it may fail to reach the source
      if (!ok) {
        final result = await BlossomClient.upload(
          server: server,
          data: encryptedBytes,
          sha256: sha256,
          signer: _signer!,
        );
        ok = result.url != null;
        if (result.rejected) _refusingServers.add(server);
      }
      _diag(localId, ok ? 'mirrored to $server' : 'mirror to $server failed');
    }
  }

  void _diag(String localId, String message) =>
      SyncDiagnostics.instance.record(localId, message);

  void _recordRelayResponses(String localId, Nip01Event signed,
      List<RelayBroadcastResponse> responses) {
    _diag(localId,
        'broadcast kind ${signed.kind} id=${signed.id} created_at=${signed.createdAt}');
    for (final r in responses) {
      _diag(
          localId,
          '  ${r.relayUrl}: success=${r.broadcastSuccessful} '
          'msg="${SyncDiagnostics.detail(r.msg)}"');
    }
    String norm(String u) => u.replaceAll(RegExp(r'/+$'), '');
    final answered = responses.map((r) => norm(r.relayUrl)).toSet();
    for (final u in _writeRelays.where((u) => !answered.contains(norm(u)))) {
      _diag(localId, '  $u: no response');
    }
  }

  Future<void> retrySync(String id) async {
    final existing = _map[id];
    if (existing == null || existing.error != null) return;
    _diag(id, '--- manual retry ---');

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
      _publishToRelays(id, existing.text, eventTime,
          sensitive: existing.sensitive);
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

    final int? since;
    final int? limit;
    final latest = _db != null ? await _db!.getLatestCreatedAt() : null;
    if (latest != null) {
      since = latest;
      limit = null;
    } else {
      since = null;
      limit = 250;
    }

    final response = NostrClient().ndk.requests.subscription(
          filter: Filter(
            kinds: [33301, 33302, 5],
            authors: [_signer!.getPublicKey()],
            since: since,
            limit: limit,
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

    if (since != null) unawaited(reconcile());
  }

  bool _reconciledThisSession = false;

  // The since-based subscription assumes the first drain got everything from
  // every relay; a relay that was unreachable back then leaves events below
  // the high-water mark that no later since-query can see. Re-pages the full
  // author history once per session and feeds it through the dedupe path.
  Future<void> reconcile() async {
    if (_reconciledThisSession) return;
    _reconciledThisSession = true;

    int until = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 1;
    while (_signer != null && _writeRelays.isNotEmpty) {
      List<Nip01Event> events;
      try {
        final response = NostrClient().ndk.requests.query(
              filter: Filter(
                kinds: [33301, 33302, 5],
                authors: [_signer!.getPublicKey()],
                limit: _olderHistoryBatchSize,
                until: until,
              ),
              explicitRelays: _writeRelays,
            );
        events = await response.future.timeout(const Duration(seconds: 20));
      } catch (_) {
        // Retry on a later sync; an aborted pass must not count as done
        _reconciledThisSession = false;
        return;
      }

      for (final event in events) {
        if (event.kind == 5) {
          await _onDeletionEvent(event);
        } else {
          await _onRelayEvent(event);
        }
      }

      if (events.length < _olderHistoryBatchSize) break;
      until = events.map((e) => e.createdAt).reduce(min) - 1;
    }
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
            parts.length == 3 && (parts[0] == '33301' || parts[0] == '33302'))
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
    final dTag =
        event.tags.where((t) => t.length >= 2 && t[0] == 'd').firstOrNull;
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
      final rawPlain = result.text;
      bool sensitive = false;
      final String? plain;
      if (rawPlain != null && kind == NoteKind.text) {
        final payload = _extractPayload(rawPlain);
        plain = payload.text;
        sensitive = payload.sensitive;
      } else {
        plain = rawPlain;
      }
      NoteAttachment? attachment;
      String? errorMsg;

      if (plain != null) {
        if (kind == NoteKind.file) {
          try {
            attachment = NoteAttachment.fromJson(
                jsonDecode(plain) as Map<String, dynamic>);
            sensitive = attachment.sensitive;
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

      if (_db != null) {
        await _db!.updateSyncedEdit(
          id: localId,
          nostrId: event.id,
          encryptedContent: event.content,
          localContent: localContent,
          editedAt: event.createdAt,
          sensitive: sensitive,
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
        sensitive: sensitive,
      );
      _emit();
      if (errorMsg != null) {
        Future.delayed(const Duration(seconds: 5), _retryPendingDecryptions);
      }
      return;
    }

    try {
      final result = await _decryptViaSigner(_signer!, event.content);
      final rawPlain = result.text;
      bool sensitive = false;
      final String? plain;
      if (rawPlain != null && kind == NoteKind.text) {
        final payload = _extractPayload(rawPlain);
        plain = payload.text;
        sensitive = payload.sensitive;
      } else {
        plain = rawPlain;
      }
      NoteAttachment? attachment;
      String? errorMsg;

      if (plain != null) {
        if (kind == NoteKind.file) {
          try {
            attachment = NoteAttachment.fromJson(
                jsonDecode(plain) as Map<String, dynamic>);
            sensitive = attachment.sensitive;
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
          sensitive: sensitive,
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
        sensitive: sensitive,
      );
      _emit();
      if (errorMsg != null) {
        Future.delayed(const Duration(seconds: 5), _retryPendingDecryptions);
      }
    } catch (_) {}
  }

  Future<void> _retryPendingDecryptions() async {
    if (_isRetrying) return;
    if (_db == null || _signer == null || _localKey == null) return;
    _isRetrying = true;

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

      bool sensitive = false;
      final String plain;
      if (kind == NoteKind.text) {
        final payload = _extractPayload(result.text!);
        plain = payload.text;
        sensitive = payload.sensitive;
      } else {
        plain = result.text!;
      }

      NoteAttachment? attachment;
      if (kind == NoteKind.file) {
        try {
          attachment = NoteAttachment.fromJson(
              jsonDecode(plain) as Map<String, dynamic>);
          sensitive = attachment.sensitive;
        } catch (_) {
          continue;
        }
      }

      final localContent = await LocalCrypto.encrypt(_localKey!, plain);
      // Persist the now-known sensitive flag without touching sync status
      await _db!.updateLocalContent(id, localContent, sensitive: sensitive);

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
        sensitive: sensitive,
      );
      retried++;
    }

    _isRetrying = false;
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

    final rowSensitive = (row['sensitive'] as int? ?? 0) == 1;

    final localEncoded = row['local_content'] as String?;
    if (localEncoded != null) {
      final plain = await LocalCrypto.decrypt(_localKey!, localEncoded);
      if (plain != null) {
        NoteAttachment? attachment;
        bool sensitive = rowSensitive;
        if (kind == NoteKind.file) {
          try {
            attachment = NoteAttachment.fromJson(
                jsonDecode(plain) as Map<String, dynamic>);
            sensitive = attachment.sensitive;
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
          sensitive: sensitive,
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

    bool sensitive = rowSensitive;
    final String plain;
    if (kind == NoteKind.text) {
      final payload = _extractPayload(result.text!);
      plain = payload.text;
      sensitive = payload.sensitive;
    } else {
      plain = result.text!;
    }
    NoteAttachment? attachment;
    if (kind == NoteKind.file) {
      try {
        attachment =
            NoteAttachment.fromJson(jsonDecode(plain) as Map<String, dynamic>);
        sensitive = attachment.sensitive;
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
      sensitive: sensitive,
    );
    _emit();
    return true;
  }

  Future<void> setSensitive(String id, bool sensitive) async {
    if (_localKey == null) return;
    final existing = _map[id];
    if (existing == null || existing.error != null) return;

    final now = DateTime.now();
    final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;

    if (existing.kind == NoteKind.file && existing.attachment != null) {
      final updatedAttachment =
          existing.attachment!.copyWith(sensitive: sensitive);
      _map[id] = DecryptedNote(
        id: id,
        nostrId: existing.nostrId,
        text: '',
        createdAt: existing.createdAt,
        editedAt: now,
        syncStatus: SyncStatus.pending,
        kind: NoteKind.file,
        attachment: updatedAttachment,
        sensitive: sensitive,
      );
      _emit();
      final localContent = await LocalCrypto.encrypt(
          _localKey!, updatedAttachment.toJsonString());
      if (_db != null) {
        await _db!.updateSensitive(
          id: id,
          sensitive: sensitive,
          editedAt: nowSeconds,
          localContent: localContent,
        );
      }
      _publishFileEvent(id, updatedAttachment, nowSeconds);
    } else {
      _map[id] = DecryptedNote(
        id: id,
        nostrId: existing.nostrId,
        text: existing.text,
        createdAt: existing.createdAt,
        editedAt: now,
        syncStatus: SyncStatus.pending,
        kind: existing.kind,
        sensitive: sensitive,
      );
      _emit();
      if (_db != null) {
        await _db!.updateSensitive(
          id: id,
          sensitive: sensitive,
          editedAt: nowSeconds,
        );
      }
      _publishToRelays(id, existing.text, nowSeconds, sensitive: sensitive);
    }
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
    if (nostrId != null)
      _broadcastDeletion(id, nostrId, note?.kind ?? NoteKind.text);
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

  Future<void> _broadcastDeletion(
      String localId, String nostrId, NoteKind kind) async {
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

  Future<void> syncOlderHistory() async {
    if (_writeRelays.isEmpty || _signer == null || _db == null) return;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_olderHistoryCompleteKey) == true) return;

    final oldestLocal = await _db!.getOldestCreatedAt();
    final thirtyDaysAgo =
        DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch ~/
            1000;
    int until =
        oldestLocal != null ? oldestLocal - 1 : thirtyDaysAgo - 1;

    loadingOlder.value = true;
    try {
      while (_signer != null && _writeRelays.isNotEmpty) {
        List<Nip01Event> events;
        try {
          final response = NostrClient().ndk.requests.query(
                filter: Filter(
                  kinds: [33301, 33302, 5],
                  authors: [_signer!.getPublicKey()],
                  limit: _olderHistoryBatchSize,
                  until: until,
                ),
                explicitRelays: _writeRelays,
              );
          events = await response.future.timeout(const Duration(seconds: 20));
        } on TimeoutException {
          break;
        } catch (_) {
          break;
        }

        for (final event in events) {
          if (event.kind == 5) {
            await _onDeletionEvent(event);
          } else {
            await _onRelayEvent(event);
          }
        }

        if (events.length < _olderHistoryBatchSize) {
          await prefs.setBool(_olderHistoryCompleteKey, true);
          break;
        }

        final oldestTs = events.map((e) => e.createdAt).reduce(min);
        until = oldestTs - 1;
      }
    } finally {
      loadingOlder.value = false;
    }
  }

  Future<void> clear() async {
    await _cancelRelaySubscription();
    _isRetrying = false;
    _reconciledThisSession = false;
    await _db?.deleteAll();
    _db = null;
    _signer = null;
    _writeRelays = [];
    _localKey = null;
    _fileCache.clear();
    _refusingServers.clear();
    _map.clear();
    _pendingDeletions.clear();
    notifier.value = [];
    loading.value = false;
    loadingOlder.value = false;
    promptFallbackRelays.value = false;
    promptFallbackBlossom.value = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_olderHistoryCompleteKey);
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

  // A pending status read from disk means a publish was interrupted; there is no
  // in-flight publish after a fresh load, so surface it as failed (retryable).
  static SyncStatus _loadedSyncStatus(int raw) {
    final s = SyncStatus.fromInt(raw);
    return s == SyncStatus.pending ? SyncStatus.failed : s;
  }

  // Marks a note failed in DB + memory; pending is transient, never terminal
  Future<void> _markSyncFailed(String localId) async {
    if (_db != null) {
      await _db!.updateSyncStatus(localId, SyncStatus.failed.value);
    }
    final existing = _map[localId];
    if (existing != null) {
      _map[localId] = _withSyncStatus(existing, SyncStatus.failed);
      _emit();
    }
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
        sensitive: n.sensitive,
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

  // Extracts text and sensitive flag from JSON payload {"text": "...", "sensitive": true}.
  // Falls back to raw string with sensitive=false for legacy plain-text payloads.
  static ({String text, bool sensitive}) _extractPayload(String decrypted) {
    try {
      final json = jsonDecode(decrypted) as Map<String, dynamic>;
      final t = json['text'];
      if (t is String) {
        return (text: t, sensitive: json['sensitive'] == true);
      }
    } catch (_) {}
    return (text: decrypted, sensitive: false);
  }

  // Computes a thumbhash from raw image bytes; returns base64 or null on error.
  // Returns thumbhash (base64) and dim ("WxH") for an image in one decode pass.
  static Future<({String? thumbhash, String? dim})> _computeImageInfo(
      Uint8List imageBytes) async {
    try {
      final codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final w = image.width;
      final h = image.height;
      final dim = '${w}x$h';

      // rgbaToThumbHash requires both dimensions ≤ 100px
      const maxSize = 100;
      final scale = maxSize / max(w, h);
      final tw = (w * scale).round().clamp(1, maxSize);
      final th = (h * scale).round().clamp(1, maxSize);

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        ui.Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
        ui.Paint(),
      );
      image.dispose();
      final scaled = await recorder.endRecording().toImage(tw, th);
      final byteData =
          await scaled.toByteData(format: ui.ImageByteFormat.rawRgba);
      scaled.dispose();
      if (byteData == null) return (thumbhash: null, dim: dim);
      final hash = rgbaToThumbHash(tw, th, byteData.buffer.asUint8List());
      return (thumbhash: base64Encode(hash), dim: dim);
    } catch (_) {
      return (thumbhash: null, dim: null);
    }
  }
}
