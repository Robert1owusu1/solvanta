import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_client_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solvanta/core/models/student.dart';
import 'package:solvanta/core/storage/data_store.dart';
import 'package:solvanta/core/storage/data_store_open_io.dart';
import 'package:solvanta/core/storage/idb_backend.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<KvBackend> _sqlite() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(
          version: 1,
          singleInstance: false,
          onCreate: (db, _) => SqliteBackend.create(db)));
  return SqliteBackend(db);
}

void main() {
  tearDown(() => DataStore.use(null));

  for (final (name, open) in [
    ('SQLite', _sqlite),
    ('IndexedDB', () async => IdbBackend.open(newIdbFactoryMemory())),
  ]) {
    group(name, () {
      test('stores, replaces and removes values, and reloads them', () async {
        final backend = await open();
        final store = CachedDataStore(backend, await backend.loadAll());
        await store.setString('solvanta.students_v1', '[1]');
        await store.setString('solvanta.students_v1', '[2]');
        await store.setString('solvanta.term_v1', '{}');
        await store.remove('solvanta.term_v1');
        final reloaded = await backend.loadAll();
        expect(reloaded, {'solvanta.students_v1': '[2]'});
      });

      test('moves school data out of SharedPreferences, once', () async {
        SharedPreferences.setMockInitialValues({
          'solvanta.students_v1': '[{"from":"prefs"}]',
          'solvanta.fees_v1': '{"from":"prefs"}',
          'solvanta.themeMode': 'dark', // a preference: stays put
          'solvanta.session_user_id': 'USR-1', // the session: stays put
        });
        final prefs = await SharedPreferences.getInstance();
        final backend = await open();
        // Already in the database: the database wins.
        await backend.put('solvanta.fees_v1', '{"from":"db"}');
        final store = CachedDataStore(backend, await backend.loadAll());

        expect(await store.migrateFrom(prefs), 1);
        expect(store.getString('solvanta.students_v1'), '[{"from":"prefs"}]');
        expect(store.getString('solvanta.fees_v1'), '{"from":"db"}');
        expect(prefs.getString('solvanta.students_v1'), isNull);
        expect(prefs.getString('solvanta.fees_v1'), isNull);
        expect(prefs.getString('solvanta.themeMode'), 'dark');
        expect(prefs.getString('solvanta.session_user_id'), 'USR-1');
        expect(await store.migrateFrom(prefs), 0); // nothing left to move
      });
    });
  }

  test('only versioned school-data keys move', () {
    expect(DataStore.isDataKey('solvanta.students_v1'), isTrue);
    expect(DataStore.isDataKey('solvanta.targets_v1.USR-STU-001'), isTrue);
    expect(DataStore.isDataKey('solvanta.themeMode'), isFalse);
    expect(DataStore.isDataKey('solvanta.api_token'), isFalse);
    expect(DataStore.isDataKey('solvanta.nav.USR-1.pinned'), isFalse);
  });

  test('the app reads and writes its data through the database', () async {
    SharedPreferences.setMockInitialValues({});
    final backend = await _sqlite();
    DataStore.use(CachedDataStore(backend, {}));
    final store = LocalStore();
    final students = await store.loadStudents(); // seeds the demo school
    expect(students, isNotEmpty);
    await store.saveStudents([students.first]);
    final onDisk = await backend.loadAll();
    expect(onDisk['solvanta.students_v1'], contains(students.first.id));
    expect((await SharedPreferences.getInstance()).getKeys()
        .where(DataStore.isDataKey), isEmpty);
    expect((await store.loadStudents()).map((Student s) => s.id),
        [students.first.id]);
  });
}
