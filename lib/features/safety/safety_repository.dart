import '../../core/api/api_client.dart';
import '../../core/api/remote_data_source.dart';
import '../../core/models/app_notification.dart';
import '../../core/models/gate_event.dart';
import '../../core/models/student.dart';
import '../../core/storage/local_store.dart';
import '../notifications/notifications_repository.dart';

/// Gate safety records (arrivals, departures, pickups) — local-first and
/// offline-safe. When a live API endpoint is configured, [record] also pushes
/// the event to the school's backend (best-effort; the offline outbox retries
/// mutating calls) and the read paths merge remote events, so a school with
/// several gate devices sees one trail.
class SafetyRepository {
  SafetyRepository({LocalStore? store, RemoteDataSource? remote})
      : _store = store ?? LocalStore(),
        _remote = remote ??
            (ApiClient.isConfigured ? RemoteDataSource() : null);

  final LocalStore _store;
  final RemoteDataSource? _remote;

  String _today() {
    final d = DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String _nowTime() {
    final d = DateTime.now();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// Local store + (in API mode) remote events merged by id, newest first.
  /// Best-effort: any failure falls back to the local copy untouched.
  Future<List<GateEvent>> _unified() async {
    final local = await _store.loadGateEvents();
    final remote = _remote;
    if (remote == null) return local;
    try {
      final remoteEvents = await remote.gateEvents();
      final byId = <String, GateEvent>{
        for (final e in [...local, ...remoteEvents]) e.id: e,
      };
      final merged = byId.values.toList()
        ..sort((a, b) => '${b.date}-${b.time}'.compareTo('${a.date}-${a.time}'));
      if (merged.length != local.length) {
        await _store.saveGateEvents(merged);
      }
      return merged;
    } on ApiException {
      return local;
    }
  }

  Future<List<GateEvent>> all() => _unified();

  Future<List<GateEvent>> forDate(String date) async {
    final all = await _unified();
    return all.where((e) => e.date == date).toList()
      ..sort((a, b) => b.time.compareTo(a.time));
  }

  Future<List<GateEvent>> forStudent(String studentId) async {
    final all = await _unified();
    return all.where((e) => e.studentId == studentId).toList()
      ..sort((a, b) => '${b.date}-${b.time}'.compareTo('${a.date}-${a.time}'));
  }

  Future<GateEvent> record({
    required String studentId,
    required GateEventType type,
    required String reporter,
    String? person,
    required String detail,
  }) async {
    final all = await _store.loadGateEvents();
    final students = await _store.loadStudents();
    final event = GateEvent(
      id: 'GATE-${DateTime.now().millisecondsSinceEpoch}',
      studentId: studentId,
      type: type,
      time: _nowTime(),
      date: _today(),
      reporter: reporter,
      person: person,
      detail: detail,
    );
    await _store.saveGateEvents([...all, event]);
    await _notify(students, event);
    return _pushRemote(event);
  }

  /// Best-effort push to the school's backend. Adopts the server-assigned id
  /// on success so the local store mirrors the server copy exactly (the id is
  /// the merge key — identical ids can never duplicate on later reads).
  /// Returns the effective event (server copy when adopted, the local one
  /// offline / on rejection).
  Future<GateEvent> _pushRemote(GateEvent event) async {
    final remote = _remote;
    if (remote == null) return event;
    try {
      final created = await remote.createGateEvent(event);
      if (created.id.isNotEmpty && created.id != event.id) {
        final current = await _store.loadGateEvents();
        final replaced =
            current.map((e) => e.id == event.id ? created : e).toList();
        await _store.saveGateEvents(replaced);
      }
      return created;
    } on ApiException {
      // Offline-first: the local copy stands and the outbox retries the POST
      // when connectivity returns; a remote rejection leaves the local trail
      // as the source of truth.
      return event;
    }
  }

  Future<void> _notify(List<Student> students, GateEvent event) async {
    final student = students.where((s) => s.id == event.studentId).firstOrNull;
    if (student == null) return;
    final parentId = student.parentUserId;
    final name = student.fullName;
    final notifications = NotificationsRepository(store: _store);
    switch (event.type) {
      case GateEventType.arrival:
        await notifications.push(
          kind: NotificationKind.gate,
          title: '$name arrived at school',
          body: 'Arrival verified at the gate at ${event.time}.',
          userId: parentId,
          studentId: event.studentId,
        );
      case GateEventType.departure:
        await notifications.push(
          kind: NotificationKind.gate,
          title: '$name left school',
          body: 'Departure verified at the gate at ${event.time}.',
          userId: parentId,
          studentId: event.studentId,
        );
      case GateEventType.pickupAuthorized:
        await notifications.push(
          kind: NotificationKind.gate,
          title: 'Pickup released — $name',
          body: '${event.person ?? 'A pickup person'} verified and released '
              '$name at ${event.time}.',
          userId: parentId,
          studentId: event.studentId,
        );
      case GateEventType.unauthorizedPickup:
        await notifications.push(
          kind: NotificationKind.gate,
          title: '⚠ Unauthorized pickup attempt — $name',
          body: '${event.person ?? 'A person'} tried to pick up $name but was '
              'NOT on the authorized list (${event.time}). Immediate review required.',
          userId: parentId,
          studentId: event.studentId,
        );
      case GateEventType.earlyDeparture:
        await notifications.push(
          kind: NotificationKind.gate,
          title: 'Early departure — $name',
          body: '$name left early at ${event.time}. ${event.detail}',
          userId: parentId,
          studentId: event.studentId,
        );
    }
  }
}