import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/api/api_client.dart';
import 'package:solvanta/core/models/announcement.dart';
import 'package:solvanta/core/models/attendance.dart';
import 'package:solvanta/core/models/user.dart';
import 'package:solvanta/features/attendance/attendance_repository.dart';
import 'package:solvanta/features/auth/auth_repository.dart';
import 'package:solvanta/features/communication/announcements_repository.dart';
import 'package:solvanta/features/communication/messages_repository.dart';
import 'package:solvanta/features/fees/fee_models.dart';
import 'package:solvanta/features/fees/fees_repository.dart';
import 'package:solvanta/features/notifications/notifications_repository.dart';
import 'package:solvanta/features/students/students_repository.dart';

/// Cross-device sync against a live backend: one account writes through the
/// app's own repositories, then a different account signs in on a "fresh
/// device" (empty local store) and must see the change after its pull.
///
///   cd backend && go run ./cmd/server          # in one terminal
///   SOLVANTA_API_URL=http://127.0.0.1:8080 flutter test test/server_sync_live_test.dart
///
/// Skipped when no endpoint is configured. Uses at most 8 sign-ins, under
/// the API's 10-per-minute login limit.
void main() {
  // Plugins (connectivity) need the test binding, but the binding also
  // fakes every HTTP call with a 400 — put real networking back.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final skip = !ApiClient.isConfigured;

  /// Signs in on an empty device: no local data, no token.
  Future<User> signInFresh(String email, String password) async {
    SharedPreferences.setMockInitialValues({});
    ApiClient.sharedToken = null;
    final user = await AuthRepository().login(email: email, password: password);
    expect(user, isNotNull, reason: 'sign-in for $email');
    return user!;
  }

  final stamp = DateTime.now().millisecondsSinceEpoch;

  test('an announcement posted by the admin reaches a parent', skip: skip,
      () async {
    final title = 'Live sync check $stamp';
    final admin = await signInFresh('admin@solvanta.app', 'admin123');
    await AnnouncementsRepository().create(
      title: title,
      body: 'Posted from the admin device.',
      audience: AnnouncementAudience.school,
      authorId: admin.id,
      authorName: admin.name,
    );

    final parent = await signInFresh('ama.owusu@school.gh', 'parent123');
    final students = await StudentsRepository().all();
    final seen = await AnnouncementsRepository().visibleFor(parent, students);
    expect(seen.map((a) => a.title), contains(title));
    final inbox = await NotificationsRepository().visibleFor(parent, students);
    expect(inbox.map((n) => n.title), contains(title),
        reason: 'the server fans announcements out to parents');
  });

  test("a teacher's absence mark shows on the parent's device", skip: skip,
      () async {
    // A school day late in the term that nothing else writes to.
    const date = '2026-12-14';
    await signInFresh('efua.mensah@school.gh', 'teacher123');
    final repo = AttendanceRepository();
    await repo.saveDay('JHS2A', date, {'STU-001': AttendanceStatus.present});
    await repo.saveDay('JHS2A', date, {'STU-001': AttendanceStatus.absent});

    final parent = await signInFresh('ama.owusu@school.gh', 'parent123');
    final day = await AttendanceRepository().forClassDate('JHS2A', date);
    expect(day.where((r) => r.studentId == 'STU-001').map((r) => r.status),
        [AttendanceStatus.absent]);
    final inbox = await NotificationsRepository()
        .visibleFor(parent, await StudentsRepository().all());
    expect(inbox.any((n) => n.body.contains('absent on $date')), isTrue);
  });

  test('a message sent online is delivered to the other side', skip: skip,
      () async {
    final subject = 'Homework follow-up $stamp';
    final teacher = await signInFresh('efua.mensah@school.gh', 'teacher123');
    await MessagesRepository().send(
      fromId: teacher.id,
      toId: 'USR-PRN-001',
      relatedStudentId: 'STU-001',
      subject: subject,
      body: 'Kojo did well this week.',
    );

    final parent = await signInFresh('ama.owusu@school.gh', 'parent123');
    final mine = await MessagesRepository().forUser(parent);
    expect(mine.map((m) => m.subject), contains(subject));
  });

  test("a payment taken by the bursar updates the parent's balance",
      skip: skip, () async {
    // STU-002's seeded invoice is part-paid (STU-001's is settled).
    await signInFresh('admin@solvanta.app', 'admin123');
    final fees = FeesRepository();
    final invoice = (await fees.invoicesForStudent('STU-002'))
        .firstWhere((i) => i.balance > 0, orElse: () => fail('no open invoice'));
    final before = invoice.amountPaid;
    final paid = await fees.recordPayment(
      invoiceId: invoice.id,
      amount: 1,
      method: PaymentMethod.cash,
      recordedBy: 'Live test',
    );

    await signInFresh('akua.boaduwaa@school.gh', 'parent123');
    final parentFees = FeesRepository();
    final mirrored = await parentFees.invoiceById(invoice.id);
    expect(mirrored?.amountPaid, before + 1);
    expect(await parentFees.receiptForPayment(paid.payment.id), isNotNull,
        reason: 'a receipt is cut for payments taken on another device');
  });
}
