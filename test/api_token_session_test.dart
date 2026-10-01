import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/app.dart';
import 'package:solvanta/core/api/api_client.dart';
import 'package:solvanta/core/api/remote_data_source.dart';
import 'package:solvanta/core/models/role.dart';
import 'package:solvanta/core/models/user.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/features/auth/auth_repository.dart';

/// Regression guard for the "signed in but never authenticated" bug.
///
/// `ApiClient.sharedToken` is a plain static that dies with the process, so a
/// login that persisted only the session id left every cold start sending
/// requests with no `Authorization` header. The backend correctly answered
/// 401, but the offline-first read paths kept serving the local copy — the app
/// looked healthy, showed arrival confirmations to the operator, and never
/// synced a single write. Both halves are covered here: the token has to
/// survive the process, and startup has to republish it before anything talks
/// to the network.

/// A teacher, so the session is also valid for gate writes.
const _teacher = User(
  id: 'USR-TCH-001',
  name: 'Ms Teacher',
  email: 'teacher@school.gh',
  phone: '0200000000',
  password: '',
  role: AppRole.teacher,
);

/// Stands in for the backend: issues a fixed token without touching the net.
class _FakeRemote extends RemoteDataSource {
  _FakeRemote(this.issuedToken) : super();

  final String issuedToken;

  @override
  Future<LoginResult> login({
    required String email,
    required String password,
    bool? offlineQueue,
    String? syncKind,
    Map<String, dynamic>? syncPayload,
  }) async {
    // Mirrors the real method, which publishes the token to the shared
    // session before returning — every other ApiClient picks it up from there.
    client.token = issuedToken;
    return (token: issuedToken, user: _teacher);
  }

  @override
  Future<void> logout({
    bool? offlineQueue,
    String? syncKind,
    Map<String, dynamic>? syncPayload,
  }) async {
    // Mirrors the real method's `finally` without a network round-trip.
    client.token = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.sharedToken = null;
  });

  group('persisted API token', () {
    test('round-trips through the store and clears on null/empty', () async {
      final store = LocalStore();
      expect(await store.getApiToken(), isNull);

      await store.setApiToken('tok-1');
      expect(await store.getApiToken(), 'tok-1');

      // Both "signed out" paths must actually remove it, not leave a stale
      // token for the next account to present.
      await store.setApiToken(null);
      expect(await store.getApiToken(), isNull);

      await store.setApiToken('tok-2');
      await store.setApiToken('');
      expect(await store.getApiToken(), isNull);
    });

    test('a remote login persists the token it was issued', () async {
      final store = LocalStore();
      final auth =
          AuthRepository(store: store, remote: _FakeRemote('tok-live'));

      final user =
          await auth.login(email: 'teacher@school.gh', password: 'x');
      expect(user, isNotNull);

      // The token must outlive this process — that is the whole fix.
      expect(await store.getApiToken(), 'tok-live');
      expect(ApiClient.sharedToken, 'tok-live');
    });

    test('logout drops the token along with the session', () async {
      final store = LocalStore();
      final auth =
          AuthRepository(store: store, remote: _FakeRemote('tok-live'));
      await auth.login(email: 'teacher@school.gh', password: 'x');
      expect(await store.getApiToken(), 'tok-live');

      await auth.logout();

      expect(await store.getSessionUserId(), isNull);
      expect(await store.getApiToken(), isNull);
      // Otherwise the next account to sign in would start out presenting the
      // previous one's token.
      expect(ApiClient.sharedToken, isNull);
    });
  });

  group('cold start', () {
    testWidgets('republishes a persisted token', (tester) async {
      SharedPreferences.setMockInitialValues({
        'solvanta.api_token': 'tok-restored',
      });
      ApiClient.sharedToken = null;

      await tester.pumpWidget(const SolvantaApp());
      await tester.pumpAndSettle();

      expect(ApiClient.sharedToken, 'tok-restored');
    });

    testWidgets('stays unauthenticated when no token was stored',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      ApiClient.sharedToken = null;

      await tester.pumpWidget(const SolvantaApp());
      await tester.pumpAndSettle();

      expect(ApiClient.sharedToken, isNull);
    });
  });
}
