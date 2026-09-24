import '../../core/models/attendance.dart';
import '../../core/models/app_notification.dart';
import '../../core/storage/local_store.dart';
import '../audit/audit_repository.dart';
import '../notifications/notifications_repository.dart';

class AttendanceRepository {
  AttendanceRepository({LocalStore? store})
      : _store = store ?? LocalStore();

  final LocalStore _store;

  Future<List<AttendanceRecord>> forClassDate(
      String classId, String date) async {
    final all = await _store.loadAttendance();
    return all
        .where((r) => r.classId == classId && r.date == date)
        .toList();
  }

  Future<List<String>> datesForClass(String classId) async {
    final all = await _store.loadAttendance();
    final dates = all
        .where((r) => r.classId == classId)
        .map((r) => r.date)
        .toSet()
        .toList();
    dates.sort();
    return dates;
  }

  Future<void> saveDay(
    String classId,
    String date,
    Map<String, AttendanceStatus> byStudent, {
    String? reason,
    String? actor,
  }) async {
    final all = await _store.loadAttendance();
    final otherDays =
        all.where((r) => !(r.classId == classId && r.date == date)).toList();
    // Merge, never replace: keep already-saved records for any student not in
    // [byStudent], so an edited or check-in record can't wipe the day's roll.
    final untouchedToday = all
        .where((r) =>
            r.classId == classId &&
            r.date == date &&
            !byStudent.containsKey(r.studentId))
        .toList();
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final records = [
      for (final e in byStudent.entries)
        AttendanceRecord(
          id: 'ATT-$date-${e.key}',
          studentId: e.key,
          classId: classId,
          date: date,
          status: e.value,
          checkIn: (e.value == AttendanceStatus.present ||
                  e.value == AttendanceStatus.late)
              ? '$hh:$mm'
              : null,
        ),
    ];
    await _store.saveAttendance([...otherDays, ...untouchedToday, ...records]);

    if (reason != null && reason.trim().isNotEmpty) {
      await AuditRepository().log(
        action: 'attendance.correction',
        actor: actor ?? 'Unknown user',
        target: 'Class $classId on $date',
        detail: '${records.length} attendance record(s) corrected for $date',
        reason: reason.trim(),
      );
    }

    final students = await _store.loadStudents();
    final studentsById = {for (final s in students) s.id: s};
    final flagged = records.where((r) =>
        r.status == AttendanceStatus.absent ||
        r.status == AttendanceStatus.late);
    final notifications = NotificationsRepository(store: _store);
    for (final r in flagged) {
      final student = studentsById[r.studentId];
      final parentId = student?.parentUserId;
      final statusWord = r.status == AttendanceStatus.absent
          ? 'was marked absent'
          : 'was marked late';
      await notifications.push(
        kind: NotificationKind.attendance,
        title: '${student?.fullName ?? r.studentId} ${r.status == AttendanceStatus.absent ? 'absent' : 'late'}',
        body: '${student?.fullName ?? r.studentId} $statusWord on $date.',
        userId: parentId,
        studentId: r.studentId,
      );
    }
  }

  Future<Map<String, List<AttendanceRecord>>> historyForStudent(
    String studentId,
  ) async {
    final all = await _store.loadAttendance();
    final mine = all
        .where((r) => r.studentId == studentId)
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final signal = <String>[];
    for (final r in mine) {
      if (!signal.contains(r.date)) {
        signal.add(r.date);
        if (signal.length == 5) break;
      }
    }
    return {
      for (final d in signal) d: mine.where((r) => r.date == d).toList(),
    };
  }

  Future<({int total, int present, int late, int absent, int excused})>
      summaryForStudent(String studentId) async {
    final all = await _store.loadAttendance();
    final mine = all.where((r) => r.studentId == studentId);
    int count(AttendanceStatus s) => mine.where((r) => r.status == s).length;
    return (
      total: mine.length,
      present: count(AttendanceStatus.present),
      late: count(AttendanceStatus.late),
      absent: count(AttendanceStatus.absent),
      excused: count(AttendanceStatus.excused),
    );
  }

  Future<({int total, int present})> summaryForClass(
    String classId,
    int lastDays,
  ) async {
    final all = await _store.loadAttendance();
    final mine = all.where((r) => r.classId == classId);
    return (
      total: mine.length,
      present:
          mine.where((r) => r.status == AttendanceStatus.present).length,
    );
  }
}