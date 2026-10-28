import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/models/marking_feedback.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/features/reports/marking_feedback_repository.dart';
import 'package:solvanta/features/reports/marking_feedback_screen.dart';

// =============================================================================
// Feedback reports — Phase 7, app side. No backend: reports come from the
// copy kept on the device, which is what a teacher sees without a signal.
// =============================================================================

const studentPath = '/api/reports/marking/students/STU-002';
const classPath = '/api/reports/marking/classes/JHS2A';

/// The shape the server sends for STU-002 (marking_reports.go).
final studentBody = {
  'student': {'id': 'STU-002', 'name': 'Akosua Boaduwaa', 'classId': 'JHS2A'},
  'papers': [
    {
      'draftId': 'MD-1', 'schemeId': 'MS-1', 'schemeVersion': 1, 'targetKind': 'assessment',
      'title': 'Fractions Quick Diagnostic', 'subjectId': 'MATH', 'finalizedAt': '2026-10-27 09:00',
      'marks': 2, 'total': 9, 'percent': 22.2, 'grade': 'F', 'questionCount': 3, 'fullMarks': 1,
      'wrong': [
        {
          'questionNumber': 2, 'topic': 'Fractions', 'studentAnswer': '1/2 m', 'marks': 0, 'totalMarks': 3,
          'blank': false, 'likelyMisconception': 'Took half of 1 m instead of half of 3/4 m',
          'nextStep': 'Work on this misconception: Took half of 1 m instead of half of 3/4 m.',
          'nextStepSource': 'misconception',
        },
        {
          'questionNumber': 3, 'topic': 'Fractions', 'studentAnswer': '', 'marks': 0, 'totalMarks': 4,
          'blank': true, 'nextStep': 'Attempt question 3 — it was left blank.', 'nextStepSource': 'blank',
        },
      ],
    },
  ],
  'summary': {
    'papers': 1, 'wrongQuestions': 2,
    'misconceptions': [
      {'cause': 'Took half of 1 m instead of half of 3/4 m', 'count': 1},
    ],
  },
};

final classBody = {
  'classId': 'JHS2A',
  'struggleThreshold': 50,
  'awaitingReview': 1,
  'reports': [
    {
      'schemeId': 'MS-1', 'schemeVersion': 1, 'targetKind': 'assessment',
      'title': 'Fractions Quick Diagnostic', 'subjectId': 'MATH', 'papers': 2, 'awaitingReview': 1,
      'averagePercent': 55.6, 'hardest': [2], 'lastMarkedAt': '2026-10-27 09:00',
      'questions': [
        {'questionNumber': 1, 'topic': 'Fractions', 'totalMarks': 2, 'papers': 2, 'averageMarks': 2,
         'averagePercent': 100, 'fullMarks': 2, 'zero': 0, 'blank': 0, 'struggled': false,
         'misconceptions': [], 'belowFull': []},
        {'questionNumber': 2, 'topic': 'Fractions', 'totalMarks': 3, 'papers': 2, 'averageMarks': 0.5,
         'averagePercent': 16.7, 'fullMarks': 0, 'zero': 1, 'blank': 0, 'struggled': true,
         'misconceptions': [{'cause': 'Took half of 1 m instead of half of 3/4 m', 'count': 1}],
         'belowFull': [
           {'studentId': 'STU-002', 'name': 'Akosua Boaduwaa', 'marks': 0},
           {'studentId': 'STU-001', 'name': 'Kojo Owusu', 'marks': 1},
         ]},
        {'questionNumber': 3, 'topic': 'Fractions', 'totalMarks': 4, 'papers': 2, 'averageMarks': 2,
         'averagePercent': 50, 'fullMarks': 1, 'zero': 1, 'blank': 1, 'struggled': false,
         'misconceptions': [], 'belowFull': [{'studentId': 'STU-002', 'name': 'Akosua Boaduwaa', 'marks': 0}]},
      ],
    },
  ],
};

Map<String, Object> prefsWith(String viewer, Map<String, Object> reports) => {
      'solvanta.session_user_id': viewer,
      'solvanta.marking_feedback_v1': jsonEncode({
        for (final e in reports.entries) '$viewer|${e.key}': {'fetchedAt': '2026-10-27T10:00:00', 'body': e.value},
      }),
    };

