import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
    final path = p.join(dir.path, 'manent.db');

    _db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE notes (
            id TEXT PRIMARY KEY,
            nostr_id TEXT,
            created_at INTEGER NOT NULL,
            encrypted_content TEXT NOT NULL DEFAULT '',
            local_content TEXT,
            synced_to_relay INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE notes ADD COLUMN nostr_id TEXT');
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE notes ADD COLUMN local_content TEXT');
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
  }) async {
    final db = await _getDb();
    await db.insert('notes', {
      'id': id,
      'created_at': createdAt,
      'encrypted_content': '',
      'local_content': localContent,
      'synced_to_relay': 0,
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
  }) async {
    final db = await _getDb();
    await db.insert('notes', {
      'id': id,
      'nostr_id': nostrId,
      'created_at': createdAt,
      'encrypted_content': encryptedContent,
      'local_content': localContent,
      'synced_to_relay': 1,
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

  Future<void> updateSynced({
    required String localId,
    required String nostrId,
  }) async {
    final db = await _getDb();
    await db.update(
      'notes',
      {'synced_to_relay': 1, 'nostr_id': nostrId},
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

  Future<void> delete(String id) async {
    final db = await _getDb();
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }
}
