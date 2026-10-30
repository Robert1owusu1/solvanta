import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solvanta/core/api/api_client.dart';
import 'package:solvanta/core/api/remote_data_source.dart';
import 'package:solvanta/core/storage/data_store.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/features/auth/auth_repository.dart';

/// A school server that accepts everyone and logs out quietly.
RemoteDataSource _server(String userId) => RemoteDataSource(
      client: ApiClient(
        baseUrl: 'http://api.test',
        client: MockClient((req) async {
          if (req.url.path == '/auth/login') {
            return http.Response(
                jsonEncode({
                  'token': 'tok',
                  'user': {
                    'id': userId,
                    'name': 'Someone',
                    'email': 'someone@school.gh',
                    'role': 'teacher',
                    'schoolId': 'SCH-002',
                  },
                }),
                200);
          }
          return http.Response('{}', 200);
        }),
      ),
    );

Future<Set<String>> _dataKeys() async =>
    (await DataStore.instance()).dataKeys.toSet();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({'solvanta.themeMode': 'dark'});
    // Some school data on the device, written in demo mode.
    await LocalStore().loadStudents();
    await LocalStore().loadClasses();
  });
  tearDown(() => ApiClient.debugRuntimeApi = null);

  test('signing out of a school server removes its data, keeps preferences',
      () async {
    expect(await _dataKeys(), isNotEmpty);
    await AuthRepository(remote: _server('USR-1')).logout();
    expect(await _dataKeys(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('solvanta.themeMode'), 'dark');
  });

  test('offline-only, signing out keeps the data (the device is the only copy)',
      () async {
    final before = await _dataKeys();
    await AuthRepository().logout();
    expect(await _dataKeys(), before);
  });

  test("signing in as someone else clears the last account's data first",
      () async {
    await LocalStore().setDataOwner('USR-PREVIOUS');
    ApiClient.debugRuntimeApi = 'http://api.test';
    await AuthRepository(remote: _server('USR-NEW'))
        .login(email: 'someone@school.gh', password: 'x');
    expect(await LocalStore().dataOwner(), 'USR-NEW');
    // The previous account's students are gone; with a server nothing
    // demo-shaped refills the device.
    expect(await LocalStore().loadStudents(), isEmpty);
  });

  test('connected to a server, an empty device shows no demo school',
      () async {
    await LocalStore().clearSchoolData();
    ApiClient.debugRuntimeApi = 'http://api.test';
    expect(LocalStore.demoData, isFalse);
    expect(await LocalStore().loadStudents(), isEmpty);
    expect(await LocalStore().loadUsers(), isEmpty);
    expect(await LocalStore().loadSchool(), isNull);
    ApiClient.debugRuntimeApi = null;
    await LocalStore().clearSchoolData();
    expect(await LocalStore().loadStudents(), isNotEmpty); // demo mode again
  });
}
