import '../../core/models/parent_meeting.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';

/// Parent meetings: saved on this device, then sent to the server, which
/// tells the family when one is booked.
class ParentMeetingsRepository {
  ParentMeetingsRepository({LocalStore? store})
      : _store = store ?? LocalStore();

  final LocalStore _store;

  Future<List<ParentMeeting>> all() => _store.loadParentMeetings();

  Future<List<ParentMeeting>> forStudent(String studentId) async => [
        for (final m in await all())
          if (m.studentId == studentId) m,
      ];

  Future<void> save(ParentMeeting meeting) async {
    final all = await _store.loadParentMeetings();
    await _store.saveParentMeetings([
      for (final m in all)
        if (m.id != meeting.id) m,
      meeting,
    ]);
    await ServerSync.instance.send(
        'PUT', '/api/records/parent_meetings/${meeting.id}',
        body: meeting.toJson());
  }

  /// Requests a meeting about [studentId] for [term], unless one is already
  /// open for that term. Returns the open meeting.
  Future<ParentMeeting> request({
    required String studentId,
    required String classId,
    required String year,
    required String term,
    required String reason,
    required String requestedBy,
  }) async {
    final open = (await forStudent(studentId))
        .where((m) => m.year == year && m.term == term && m.status.open)
        .firstOrNull;
    if (open != null) return open;
    final meeting = ParentMeeting(
      id: 'MEET-${DateTime.now().millisecondsSinceEpoch}-$studentId',
      studentId: studentId,
      classId: classId,
      year: year,
      term: term,
      reason: reason,
      requestedBy: requestedBy,
    );
    await save(meeting);
    return meeting;
  }
}
