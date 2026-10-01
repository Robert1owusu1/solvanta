import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/api/api_client.dart';
import 'package:solvanta/core/sync/sync_queue.dart';

/// Regression guards for the "signed in but not authenticated" write path.
///
/// The offline outbox used to capture *transport* failures only. A request
/// rejected with 401/403 never reached `SyncQueue`, and every caller handled
/// the `ApiException` by falling back to its local copy — so once a token
/// expired the app kept saving locally, kept telling the operator the record
/// was verified, and the server never received it. Nothing was queued,
/// nothing was retried, nothing appeared in the sync banner.
///
/// The fix has two halves, both pinned here:
///
///  * `_send` queues a 401/403 on a *mutating* request (still rethrowing, so
///    callers see the real status code);
///  * `_replaySyncItem` no longer discards those items on replay — a session
///    that is merely stale will accept the payload after a sign-in.
///
/// Rejections that can never succeed (400/404/…) must stay out of the queue,
/// and `/auth/*` must never queue at all, because those payloads carry
/// passwords.

/// Answers whatever the client sends, so a single [ApiClient] — and therefore
/// a single registered replay handler — can behave differently per test.
class _Backend {
  int status = 200;
  String body = '{}';
}

final _backend = _Backend();
late ApiClient _client;

/// The path a gate event takes when the session has expired.
Future<void> _postGateEvent() => _client.post('/api/gate/events', {
      'id': 'GATE-TEST-1',
      'studentId': 'STU-002',
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    // One client for the whole file: `registerHandler` is first-wins, so the
    // replay path under test is always bound to this client's mock transport.
    _client = ApiClient(
      baseUrl: 'http://solvanta.test',
      client: MockClient(
        (request) async => http.Response(_backend.body, _backend.status),
      ),
    );
  });

  tearDownAll(() {
    _client.close();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ApiClient.sharedToken = null;
    await SyncQueue.instance.clear();
    _backend.status = 200;
    _backend.body = '{}';
  });

  group('expired session (401)', () {
    test('queues the mutation for retry and still reports 401 to the caller',
        () async {
      _backend.status = 401;
      _backend.body = '{"error":"Invalid or expired token"}';

      await expectLater(
        // The caller must still learn the request failed.
        _postGateEvent(),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 401)),
      );

      expect(
        SyncQueue.instance.pendingCount,
        1,
        reason: 'the record must survive an expired token, not vanish',
      );
      final pending = await SyncQueue.instance.pending();
      expect(pending.single.kind, 'api.post /api/gate/events');
      expect(pending.single.payload['path'], '/api/gate/events');
      expect(pending.single.payload['body'], containsPair('id', 'GATE-TEST-1'));
    });

    test('keeps the item on replay instead of dropping it', () async {
      _backend.status = 401;
      _backend.body = '{"error":"Invalid or expired token"}';

      await expectLater(_postGateEvent(), throwsA(isA<ApiException>()));
      expect(SyncQueue.instance.pendingCount, 1);

      await SyncQueue.instance.flush(ignoreBackoff: true);

      expect(
        SyncQueue.instance.pendingCount,
        1,
        reason: 'dropping it would lose the school record for good',
      );
      final pending = await SyncQueue.instance.pending();
      expect(
        pending.single.lastError,
        contains('401'),
        reason: 'the queue should carry the real reason for the failure',
      );
    });

    test('a permanently rejected payload is still dropped on replay', () async {
      // Queue it the way an outage would have (transport failure), then have
      // the server reject the payload outright: retrying forever would poison
      // the outbox.
      await SyncQueue.instance.enqueue('api.post /api/gate/events', {
        'method': 'POST',
        'path': '/api/gate/events',
        'body': {'nonsense': true},
      });
      expect(SyncQueue.instance.pendingCount, 1);

      _backend.status = 400;
      _backend.body = '{"error":"malformed event"}';

      await SyncQueue.instance.flush(ignoreBackoff: true);

      expect(SyncQueue.instance.pendingCount, 0);
    });
  });

  group('forbidden (403)', () {
    test('queues the mutation rather than swallowing it', () async {
      _backend.status = 403;
      _backend.body = '{"error":"role cannot save attendance"}';

      await expectLater(
        _client.post('/api/attendance/check-in', {'studentId': 'STU-002'}),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403)),
      );

      expect(SyncQueue.instance.pendingCount, 1);
      final pending = await SyncQueue.instance.pending();
      expect(pending.single.payload['path'], '/api/attendance/check-in');
    });
  });

  group('must never be queued', () {
    test('a rejected login — the payload carries a password', () async {
      _backend.status = 401;
      _backend.body = '{"error":"Invalid credentials"}';

      await expectLater(
        _client.post('/auth/login', {
          'email': 'ama@school.gh',
          'password': 'hunter2',
        }),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401)),
      );

      expect(SyncQueue.instance.pendingCount, 0,
          reason: 'credentials must never reach the outbox');
      final raw = await SharedPreferences.getInstance();
      expect(raw.getString(SyncQueue.storageKey),
          anyOf(isNull, isNot(contains('hunter2'))));
    });

    test('a rejected read — reads are re-fetchable', () async {
      _backend.status = 401;

      await expectLater(
        _client.get('/api/users'),
        throwsA(isA<ApiException>()),
      );

      expect(SyncQueue.instance.pendingCount, 0);
    });

    test('a 400 on a mutation — replaying can never succeed', () async {
      _backend.status = 400;
      _backend.body = '{"error":"malformed event"}';

      await expectLater(
        _postGateEvent(),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 400)),
      );

      expect(SyncQueue.instance.pendingCount, 0);
    });
  });
}
