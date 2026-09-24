import '../../core/models/app_notification.dart';
import '../../core/models/gate_event.dart';
import '../../core/models/student.dart';
import '../../core/storage/local_store.dart';
import '../notifications/notifications_repository.dart';

class SafetyRepository {
  SafetyRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  String _today() {
    final d = DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String _nowTime() {
    final d = DateTime.now();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<List<GateEvent>> all() => _store.loadGateEvents();

  Future<List<GateEvent>> forDate(String date) async {
    final all = await _store.loadGateEvents();
    return all.where((e) => e.date == date).toList()
      ..sort((a, b) => b.time.compareTo(a.time));
  }

  Future<List<GateEvent>> forStudent(String studentId) async {
    final all = await _store.loadGateEvents();
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
    return event;
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