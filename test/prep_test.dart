import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solvanta/core/models/assessment.dart';
import 'package:solvanta/core/models/grading.dart';
import 'package:solvanta/core/models/question.dart';
import 'package:solvanta/core/models/submission.dart';
import 'package:solvanta/core/theme/app_theme.dart';
import 'package:solvanta/features/auth/auth_repository.dart';
import 'package:solvanta/features/prep/prep_screen.dart';

Assessment _paper(String subject) => Assessment(
      id: 'A-$subject',
      title: subject,
      type: AssessmentType.classTest,
      subjectId: subject,
      classId: 'JHS3A',
      date: '2026-10-01',
      createdBy: 'T',
      questions: [
        Question(
          id: 'Q-$subject',
          type: QuestionType.structured,
          subjectId: subject,
          classId: 'JHS3A',
          topic: 't',
          difficulty: 1,
          cognitiveLevel: 'Knowledge',
          marks: 100,
          stem: 's',
        ),
      ],
    );

AssessmentSubmission _mark(String subject, String student, double earned) =>
    AssessmentSubmission(
      id: '$subject-$student',
      assessmentId: 'A-$subject',
      studentId: student,
      classId: 'JHS3A',
      date: '2026-10-01',
      answers: const {},
      teacherMarks: const {},
      earned: earned,
    );

void main() {
  const six = ['ENG', 'MATH', 'SCI', 'SOC', 'ICT', 'RME'];
  final data = PrepData(
    studentId: 'ME',
    schoolId: 'SCH-001',
    mocks: const [],
    subs: [
      for (final s in six) _mark(s, 'ME', 72), // grade 2 everywhere
      _mark('ENG', 'SOMEONE-ELSE', 99),
    ],
    assessments: [for (final s in six) _paper(s)],
    bank: const [],
    targets: const {'MATH': '1', 'ENG': 'B'}, // 'B' predates the 1–9 scale
    scheme: gesBasicPreset,
  );

  test("only the student's own marks count", () {
    expect(data.currentPercent('ENG'), 72);
  });

  test('grades, targets and the aggregate follow the school scheme', () {
    expect(data.gradeRank('1'), greaterThan(data.gradeRank('2')));
    expect(data.targetFor('MATH'), '1');
    // An old letter target isn't on the 1–9 scale: the pass grade stands in.
    expect(data.targetFor('ENG'), gesBasicPreset.bandFor(50).grade);
    expect(data.predictedAggregate(), 12); // six subjects at grade 2
    expect(data.subjects.map((s) => s.id), containsAll(six));
  });

  test('no aggregate until the core scores are in', () {
    final partial = PrepData(
      studentId: 'ME',
      schoolId: 'SCH-001',
      mocks: const [],
      subs: [_mark('ENG', 'ME', 72)],
      assessments: [_paper('ENG')],
      bank: const [],
      targets: const {},
    );
    expect(partial.predictedAggregate(), isNull);
  });

  testWidgets('the prep screen opens for a student on a phone',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() => AuthRepository()
        .login(email: 'kojo.owusu@school.gh', password: 'student123'));
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        MaterialApp(theme: AppTheme.light(), home: const PrepScreen()));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Targets'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Predicted aggregate'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
