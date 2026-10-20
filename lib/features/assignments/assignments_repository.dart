import '../../core/models/app_notification.dart';
import '../../core/models/assignment.dart';
import '../../core/models/student.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';
import '../notifications/notifications_repository.dart';

class AssignmentsRepository {
  AssignmentsRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  Future<List<Assignment>> all() => _store.loadAssignments();

  Future<List<Assignment>> forClass(String classId) async {
    final all = await _store.loadAssignments();
    return all.where((a) => a.classId == classId).toList();
  }

  Future<void> create({
    required String classId,
    required String subjectId,
    required String title,
    required String instructions,
    required String deadline,
    required String createdBy,
  }) async {
    final all = await _store.loadAssignments();
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    final assignment = Assignment(
      id: 'ASG-${DateTime.now().millisecondsSinceEpoch}',
      classId: classId,
      subjectId: subjectId,
      title: title,
      instructions: instructions,
      deadline: deadline,
      createdBy: createdBy,
      createdAt: '${n.year}-${p(n.month)}-${p(n.day)}',
    );
    await _store.saveAssignments([assignment, ...all]);
    final saved = await ServerSync.instance.sendFor(
        'POST', '/api/assignments', assignment.toJson(), Assignment.fromJson);
    if (saved != null) {
      final now = await _store.loadAssignments();
      await _store.saveAssignments(
          [for (final a in now) a.id == assignment.id ? saved : a]);
    }
  }

  Future<void> delete(String id) async {
    final all = await _store.loadAssignments();
    await _store.saveAssignments(all.where((a) => a.id != id).toList());
    await ServerSync.instance.send('DELETE', '/api/assignments/$id');
  }

  Future<void> setCompleted(String id, Student student, bool completed) async {
    final all = await _store.loadAssignments();
    final without = all.where((a) => a.id != id).toList();
    final current = all.where((a) => a.id == id).firstOrNull;
    if (current == null) return;

    final done = completed && !current.completedBy.contains(student.id)
        ? [...current.completedBy, student.id]
        : current.completedBy;
    final undone = !completed
        ? current.completedBy.where((x) => x != student.id).toList()
        : done;
    final updated =
        current.copyWith(completedBy: !completed ? undone : done);
    await _store.saveAssignments([updated, ...without]);

    // The API records completion for the signed-in pupil only and has no
    // "undo"; an un-tick stays on this device until the next pull.
    if (completed) {
      await ServerSync.instance.send('POST', '/api/assignments/$id/complete',
          report: false);
    }

    if (completed && !ServerSync.instance.enabled) {
      await NotificationsRepository(store: _store).push(
        kind: NotificationKind.assignment,
        title: '${student.fullName} submitted an assignment',
        body: 'Completed "${updated.title}" — ${updated.instructions}',
        userId: student.parentUserId,
        studentId: student.id,
      );
    }
  }
}