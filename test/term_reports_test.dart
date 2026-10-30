import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solvanta/core/models/submission.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/core/theme/app_theme.dart';
import 'package:solvanta/features/assessment/results_screen.dart';
import 'package:solvanta/features/auth/auth_repository.dart';
import 'package:solvanta/features/reports/report_card_pdf.dart';
import 'package:solvanta/features/reports/report_card_screen.dart';
import 'package:solvanta/features/reports/report_card_source.dart';
import 'package:solvanta/features/reports/term_reports_repository.dart';

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _open(
  WidgetTester tester,
  String email,
  String pw,
  Widget home,
) async {
  await tester.runAsync(
    () => AuthRepository().login(email: email, password: pw),
  );
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: home));
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a card survives its JSON round trip unchanged', () async {
    final src = await ReportCardSource.load();
    final card = src.liveCardFor(src.students.first);
    final again = ReportCardData.fromJson(
      jsonDecode(jsonEncode(card.toJson())) as Map<String, dynamic>,
    );
    expect(again.toJson(), card.toJson());
  });

  test('remarks land on the card; approval freezes it', () async {
    final store = LocalStore();
    var src = await ReportCardSource.load(store: store);
    final kojo = src.students.firstWhere((s) => s.id == 'STU-001');
    final repo = TermReportsRepository(store: store);
    await repo.save(
      src
          .reportFor(kojo)
          .copyWith(
            teacherRemark: 'A careful worker who helps others.',
            conduct: 'Very good',
            headRemark: 'Keep it up.',
          ),
    );
    src = await ReportCardSource.load(store: store);
    var card = src.cardFor(kojo);
    expect(card.remark, 'A careful worker who helps others.');
    expect(card.conduct, 'Very good');
    expect(card.headRemark, 'Keep it up.');
    expect(card.approved, isFalse);
    expect(approvalLine(card), startsWith('DRAFT'));
    final before = card.overall;

    await repo.approve(src.reportFor(kojo), card, 'Mr. Kwame Boateng');
    // A mark changes after approval…
    final subs = await store.loadSubmissions();
    await store.saveSubmissions([
      for (final s in subs)
        s.studentId == 'STU-001'
            ? AssessmentSubmission.fromJson({...s.toJson(), 'earned': 0})
            : s,
    ]);
    src = await ReportCardSource.load(store: store);
    card = src.cardFor(kojo);
    // …but the approved card is exactly as it was approved.
    expect(card.approved, isTrue);
    expect(card.overall, before);
    expect(card.remark, 'A careful worker who helps others.');
    expect(approvalLine(card), startsWith('Approved by Mr. Kwame Boateng'));
    final out = Platform.environment['REPORT_CARD_OUT'];
    if (out != null) {
      File('$out/approved_card.pdf').writeAsBytesSync(
          await buildReportCardPdf(card, ReportCardTemplate.classic));
    }
    expect(src.liveCardFor(kojo).overall, isNot(before));

    // Reopening goes back to the live marks.
    await repo.reopen(src.reportFor(kojo));
    src = await ReportCardSource.load(store: store);
    expect(src.cardFor(kojo).approved, isFalse);
    expect(src.cardFor(kojo).overall, isNot(before));
  });

  test('a whole class prints as one PDF, a page per pupil', () async {
    final src = await ReportCardSource.load();
    final cards = [
      for (final s in src.students)
        if (s.classId == 'JHS2A') src.cardFor(s),
    ];
    final pdf = latin1.decode(
      await buildClassReportPdf(cards, ReportCardTemplate.classic),
    );
    final pages = RegExp(r'/Type\s*/Page\b').allMatches(pdf).length;
    expect(pages, cards.length);
  });

  testWidgets('a teacher sees only their class and cannot approve', (
    tester,
  ) async {
    await _open(
      tester,
      'efua.mensah@school.gh',
      'teacher123',
      const ReportCardScreen(),
    );
    expect(find.text('Remarks'), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('JHS1A'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the headteacher can approve, and the remarks sheet opens', (
    tester,
  ) async {
    await _open(tester, 'head@school.gh', 'head123', const ReportCardScreen());
    expect(find.text('Approve'), findsOneWidget);
    await tester.tap(find.text('Remarks'));
    await tester.pumpAndSettle();
    expect(find.text("Headteacher's remark"), findsOneWidget);
    expect(find.text('Save remarks'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('families see a card only once it is approved', (tester) async {
    final store = LocalStore();
    late ReportCardSource src;
    await tester.runAsync(() async {
      src = await ReportCardSource.load(store: store);
      final kojo = src.students.firstWhere((s) => s.id == 'STU-001');
      await TermReportsRepository(store: store)
          .save(src.reportFor(kojo).copyWith(teacherRemark: 'Draft only'));
    });
    await _open(
      tester,
      'ama.owusu@school.gh',
      'parent123',
      const ResultsScreen(studentId: 'STU-001'),
    );
    expect(find.text('Report cards'), findsNothing);

    await tester.runAsync(() async {
      final kojo = src.students.firstWhere((s) => s.id == 'STU-001');
      final fresh = await ReportCardSource.load(store: store);
      await TermReportsRepository(store: store)
          .approve(fresh.reportFor(kojo), fresh.cardFor(kojo), 'Head');
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const ResultsScreen(studentId: 'STU-001'),
      ),
    );
    await _settle(tester);
    expect(find.text('Report cards'), findsOneWidget);
    expect(find.textContaining('Approved by Head'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
