import '../../core/models/app_notification.dart';
import '../../core/models/announcement.dart';
import '../../core/models/assessment.dart';
import '../../core/models/assignment.dart';
import '../../core/models/attendance.dart';
import '../../core/models/audit.dart';
import '../../core/models/class_room.dart';
import '../../core/models/gate_event.dart';
import '../../core/models/intervention.dart';
import '../../core/models/message.dart';
import '../../core/models/question.dart';
import '../../core/models/school.dart';
import '../../core/models/school_term.dart';
import '../../core/models/student.dart';
import '../../core/models/user.dart';
import 'api_client.dart';

typedef JsonMap = Map<String, dynamic>;

/// Minimum subject shape served by `GET /api/subjects` (id + display name).
typedef SubjectInfo = ({String id, String name});

/// Login response from `POST /auth/login`.
typedef LoginResult = ({String token, User user});

class AttendanceSummary {
  const AttendanceSummary({
    required this.total,
    required this.present,
    required this.late,
    required this.absent,
    required this.excused,
    required this.percentage,
  });

  final int total;
  final int present;
  final int late;
  final int absent;
  final int excused;
  final double percentage;

  factory AttendanceSummary.fromJson(JsonMap json) => AttendanceSummary(
        total: (json['totalDays'] as num).toInt(),
        present: (json['present'] as num).toInt(),
        late: (json['late'] as num).toInt(),
        absent: (json['absent'] as num).toInt(),
        excused: (json['excused'] as num).toInt(),
        percentage: (json['percentage'] as num).toDouble(),
      );
}

/// One per-assessment result from the student-results analytics endpoint.
class StudentResult {
  const StudentResult({
    required this.assessment,
    required this.subject,
    required this.marks,
    required this.total,
    required this.percent,
    required this.grade,
  });

  final Assessment assessment;
  final String subject;
  final double marks;
  final double total;
  final double percent;
  final String grade;

  factory StudentResult.fromJson(JsonMap json) => StudentResult(
        assessment: Assessment.fromJson(json['assessment'] as JsonMap),
        subject: (json['subject'] ?? '') as String,
        marks: (json['marks'] as num).toDouble(),
        total: (json['total'] as num).toDouble(),
        percent: (json['percent'] as num).toDouble(),
        grade: (json['grade'] ?? '') as String,
      );
}

/// Typed read/view layer over the SOLVANTA REST API.
///
/// Method contracts mirror the app's repositories: every server payload is
/// parsed through the same core models the client persists locally, so a
/// remote response and a `LocalStore` seed decode to identical objects.
///
/// Offline note: reads (GETs) are never queued. Mutating calls are made
/// through `ApiClient.request(...)` with explicit `offlineQueue` /
/// `syncKind` / `syncPayload` control — network failures then land in the
/// sync outbox (`lib/core/sync/`) and replay when connectivity returns.
/// See [login] and [logout] for the pattern to copy on new mutating
/// endpoints.
class RemoteDataSource {
  RemoteDataSource({String? baseUrl, ApiClient? client})
      : client = client ?? ApiClient(baseUrl: baseUrl);

  final ApiClient client;

  // --- Health / auth -----------------------------------------------------

  Future<bool> health() async {
    final res = await client.get('/health') as JsonMap;
    return res['status'] == 'ok';
  }

  Future<LoginResult> login({
    required String email,
    required String password,
    bool? offlineQueue,
    String? syncKind,
    Map<String, dynamic>? syncPayload,
  }) async {
    // Auth paths are excluded from automatic outbox capture (a persisted
    // password would be a leak); pass `offlineQueue: true` to opt in
    // explicitly — null keeps the client default.
    final res = await client.request(
      'POST',
      '/auth/login',
      body: {
        'email': email,
        'password': password,
      },
      offlineQueue: offlineQueue,
      syncKind: syncKind,
      syncPayload: syncPayload,
    ) as JsonMap;
    final token = res['token'] as String;
    client.token = token;
    return (token: token, user: User.fromJson(res['user'] as JsonMap));
  }

  Future<void> logout({
    bool? offlineQueue,
    String? syncKind,
    Map<String, dynamic>? syncPayload,
  }) async {
    try {
      await client.request(
        'POST',
        '/auth/logout',
        offlineQueue: offlineQueue,
        syncKind: syncKind,
        syncPayload: syncPayload,
      );
    } finally {
      client.token = null;
    }
  }

  Future<User?> currentUser() async {
    final res = await client.get('/auth/me') as JsonMap;
    return res.containsKey('user') && res['user'] != null
        ? User.fromJson(res['user'] as JsonMap)
        : null;
  }

  // --- Registry & school ---------------------------------------------------

