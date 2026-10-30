import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data_store_open_stub.dart'
    if (dart.library.io) 'data_store_open_io.dart'
    if (dart.library.js_interop) 'data_store_open_web.dart';

/// Where the app keeps the school's data on this device: an on-device
/// database — SQLite on Android, iOS and macOS, IndexedDB in the browser —
/// in place of SharedPreferences, which rewrites one whole file on every
/// change on Android and is capped near 5 MB in a browser (localStorage).
///
/// The interface is SharedPreferences' own (`getString`, `setString`,
/// `remove`) so storage code reads the same; like SharedPreferences, reads
/// come from an in-memory copy loaded once, and writes go through.
///
/// Small preferences (theme, lock, pinned menu items, the session) stay in
/// SharedPreferences. Linux/Windows desktop and the test suite keep
/// SharedPreferences for everything: neither has the size problem.
abstract class DataStore {
  /// The school-data keys held now.
  Iterable<String> get dataKeys;
  String? getString(String key);
  Future<bool> setString(String key, String value);
  Future<bool> remove(String key);

  static DataStore? _opened;

  /// The store to read and write the school's data through.
  static Future<DataStore> instance() async =>
      _opened ?? PrefsDataStore(await SharedPreferences.getInstance());

  /// Opens this platform's database (call once at startup) and moves any
  /// school data still in SharedPreferences into it. Any failure leaves the
  /// app on SharedPreferences, which always works.
  static Future<void> open() async {
    try {
      final backend = await openPlatformBackend();
      if (backend == null) return;
      final store = CachedDataStore(backend, await backend.loadAll());
      await store.migrateFrom(await SharedPreferences.getInstance());
      _opened = store;
    } catch (e) {
      debugPrint('[DataStore] staying on SharedPreferences: $e');
    }
  }

  /// School data keys are versioned (`solvanta.students_v1`); preferences
  /// (`solvanta.themeMode`, `solvanta.session_user_id`) are not.
  static bool isDataKey(String key) =>
      RegExp(r'^solvanta\.[a-z_]+_v\d+').hasMatch(key);

  /// Makes [store] the open store (null: back to SharedPreferences).
  @visibleForTesting
  static void use(DataStore? store) => _opened = store;
}

/// SharedPreferences as a [DataStore].
class PrefsDataStore implements DataStore {
  PrefsDataStore(this._prefs);

  final SharedPreferences _prefs;

  @override
  Iterable<String> get dataKeys => _prefs.getKeys().where(DataStore.isDataKey);

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  Future<bool> setString(String key, String value) =>
      _prefs.setString(key, value);

  @override
  Future<bool> remove(String key) => _prefs.remove(key);
}

/// A key–value table in some database.
abstract class KvBackend {
  Future<Map<String, String>> loadAll();
  Future<void> put(String key, String value);
  Future<void> delete(String key);
}

/// Reads from memory; writes to memory and the database.
class CachedDataStore implements DataStore {
  CachedDataStore(this._backend, this._cache);

  final KvBackend _backend;
  final Map<String, String> _cache;

  @override
  Iterable<String> get dataKeys => _cache.keys.where(DataStore.isDataKey);

  @override
  String? getString(String key) => _cache[key];

  @override
  Future<bool> setString(String key, String value) async {
    _cache[key] = value;
    await _backend.put(key, value);
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _cache.remove(key);
    await _backend.delete(key);
    return true;
  }

  /// Copies school data out of SharedPreferences (where earlier versions
  /// kept it) into the database, then removes it there — once. Data already
  /// in the database wins.
  Future<int> migrateFrom(SharedPreferences prefs) async {
    var moved = 0;
    for (final key in prefs.getKeys().where(DataStore.isDataKey).toList()) {
      final value = prefs.get(key);
      if (value is String && !_cache.containsKey(key)) {
        await setString(key, value);
        moved++;
      }
      await prefs.remove(key);
    }
    return moved;
  }
}
