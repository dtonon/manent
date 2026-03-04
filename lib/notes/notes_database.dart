import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../app_flavor.dart';

class AppDatabase {
  AppDatabase._();
  static final instance = AppDatabase._();

  Database? _db;

  Future<Database> _getDb() async {
    if (_db != null) return _db!;

    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, AppFlavor.dbName);

    _db = await openDatabase(
      path,
      version: 5,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE notes (
            id TEXT PRIMARY KEY,
            nostr_id TEXT,
            created_at INTEGER NOT NULL,
            encrypted_content TEXT NOT NULL DEFAULT '',
            local_content TEXT,
            synced_to_relay INTEGER NOT NULL DEFAULT 0,
            edited_at INTEGER,
            kind INTEGER NOT NULL DEFAULT 33301
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE notes ADD COLUMN nostr_id TEXT');
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE notes ADD COLUMN local_content TEXT');
        }
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE notes ADD COLUMN edited_at INTEGER');
        }
        if (oldVersion < 5) {
          final cols = await db.rawQuery('PRAGMA table_info(notes)');
          final hasKind = cols.any((r) => r['name'] == 'kind');
          if (!hasKind) {
            await db.execute(
                'ALTER TABLE notes ADD COLUMN kind INTEGER NOT NULL DEFAULT 33301');
          }
        }
      },
    );
    return _db!;
  }

  Future<List<Map<String, Object?>>> getAll() async {
    final db = await _getDb();
    return db.query('notes', orderBy: 'created_at ASC');
  }

  Future<void> insert({
    required String id,
    required int createdAt,
    required String localContent,
    int kind = 33301,
  }) async {
    final db = await _getDb();
    await db.insert('notes', {
      'id': id,
      'created_at': createdAt,
      'encrypted_content': '',
      'local_content': localContent,
      'synced_to_relay': 0,
      'kind': kind,
    });
  }

  Future<int?> getLatestCreatedAt() async {
    final db = await _getDb();
    final rows = await db.rawQuery('SELECT MAX(created_at) AS ts FROM notes');
    return rows.first['ts'] as int?;
  }

  Future<bool> existsByNostrId(String nostrId) async {
    final db = await _getDb();
    final rows = await db.query(
      'notes',
      where: 'nostr_id = ?',
      whereArgs: [nostrId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> insertSynced({
    required String id,
    required String nostrId,
    required int createdAt,
    required String encryptedContent,
    String? localContent,
    int? editedAt,
    int kind = 33301,
  }) async {
    final db = await _getDb();
    await db.insert('notes', {
      'id': id,
      'nostr_id': nostrId,
      'created_at': createdAt,
      'encrypted_content': encryptedContent,
      'local_content': localContent,
      'edited_at': editedAt,
      'synced_to_relay': 1,
      'kind': kind,
    });
  }

  Future<void> updateEncryptedContent({
    required String localId,
    required String encryptedContent,
  }) async {
    final db = await _getDb();
    await db.update(
      'notes',
      {'encrypted_content': encryptedContent},
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> updateNostrId({
    required String localId,
    required String nostrId,
  }) async {
    final db = await _getDb();
    await db.update(
      'notes',
      {'nostr_id': nostrId},
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> updateSyncStatus(String localId, int status) async {
    final db = await _getDb();
    await db.update(
      'notes',
      {'synced_to_relay': status},
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> updateLocalContent(String id, String localContent) async {
    final db = await _getDb();
    await db.update(
      'notes',
      {'local_content': localContent},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Map<String, Object?>?> getById(String id) async {
    final db = await _getDb();
    final rows =
        await db.query('notes', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> delete(String id) async {
    final db = await _getDb();
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteAll() async {
    final db = await _getDb();
    await db.delete('notes');
  }

  // Sets local_content + edited_at + resets sync to pending, for local edits
  Future<void> updateForEdit({
    required String id,
    required String localContent,
    required int editedAt,
  }) async {
    final db = await _getDb();
    await db.update(
      'notes',
      {'local_content': localContent, 'edited_at': editedAt, 'synced_to_relay': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // Updates an existing row when a newer version arrives from relay (cross-device edit)
  Future<void> updateSyncedEdit({
    required String id,
    required String nostrId,
    required String encryptedContent,
    String? localContent,
    required int editedAt,
  }) async {
    final db = await _getDb();
    await db.update(
      'notes',
      {
        'nostr_id': nostrId,
        'encrypted_content': encryptedContent,
        'local_content': localContent,
        'edited_at': editedAt,
        'synced_to_relay': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
