import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/api/api_client.dart';
import 'package:solvanta/core/api/remote_data_source.dart';
import 'package:solvanta/core/models/gate_event.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/features/safety/safety_repository.dart';

/// Gate events wired to the backend (API mode): record pushes to the remote
/// and adopts the server id; reads merge remote + local by id; any remote
/// failure keeps the local trail authoritative (offline-first).
class _FakeRemote extends RemoteDataSource {
  _FakeRemote({this.failPush = false, this.failRead = false})
      : super(client: ApiClient());

  final bool failPush;
  final bool failRead;
  final List<GateEvent> pushed = [];
  List<GateEvent> remoteEvents = [];

  @override
  Future<List<GateEvent>> gateEvents() async {
    if (failRead) throw ApiException(0, 'unreachable');
    return List.of(remoteEvents);
  }

  @override
  Future<GateEvent> createGateEvent(GateEvent event) async {
    if (failPush) throw ApiException(503, 'down');
    pushed.add(event);
    final server = GateEvent(
      id: 'GATE-SRV-001',
      studentId: event.studentId,
      type: event.type,
      time: event.time,
      date: event.date,
      reporter: event.reporter,
      person: event.person,
      detail: event.detail,
    );
    remoteEvents.add(server);
    return server;
  }
}

GateEvent _event({
  String id = 'GATE-LOC-001',
  String studentId = 'STU-002',
  String date = '2026-09-24',
  String time = '08:00',
}) =>
    GateEvent(
      id: id,
      studentId: studentId,
      type: GateEventType.arrival,
      time: time,
      date: date,
      reporter: 'Gate Staff',
      detail: 'ID check-in verified at gate',
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('record pushes to the backend in API mode and adopts the server id',
      () async {
    final store = LocalStore();
    final fake = _FakeRemote();
    final repo = SafetyRepository(store: store, remote: fake);

    final effective = await repo.record(
      studentId: 'STU-002',
      type: GateEventType.arrival,
      reporter: 'Gate Staff',
      detail: 'ID check-in verified at gate',
    );

    expect(fake.pushed, hasLength(1));
    expect(effective.id, 'GATE-SRV-001',
        reason: 'the authoritative event carries the server-assigned id');
    final stored = await store.loadGateEvents();
    expect(stored.map((e) => e.id), contains('GATE-SRV-001'),
        reason: 'local store mirrors the server copy so reads can dedupe');
  });

  test('reads merge remote and local trails by id without duplicates', () async {
    final store = LocalStore();
    final fake = _FakeRemote()
      ..remoteEvents = [
        _event(id: 'GATE-RMT-001', studentId: 'STU-003', time: '07:55'),
        _event(id: 'GATE-LOC-001', studentId: 'STU-002', time: '08:00'),
      ];
    final repo = SafetyRepository(store: store, remote: fake);
    await repo.record(
      studentId: 'STU-002',
      type: GateEventType.arrival,
      reporter: 'Gate Staff',
      detail: 'ID check-in verified at gate',
    );

    final all = await repo.all();
    final ids = all.map((e) => e.id).toList();
    expect(ids, containsAll(['GATE-SRV-001', 'GATE-RMT-001']));
    expect(ids.toSet().length, ids.length,
        reason: 'no duplicate ids after the merge');
  });

  test('remote outage keeps record local and does not throw', () async {
    final store = LocalStore();
    final fake = _FakeRemote(failPush: true);
    final repo = SafetyRepository(store: store, remote: fake);

    final effective = await repo.record(
      studentId: 'STU-002',
      type: GateEventType.arrival,
      reporter: 'Gate Staff',
      detail: 'ID check-in verified at gate',
    );

    expect(effective.id, isNot('GATE-SRV-001'));
    expect((await store.loadGateEvents()).map((e) => e.id),
        contains(effective.id));
  });

  test('a failing remote read falls back to the local trail', () async {
    final store = LocalStore();
    final fake = _FakeRemote(failRead: true);
    final repo = SafetyRepository(store: store, remote: fake);
    await repo.record(
      studentId: 'STU-002',
      type: GateEventType.arrival,
      reporter: 'Gate Staff',
      detail: 'ID check-in verified at gate',
    );

    expect(await repo.forDate('2026-09-24'), isNotEmpty);
    expect(await repo.all(), isNotEmpty);
  });

  test('without a remote, record is purely local (no push)', () async {
    final store = LocalStore();
    final before = (await store.loadGateEvents()).length;
    final repo = SafetyRepository(store: store, remote: null);

    final effective = await repo.record(
      studentId: 'STU-001',
      type: GateEventType.arrival,
      reporter: 'Gate Staff',
      detail: 'ID check-in verified at gate',
    );
    final stored = await store.loadGateEvents();
    expect(stored.length, before + 1,
        reason: 'exactly one event is appended to the existing trail');
    expect(stored.last.studentId, 'STU-001');
    expect(stored.last.id, effective.id);
  });
}