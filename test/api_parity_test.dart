import 'package:flutter_test/flutter_test.dart';
import 'package:solvanta/core/models/subjects.dart' as app_subjects;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/api/api_client.dart';
import 'package:solvanta/core/api/remote_data_source.dart';
import 'package:solvanta/core/models/audit.dart';
import 'package:solvanta/core/models/role.dart';
import 'package:solvanta/core/models/school_term.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/core/storage/phase6_store.dart';

/// Live-backend parity suite.
///
/// Run against a running SOLVANTA backend:
///   cd backend && go run ./cmd/server          # in one terminal
///   SOLVANTA_API_URL=http://127.0.0.1:8080 flutter test test/api_parity_test.dart
///
/// Everything is skipped when no endpoint is configured, so `flutter test`
/// stays green in CI without a server. When run, every server payload is
/// decoded through the app's own core models and cross-checked against the
/// dataset the app seeds into LocalStore — proving the wire contract and the
/// local seed agree. Demo accounts authenticate once in [setUpAll] so the
/// suite respects the backend's per-IP login rate limit.
void main() {
  final base = ApiClient.defaultApiBaseUrl();
  // Whole suite self-skips unless an endpoint is configured.
  final skip = !ApiClient.isConfigured;

  late RemoteDataSource superDs;
  late RemoteDataSource admin;
  late RemoteDataSource head;
  late RemoteDataSource teacher;
  late RemoteDataSource parent;
  late RemoteDataSource student;

  setUpAll(() async {
    if (skip) return;
    Future<RemoteDataSource> ds(String email, String pw) async {
      final r = RemoteDataSource(baseUrl: base);
      await r.login(email: email, password: pw);
      return r;
    }

    superDs = await ds('super@solvanta.app', 'super123');
    admin = await ds('admin@solvanta.app', 'admin123');
    head = await ds('head@school.gh', 'head123');
    teacher = await ds('efua.mensah@school.gh', 'teacher123');
    parent = await ds('ama.owusu@school.gh', 'parent123');
    student = await ds('kojo.owusu@school.gh', 'student123');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('auth', () {
    test('demo users map to expected ids/roles and never leak passwords',
        skip: skip, () async {
      final expectations = {
        superDs: (AppRole.superAdmin, 'USR-SUPER'),
        admin: (AppRole.schoolAdmin, 'USR-ADM-001'),
        head: (AppRole.headteacher, 'USR-HRT-001'),
        teacher: (AppRole.teacher, 'USR-TCH-001'),
        parent: (AppRole.parent, 'USR-PRN-001'),
        student: (AppRole.student, 'USR-STU-001'),
      };
      for (final entry in expectations.entries) {
        final (role, expectedId) = entry.value;
        final me = await entry.key.currentUser();
        expect(me, isNotNull);
        expect(me!.id, expectedId);
        expect(me.role, role);
        expect(me.password, isEmpty,
            reason: 'API must not leak plaintext passwords');
      }

      // Parent link must round-trip remotely.
      final p = await parent.currentUser();
      expect(p!.studentIds, contains('STU-001'));
    });

    test('bad credentials are rejected with 401', skip: skip, () async {
      final client = ApiClient(baseUrl: base);
      await expectLater(
        client.post('/auth/login', {
          'email': 'kojo.owusu@school.gh',
          'password': 'wrong-password',
        }),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.message, 'message', contains('Invalid'))),
      );
      client.close();
    });

    test('role-based read guard: student cannot list users', skip: skip,
        () async {
      await expectLater(
        () => student.users(),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 403)),
      );
    });
  });

  group('payload parity (local seed == remote store)', () {
    test('students: 8 records decode and match the app seed in detail',
        skip: skip, () async {
      final app = await LocalStore().loadStudents();
      final remote = await admin.students();
      expect(remote.map((s) => s.id).toList()..sort(),
          app.map((s) => s.id).toList()..sort());

      final kojo = remote.firstWhere((s) => s.id == 'STU-001');
      expect(kojo.firstName, 'Kojo');
      expect(kojo.lastName, 'Owusu');
      expect(kojo.parentUserId, 'USR-PRN-001');
      expect(kojo.guardians.length, 2, reason: 'guardians');
      expect(kojo.emergencyContacts.length, 1, reason: 'emergency contacts');
      expect(kojo.authorizedPickup.length, 2, reason: 'authorized pickup');
    });

    test('classes, subjects and term agree with the app', skip: skip,
        () async {
      final appClasses = await LocalStore().loadClasses();
      expect((await admin.classes()).length, appClasses.length);

      final subjects = await admin.subjects();
      expect(subjects.map((s) => s.id).toList(),
          app_subjects.subjects.map((s) => s.id).toList());
      expect(subjects.every((s) => s.name.isNotEmpty), isTrue);

      final term = await admin.term();
      expect(term.year, SchoolTerm.fallback.year);
      expect(term.name, SchoolTerm.fallback.name);
      expect(term.start, SchoolTerm.fallback.start);
      expect(term.end, SchoolTerm.fallback.end);
    });

    test('question bank and assessments decode and match app seed', skip: skip,
        () async {
      final appBank = await LocalStore().loadQuestionBank();
      final appAssessmentIds =
          (await LocalStore().loadAssessments()).map((a) => a.id).toSet();

      final bank = await admin.questions();
      expect(bank.length, appBank.length);
      expect(bank.map((q) => q.id).toList()..sort(),
          appBank.map((q) => q.id).toList()..sort());

      final assessments = await admin.assessments();
      expect(assessments.map((a) => a.id).toSet(), {
        'ASSMT-MAT-HALF',
        'ASSMT-ENG-T1',
        'ASSMT-MOCK-BECE-MATH',
        'ASSMT-MOCK-BECE-ENG',
      });
      // every backend assessment (incl. embedded questions) must be present in
      // the app's merged seed (base + permanently re-added mocks).
      expect(assessments.map((a) => a.id).toSet().difference(appAssessmentIds),
          isEmpty);
      for (final a in assessments) {
        expect(a.questions, isNotEmpty, reason: '${a.id} embeds questions');
      }

      // delegated read: single-assessment detail round-trips too
      final half = await admin.assessment('ASSMT-MAT-HALF');
      expect(half.questions.map((q) => q.id).toList(),
          ['Q-MATH-001', 'Q-MATH-002', 'Q-MATH-003']);

      // results for STU-001: two seeded submissions (SUB-M1-STU001, SUB-E1-STU001)
      final results = await admin.resultsForStudent('STU-001');
      expect(results.map((r) => r.assessment.id).toSet(),
          {'ASSMT-MAT-HALF', 'ASSMT-ENG-T1'});
    });

    test('attendance summary matches the 5-day seed per student', skip: skip,
        () async {
      final app = await LocalStore().loadAttendance();
      final perStudent = <String, int>{};
      for (final r in app) {
        perStudent[r.studentId] = (perStudent[r.studentId] ?? 0) + 1;
      }
      expect(perStudent['STU-001'], 5);
      expect(app.length, 30);

      final summary = await admin.attendanceSummaryForStudent('STU-001');
      expect(summary.total, 5);
      expect(summary.present + summary.late + summary.absent + summary.excused,
          5);

      // history endpoint: every record parses as an app model
      final history = await admin.attendanceHistoryForStudent('STU-001');
      final records = history.values.expand((e) => e).toList();
      expect(records, hasLength(5));
      expect(records.every((r) => r.studentId == 'STU-001'), isTrue);
    });

    test('gate, interventions, assignments, messages, notifications',
        skip: skip, () async {
      final appGate = await LocalStore().loadGateEvents();
      final appInterventions = await LocalStore().loadInterventions();
      final appAssignments = await LocalStore().loadAssignments();
      final appMessages = await LocalStore().loadMessages();

      expect((await admin.gateEvents()).length, appGate.length);
      expect((await admin.interventions()).map((i) => i.id).toList(),
          appInterventions.map((i) => i.id).toList());
      expect((await admin.assignments()).map((a) => a.id).toList()..sort(),
          appAssignments.map((a) => a.id).toList()..sort());

      // messages are participant-scoped: the teacher thread carries all three
      // seeded messages, while the admin has none (role filtering, not a bug)
      final teacherMessages = await teacher.messages();
      expect(teacherMessages.map((m) => m.id).toList()..sort(),
          appMessages.map((m) => m.id).toList()..sort());
      expect(teacherMessages.map((m) => m.fromId).toSet(),
          containsAll(['USR-TCH-001', 'USR-PRN-001']));
      expect(await admin.messages(), isEmpty);

      // announcements are seeded identically on both sides; audit gains
      // auth.login rows during a live session — both must parse cleanly
      final announcements = await admin.announcements();
      final appAnnouncements = await LocalStore().loadAnnouncements();
      expect(announcements.map((a) => a.id).toList()..sort(),
          appAnnouncements.map((a) => a.id).toList()..sort());
      final audit = await admin.client.get('/api/audit') as List;
      expect(audit, isNotEmpty);
      for (final e in audit) {
        final entry = AuditEntry.fromJson(e as Map<String, dynamic>);
        expect(entry.id, isNotEmpty);
        expect(entry.action, isNotEmpty);
      }
    });

    test('timetable and resources are seeded identically', skip: skip,
        () async {
      final store = Phase6Store();
      int byId(Map a, Map b) => (a['id'] as String).compareTo(b['id'] as String);
      expect((await student.records('lessons'))..sort(byId),
          List.of(await store.loadLessonsJson())..sort(byId));
      expect((await student.records('resources'))..sort(byId),
          List.of(await store.loadResourcesJson())..sort(byId));
    });

    test('notification visibility follows role ownership', skip: skip,
        () async {
      // parent of STU-001 sees the 3 seeded notifications for their child
      final parentUnread = await parent.unreadNotifications();
      expect(parentUnread.map((n) => n.id).toList()..sort(),
          ['NOTIF-001', 'NOTIF-002', 'NOTIF-003']);

      // same request for the school admin yields an empty array (role filter)
      expect(await admin.unreadNotifications(), isEmpty);
    });
  });
}