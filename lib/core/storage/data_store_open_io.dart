import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'data_store.dart';

/// SQLite on Android, iOS and macOS; Linux and Windows desktop keep
/// SharedPreferences (a file on disk, without Android's rewrite cost).
Future<KvBackend?> openPlatformBackend() async {
  if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) return null;
  final db = await openDatabase(
    p.join(await getDatabasesPath(), 'solvanta.db'),
    version: 1,
    onCreate: (db, _) => SqliteBackend.create(db),
  );
  return SqliteBackend(db);
}

/// A `kv` table in SQLite.
class SqliteBackend implements KvBackend {
  SqliteBackend(this._db);

  final Database _db;

  static Future<void> create(Database db) => db.execute(
      'CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)');

  @override
  Future<Map<String, String>> loadAll() async => {
        for (final row in await _db.query('kv'))
          row['key'] as String: row['value'] as String,
      };

  @override
  Future<void> put(String key, String value) => _db.insert(
        'kv',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  @override
  Future<void> delete(String key) =>
      _db.delete('kv', where: 'key = ?', whereArgs: [key]);
}
