import 'package:idb_shim/idb.dart';

import 'data_store.dart';

/// A `kv` object store in IndexedDB.
class IdbBackend implements KvBackend {
  IdbBackend(this._db);

  final Database _db;
  static const _store = 'kv';

  static Future<IdbBackend> open(IdbFactory factory) async {
    final db = await factory.open('solvanta', version: 1,
        onUpgradeNeeded: (VersionChangeEvent e) {
      if (!e.database.objectStoreNames.contains(_store)) {
        e.database.createObjectStore(_store);
      }
    });
    return IdbBackend(db);
  }

  @override
  Future<Map<String, String>> loadAll() async {
    final out = <String, String>{};
    final txn = _db.transaction(_store, idbModeReadOnly);
    await txn
        .objectStore(_store)
        .openCursor(autoAdvance: true)
        .forEach((c) => out[c.key as String] = c.value as String);
    await txn.completed;
    return out;
  }

  @override
  Future<void> put(String key, String value) async {
    final txn = _db.transaction(_store, idbModeReadWrite);
    await txn.objectStore(_store).put(value, key);
    await txn.completed;
  }

  @override
  Future<void> delete(String key) async {
    final txn = _db.transaction(_store, idbModeReadWrite);
    await txn.objectStore(_store).delete(key);
    await txn.completed;
  }
}
