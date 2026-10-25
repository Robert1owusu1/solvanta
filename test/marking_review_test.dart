import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/models/marking_draft.dart';
import 'package:solvanta/core/models/question.dart';
import 'package:solvanta/core/models/submission.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/features/marking/draft_review_screen.dart';
import 'package:solvanta/features/marking/marking_drafts_repository.dart';

// =============================================================================
// Teacher review — Phase 6, app side. No backend: the offline path is real.
// =============================================================================

Map<String, dynamic> answer(int n, double proposed, double total,
        {bool flagged = false, String method = 'exact', double? finalMarks}) =>
    {
      'schemeQuestionId': 'SQ-$n',
      'questionNumber': n,
      'studentAnswer': n == 2 ? '1/2 m' : 'answer $n',
      'working': n == 2 ? ['3/4 x 1/2'] : <String>[],
      'draftMarks': proposed,
      'totalMarks': total,
      'method': method,
      'needsReview': flagged,
      'reasons': ['Reason for question $n.'],
      'steps': <Map<String, dynamic>>[],
      'finalMarks': finalMarks,
    };

/// Q1 confident (2/2), Q2 flagged "not in the scheme" (0/3), Q3 confident (4/4).
MarkingDraft aDraft({String status = 'draft', List<double?> finals = const [null, null, null]}) =>
    MarkingDraft.fromJson({
      'id': 'MD-1',
      'schemeId': 'MS-1',
      'schemeVersion': 1,
      'targetKind': 'assessment',
      'submissionId': 'SUB-1',
      'studentId': 'STU-002',
      'classId': 'JHS2A',
      'sourceText': '1. 2/4',
      'ocrJobIds': <String>[],
      'unassigned': ['Name: Akosua'],
      'status': status,
      'draftTotal': 6,
      'maxTotal': 9,
      'needsReview': 1,
      'createdAt': '2026-10-25 10:00',
      'answers': [
        answer(1, 2, 2, finalMarks: finals[0]),
        answer(2, 0, 3, flagged: true, method: 'none', finalMarks: finals[1]),
        answer(3, 4, 4, finalMarks: finals[2]),
      ],
    });

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('recorded score', () {
    test('a teacher mark on an MCQ wins over the auto-mark', () {
      const mcq = Question(
        id: 'q1', type: QuestionType.mcq, subjectId: 'MATH', classId: 'JHS2A',
        topic: 'Fractions', difficulty: 1, cognitiveLevel: 'Knowledge', marks: 2,
        stem: 'Which is 1/2?', options: ['2/4', '2/3'], correctAnswer: '2/4',
      );
      expect(computeEarned([mcq], {'q1': '2/3'}, {}), 0);
      expect(computeEarned([mcq], {'q1': '2/3'}, {'q1': 1}), 1);
      expect(computeEarned([mcq], {'q1': '2/4'}, {'q1': 0}), 0);
    });
  });

  group('review rules', () {
    test('every question needs a mark', () {
      expect(reviewBlocker(aDraft(), {}), contains('Question 1'));
    });

    test('accept confident leaves flagged questions to the teacher', () {
      final decisions = acceptConfident(aDraft(), {});
      expect(decisions['SQ-1']!.marks, 2);
      expect(decisions['SQ-3']!.marks, 4);
      expect(decisions.containsKey('SQ-2'), isFalse);
      expect(reviewBlocker(aDraft(), decisions), contains('Question 2'));
    });

    test('a flagged question needs a tick or a changed mark', () {
      final base = acceptConfident(aDraft(), {});
      final unticked = {...base, 'SQ-2': const DraftDecision(marks: 0)};
      expect(reviewBlocker(aDraft(), unticked), contains('flagged'));
      final ticked = {...base, 'SQ-2': const DraftDecision(marks: 0, checked: true)};
      expect(reviewBlocker(aDraft(), ticked), isNull);
      final changed = {...base, 'SQ-2': const DraftDecision(marks: 1)};
      expect(reviewBlocker(aDraft(), changed), isNull);
    });

    test('a mark above the total is refused', () {
      final over = {...acceptConfident(aDraft(), {}), 'SQ-2': const DraftDecision(marks: 5, checked: true)};
      expect(reviewBlocker(aDraft(), over), contains('between 0 and 3'));
    });
  });

  group('model', () {
    test('a finalized draft keeps the proposal and the decision', () {
      final d = MarkingDraft.fromJson(aDraft(status: 'finalized', finals: [2, 1, 4]).toJson());
      expect(d.isFinal, isTrue);
      expect(d.toJson()['final'], isTrue);
      expect(d.finalTotal, 7);
      expect(d.answers[1].draftMarks, 0);
      expect(d.answers[1].finalMarks, 1);
      expect(d.answers[1].overridden, isTrue);
      expect(d.answers[0].overridden, isFalse);
    });

    test('a draft is not final', () {
      expect(aDraft().isFinal, isFalse);
      expect(aDraft().toJson()['final'], isFalse);
    });
  });

  group('repository, offline', () {
    test('decisions are kept on the device', () async {
      final repo = MarkingDraftsRepository();
      await repo.saveDecisions('MD-1', {'SQ-2': const DraftDecision(marks: 1.5, note: 'method', checked: true)});
      final back = await MarkingDraftsRepository().decisionsFor('MD-1');
      expect(back['SQ-2']!.marks, 1.5);
      expect(back['SQ-2']!.note, 'method');
      expect(back['SQ-2']!.checked, isTrue);
    });

    test('finalizing offline is refused, with the marks kept', () async {
      final repo = MarkingDraftsRepository();
      final ready = {...acceptConfident(aDraft(), {}), 'SQ-2': const DraftDecision(marks: 1)};
      await repo.saveDecisions('MD-1', ready);
      await expectLater(
        repo.finalize(aDraft(), ready),
        throwsA(isA<FinalizeException>().having((e) => e.message, 'message', contains('saved on this device'))),
      );
      expect((await repo.decisionsFor('MD-1'))['SQ-2']!.marks, 1);
    });

    test('an incomplete review is never sent', () async {
      await expectLater(
        MarkingDraftsRepository().finalize(aDraft(), {}),
        throwsA(isA<FinalizeException>().having((e) => e.message, 'message', contains('Question 1'))),
      );
    });
  });

  group('review screen at phone width', () {
    Future<void> pumpReview(WidgetTester tester, MarkingDraft draft) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await LocalStore().saveMarkingDrafts([draft]);
      await tester.pumpWidget(MaterialApp(
        home: DraftReviewScreen(draftId: draft.id, studentName: 'Akosua Boaduwaa'),
      ));
      await tester.pumpAndSettle();
    }

    FilledButton finalizeButton(WidgetTester tester) =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Finalize'));

    testWidgets('finalize unlocks only after the flagged question is checked', (tester) async {
      await pumpReview(tester, aDraft());
      expect(tester.takeException(), isNull);
      expect(find.text('Draft — not recorded until you finalize'), findsOneWidget);
      expect(find.text('Text not matched to any question'), findsOneWidget);
      expect(finalizeButton(tester).onPressed, isNull);

      await tester.tap(find.text('Accept confident'));
      await tester.pumpAndSettle();
      expect(finalizeButton(tester).onPressed, isNull, reason: 'Q2 is flagged and unchecked');

      final q2Mark = find.widgetWithText(TextField, 'Your mark').at(1);
      await tester.ensureVisible(q2Mark);
      await tester.enterText(q2Mark, '0');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text("I've checked this question"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("I've checked this question"));
      await tester.pumpAndSettle();
      expect(finalizeButton(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a finalized draft is read-only', (tester) async {
      await pumpReview(tester, aDraft(status: 'finalized', finals: [2, 1, 4]));
      expect(find.text('Finalized: 7 / 9'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Finalize'), findsNothing);
      expect(find.widgetWithText(TextField, 'Your mark'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the queue shows the empty state offline', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: DraftReviewQueueScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Nothing to review'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
