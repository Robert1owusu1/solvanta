import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/api/api_client.dart';
import 'package:solvanta/core/models/message.dart';
import 'package:solvanta/core/models/scan_page.dart';
import 'package:solvanta/core/models/timetable.dart';
import 'package:solvanta/core/models/user.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/core/sync/server_sync.dart';
import 'package:solvanta/features/assessment/scans_repository.dart';
import 'package:solvanta/features/assignments/assignments_repository.dart';
import 'package:solvanta/features/auth/auth_repository.dart';
import 'package:solvanta/features/communication/messages_repository.dart';
import 'package:solvanta/features/students/students_repository.dart';
import 'package:solvanta/features/timetable/timetable_repository.dart';

/// Cross-device sync for the collections the server stores on the client's
/// behalf (timetable, scans, targets) and for receipts, assignment un-ticks
/// and password resets. Same shape as server_sync_live_test.dart: one
/// account writes, another signs in on an empty device and must see it.
///
///   SOLVANTA_API_URL=http://127.0.0.1:8080 flutter test test/records_sync_live_test.dart
///
/// The tests run in order and share state. 8 sign-ins, under the API's
/// 10-per-minute login limit (run it a minute apart from the other live
/// suite). It changes the staff demo password, so restart an in-memory
/// server afterwards.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final skip = !ApiClient.isConfigured;

  Future<User> signInFresh(String email, String password) async {
    SharedPreferences.setMockInitialValues({});
    ApiClient.sharedToken = null;
    final user = await AuthRepository().login(email: email, password: password);
    expect(user, isNotNull, reason: 'sign-in for $email');
    return user!;
  }

  final stamp = DateTime.now().millisecondsSinceEpoch;
  final slotId = 'SLOT-LIVE-$stamp';
  final scanId = 'SCAN-LIVE-$stamp';
  final photo = Uint8List.fromList([0xFF, 0xD8, 0xFF, for (var i = 0; i < 5000; i++) i % 251]);
  late Message sent;
  late String assignmentId;

  test('a teacher adds a lesson, scans a page and sends a message', skip: skip,
      () async {
    final teacher = await signInFresh('efua.mensah@school.gh', 'teacher123');
    final timetable = TimetableRepository();
    await timetable.saveSlots([
      ...await timetable.loadSlots(),
      LessonSlot(id: slotId, classId: 'JHS2A', weekday: 'Friday',
          start: '15:00', end: '15:40', subjectId: 'ICT', teacherId: teacher.id),
    ]);
    await ScansRepository().save(
      ScanPage(id: scanId, assessmentId: 'ASSMT-MATH-T1', studentId: 'STU-001',
          imagePath: '/device/only.jpg', pageNumber: 1,
          capturedAt: '2026-10-21 09:00', recorder: teacher.name,
          status: ScanStatus.queued),
      image: photo,
    );
    sent = await MessagesRepository().send(
      fromId: teacher.id,
      toId: 'USR-PRN-001',
      relatedStudentId: 'STU-001',
      subject: 'Receipt check $stamp',
      body: 'Please confirm you saw this.',
    );
  });

  test('the pupil sees the lesson, and can take back a completion',
      skip: skip, () async {
    await signInFresh('kojo.owusu@school.gh', 'student123');
    final slots = await TimetableRepository().loadSlots();
    expect(slots.map((s) => s.id), contains(slotId));

    final me = (await StudentsRepository().all())
        .firstWhere((s) => s.id == 'STU-001');
    final repo = AssignmentsRepository();
    final open = (await repo.forClass('JHS2A'))
        .firstWhere((a) => !a.completedBy.contains(me.id));
    assignmentId = open.id;
    await repo.setCompleted(assignmentId, me, true);
    await repo.setCompleted(assignmentId, me, false);

    final targets = {'MATH': 'A', 'ENG': 'B'};
    await LocalStore().saveTargets(targets, userId: 'USR-STU-001');
    await ServerSync.instance.send('PUT', '/api/records/targets/USR-STU-001',
        body: {'id': 'USR-STU-001', 'targets': targets});
  });

  test('the parent opens the message', skip: skip, () async {
    final parent = await signInFresh('ama.owusu@school.gh', 'parent123');
    final mine = await MessagesRepository().forUser(parent);
    final got = mine.firstWhere((m) => m.id == sent.id);
    await MessagesRepository()
        .markRead(meId: parent.id, conversationId: got.conversationId);
  });

  test('the head sees the scan photo and the un-ticked assignment',
      skip: skip, () async {
    await signInFresh('head@school.gh', 'head123');
    final scan = (await ScansRepository().all()).firstWhere((s) => s.id == scanId);
    expect(scan.imagePath, isEmpty,
        reason: "another device's file path is meaningless here");
    expect(await ScansRepository().image(scan), photo);
    final a = (await AssignmentsRepository().all())
        .firstWhere((a) => a.id == assignmentId);
    expect(a.completedBy, isNot(contains('STU-001')));
  });

  test("the teacher's copy shows the message as read", skip: skip, () async {
    final teacher = await signInFresh('efua.mensah@school.gh', 'teacher123');
    final mine = await MessagesRepository().forUser(teacher);
    expect(mine.firstWhere((m) => m.id == sent.id).state, MessageState.read);
  });

  test("the pupil's targets follow them to a new device", skip: skip,
      () async {
    await signInFresh('kojo.owusu@school.gh', 'student123');
    expect(await LocalStore().loadTargets(userId: 'USR-STU-001'),
        {'MATH': 'A', 'ENG': 'B'});
  });

  test('an admin resets a forgotten password', skip: skip, () async {
    await signInFresh('admin@solvanta.app', 'admin123');
    await ServerSync.instance.send('POST', '/api/users/USR-STF-001/reset-password',
        body: {'new': 'Gatehouse2026'});
    final staff = await signInFresh('staff@school.gh', 'Gatehouse2026');
    expect(staff.id, 'USR-STF-001');
  });
}