  Future<List<SubjectInfo>> subjects() async =>
      ((await client.get('/api/subjects')) as List)
          .map((e) {
            final m = e as JsonMap;
            return (id: m['id'] as String, name: (m['name'] ?? '') as String);
          })
          .toList();

  Future<School> school() async =>
      School.fromJson(await client.get('/api/school') as JsonMap);

  Future<SchoolTerm> term() async =>
      SchoolTerm.fromJson(await client.get('/api/school/term') as JsonMap);

  Future<List<ClassRoom>> classes() async => ((await client.get(
          '/api/school/classes')) as List)
      .map((e) => ClassRoom.fromJson(e as JsonMap))
      .toList();

  // --- Users / students -----------------------------------------------------

  Future<List<User>> users() async => ((await client.get('/api/users')) as List)
      .map((e) => User.fromJson(e as JsonMap))
      .toList();

  Future<List<Student>> students() async =>
      ((await client.get('/api/students')) as List)
          .map((e) => Student.fromJson(e as JsonMap))
          .toList();

  Future<Student> student(String id) async =>
      Student.fromJson(await client.get('/api/students/$id') as JsonMap);

  // --- Attendance -----------------------------------------------------------

  Future<List<AttendanceRecord>> attendanceForClassDate(
    String classId,
    String date,
  ) async =>
      ((await client.get('/api/attendance/class/$classId/date/$date')) as List)
          .map((e) => AttendanceRecord.fromJson(e as JsonMap))
          .toList();

  /// Groups every attendance record from `GET /api/attendance/students/:id/history`
/// by date, mirroring the app repository's `historyForStudent` shape.
  Future<Map<String, List<AttendanceRecord>>> attendanceHistoryForStudent(
    String studentId,
  ) async {
    final res = await client.get('/api/attendance/students/$studentId/history')
        as List;
    final out = <String, List<AttendanceRecord>>{};
    for (final e in res) {
      final r = AttendanceRecord.fromJson(e as JsonMap);
      out.putIfAbsent(r.date, () => []).add(r);
    }
    return out;
  }

  Future<AttendanceSummary> attendanceSummaryForStudent(String studentId) async =>
      AttendanceSummary.fromJson(
        await client.get('/api/attendance/students/$studentId/summary')
            as JsonMap,
      );

  // --- Gate -----------------------------------------------------------------

  Future<List<GateEvent>> gateEvents() async =>
      ((await client.get('/api/gate/events')) as List)
          .map((e) => GateEvent.fromJson(e as JsonMap))
          .toList();

  /// Records a gate event (arrival / departure / pickup). Mutating, so the
  /// offline outbox retries it automatically when connectivity returns.
  Future<GateEvent> createGateEvent(GateEvent event) async {
    final res = await client.post('/api/gate/events', event.toJson());
    return GateEvent.fromJson(res as JsonMap);
  }

  // --- Question bank & assessments --------------------------------------------

  Future<List<Question>> questions() async =>
      ((await client.get('/api/questions')) as List)
          .map((e) => Question.fromJson(e as JsonMap))
          .toList();

  Future<List<Assessment>> assessments() async =>
      ((await client.get('/api/assessments')) as List)
          .map((e) => Assessment.fromJson(e as JsonMap))
          .toList();

  Future<Assessment> assessment(String id) async {
    final res = await client.get('/api/assessments/$id') as JsonMap;
    return Assessment.fromJson(res['assessment'] as JsonMap);
  }

  Future<List<StudentResult>> resultsForStudent(String studentId) async =>
      ((await client.get('/api/analytics/students/$studentId/results')) as List)
          .map((e) => StudentResult.fromJson(e as JsonMap))
          .toList();

  // --- Interventions / comms / assignments / audit -----------------------------

  Future<List<Intervention>> interventions() async =>
      ((await client.get('/api/interventions')) as List)
          .map((e) => Intervention.fromJson(e as JsonMap))
          .toList();

  Future<List<Announcement>> announcements() async =>
      ((await client.get('/api/announcements')) as List)
          .map((e) => Announcement.fromJson(e as JsonMap))
          .toList();

  Future<List<Message>> messages() async =>
      ((await client.get('/api/messages')) as List)
          .map((e) => Message.fromJson(e as JsonMap))
          .toList();

  Future<List<AppNotification>> unreadNotifications() async =>
      ((await client.get('/api/notifications/unread')) as List)
          .map((e) => AppNotification.fromJson(e as JsonMap))
          .toList();

  Future<List<Assignment>> assignments() async =>
      ((await client.get('/api/assignments')) as List)
          .map((e) => Assignment.fromJson(e as JsonMap))
          .toList();

  Future<List<AuditEntry>> auditLogs() async =>
      ((await client.get('/api/audit')) as List)
          .map((e) => AuditEntry.fromJson(e as JsonMap))
          .toList();
}