void main() {
  group('model', () {
    test('a student report reads the server shape', () {
      final f = StudentFeedback.fromJson(studentBody);
      expect(f.studentName, 'Akosua Boaduwaa');
      expect(f.wrongQuestions, 2);
      final p = f.papers.single;
      expect(p.marks, 2);
      expect(p.wrong.first.likelyMisconception, contains('half of 3/4'));
      expect(p.wrong.first.teacherNote, isEmpty);
      expect(p.wrong.last.blank, isTrue);
      expect(f.misconceptions.single.count, 1);
    });

    test('a class report finds its hardest question', () {
      final f = ClassFeedback.fromJson(classBody);
      final r = f.reports.single;
      expect(f.awaitingReview, 1);
      expect(r.hardest, [2]);
      expect(r.question(2)!.struggled, isTrue);
      expect(r.question(2)!.averageMarks, 0.5);
      expect(r.question(3)!.struggled, isFalse);
      expect(r.question(9), isNull);
    });
  });

  group('repository, offline', () {
    test('the copy on the device is shown, marked as offline', () async {
      SharedPreferences.setMockInitialValues(prefsWith('USR-TCH-001', {studentPath: studentBody}));
      final res = await MarkingFeedbackRepository().student('USR-TCH-001', 'STU-002');
      expect(res.fromCache, isTrue);
      expect(res.data!.papers.single.title, 'Fractions Quick Diagnostic');
    });

    test("one account never sees another's saved copy", () async {
      SharedPreferences.setMockInitialValues(prefsWith('USR-TCH-001', {studentPath: studentBody}));
      final res = await MarkingFeedbackRepository().student('USR-PRN-001', 'STU-002');
      expect(res.data, isNull);
      expect(res.error, contains('Connect once'));
    });

    test('nothing saved and no server: an honest message', () async {
      SharedPreferences.setMockInitialValues({});
      final res = await MarkingFeedbackRepository().forClass('USR-TCH-001', 'JHS2A');
      expect(res.data, isNull);
      expect(await LocalStore().loadMarkingFeedback(), isEmpty);
    });
  });

  group('screens at phone width', () {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('student feedback shows wrong questions and next steps', (tester) async {
      phone(tester);
      SharedPreferences.setMockInitialValues(prefsWith('USR-TCH-001', {studentPath: studentBody}));
      await tester.pumpWidget(const MaterialApp(home: StudentFeedbackView(studentId: 'STU-002')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Offline'), findsOneWidget);
      expect(find.text('Fractions Quick Diagnostic'), findsOneWidget);
      expect(find.text('Question 2 · Fractions'), findsOneWidget);
      expect(find.textContaining('Likely misconception'), findsOneWidget);
      expect(find.text('Attempt question 3 — it was left blank.'), findsOneWidget);
      expect(find.text('Left blank'), findsOneWidget);
    });

    testWidgets('an empty report says marks must be finalized first', (tester) async {
      phone(tester);
      SharedPreferences.setMockInitialValues(prefsWith('USR-TCH-001', {
        studentPath: {'student': {'id': 'STU-002', 'name': 'Akosua Boaduwaa'}, 'papers': [], 'summary': {}},
      }));
      await tester.pumpWidget(const MaterialApp(home: StudentFeedbackView(studentId: 'STU-002')));
      await tester.pumpAndSettle();
      expect(find.text('No marked papers yet'), findsOneWidget);
    });

    testWidgets("a teacher's class report shows what the class struggled with", (tester) async {
      phone(tester);
      SharedPreferences.setMockInitialValues(prefsWith('USR-TCH-001', {classPath: classBody}));
      await tester.pumpWidget(const MaterialApp(home: MarkingFeedbackScreen()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Struggled with: Q2 (17%)'), findsOneWidget);
      expect(find.text('1 paper still awaiting review'), findsOneWidget);

      // Open Q2: who lost marks, and the misconception behind it.
      await tester.tap(find.text('Q2 · Fractions'));
      await tester.pumpAndSettle();
      expect(find.text('Kojo Owusu 1'), findsOneWidget);
      expect(find.textContaining('half of 3/4 m (1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
