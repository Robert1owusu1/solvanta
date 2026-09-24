import 'package:flutter_test/flutter_test.dart';
import 'package:solvanta/core/models/assessment.dart';
import 'package:solvanta/core/models/correction.dart';
import 'package:solvanta/core/models/question.dart';
import 'package:solvanta/core/models/submission.dart';
import 'package:solvanta/features/assessment/feedback_screen.dart';
import 'package:solvanta/features/assessment/improvement.dart';

void main() {
  const mcq = Question(
    id: 'Q1',
    type: QuestionType.mcq,
    subjectId: 'MATH',
    classId: 'JHS2A',
    topic: 'Fractions',
    difficulty: 1,
    cognitiveLevel: 'Knowledge',
    marks: 2,
    stem: '1/2 equivalent to?',
    options: ['2/4', '1/3'],
    correctAnswer: '2/4',
  );
  const mathQ = Question(
    id: 'Q2',
    type: QuestionType.math,
    subjectId: 'MATH',
    classId: 'JHS2A',
    topic: 'Fractions',
    difficulty: 2,
    cognitiveLevel: 'Application',
    marks: 4,
    stem: 'Simplify 3/4 + 1/6',
  );
  final questions = [mcq, mathQ];

  test('isCorrect uses exact match for objective questions', () {
    final sub = AssessmentSubmission(
      id: 's1',
      assessmentId: 'A',
      studentId: 'S1',
      classId: 'JHS2A',
      date: '2026-09-20',
      answers: const {'Q1': '2/4', 'Q2': '11/12'},
      teacherMarks: const {'Q2': 3},
      earned: 5,
    );
    expect(isCorrect(mcq, sub), isTrue);
    // Below the 80% threshold → not correct.
    expect(isCorrect(mathQ, sub), isFalse);
  });

  test('incorrectQuestions lists only wrong questions', () {
    final sub = AssessmentSubmission(
      id: 's2',
      assessmentId: 'A',
      studentId: 'S1',
      classId: 'JHS2A',
      date: '2026-09-20',
      answers: const {'Q1': '1/3', 'Q2': '11/12'},
      teacherMarks: const {'Q2': 4},
      earned: 4,
    );
    final wrong = incorrectQuestions(questions, sub);
    expect(wrong.single.id, 'Q1');
  });

  test('Correction JSON round-trip', () {
    const c = Correction(
      id: 'CRCT-1',
      studentId: 'S1',
      assessmentId: 'A',
      questionId: 'Q1',
      beforeAnswer: '1/3',
      afterAnswer: '2/4',
      note: '',
      date: '2026-09-21',
    );
    final back = Correction.fromJson(c.toJson());
    expect(back.afterAnswer, '2/4');
    expect(back.completed, isTrue);
    expect(back.questionId, 'Q1');
  });

  group('subjectTrend', () {
    final assessmentA = Assessment(
      id: 'A',
      title: 'Diagnostic',
      type: AssessmentType.diagnostic,
      subjectId: 'MATH',
      classId: 'JHS2A',
      date: '2026-09-10',
      createdBy: 't',
      questions: [
        const Question(
          id: 'a1',
          type: QuestionType.math,
          subjectId: 'MATH',
          classId: 'JHS2A',
          topic: 'Fractions',
          difficulty: 1,
          cognitiveLevel: 'Knowledge',
          marks: 9,
          stem: 'x',
        ),
      ],
    );
    final assessmentB = Assessment(
      id: 'B',
      title: 'Reassess',
      type: AssessmentType.remedial,
      subjectId: 'MATH',
      classId: 'JHS2A',
      date: '2026-09-20',
      createdBy: 't',
      questions: [
        const Question(
          id: 'b1',
          type: QuestionType.math,
          subjectId: 'MATH',
          classId: 'JHS2A',
          topic: 'Fractions',
          difficulty: 1,
          cognitiveLevel: 'Knowledge',
          marks: 10,
          stem: 'y',
        ),
      ],
    );
    final otherSubject = Assessment(
      id: 'C',
      title: 'English test',
      type: AssessmentType.classTest,
      subjectId: 'ENG',
      classId: 'JHS2A',
      date: '2026-09-12',
      createdBy: 't',
      questions: const [],
    );

    AssessmentSubmission sub(String id, String assessmentId, String date,
        double earned, double total,
        {String studentId = 'S1'}) {
      return AssessmentSubmission(
        id: id,
        assessmentId: assessmentId,
        studentId: studentId,
        classId: 'JHS2A',
        date: date,
        answers: const {},
        teacherMarks: const {},
        earned: earned,
      );
    }

    test('computes before/after averages for the same subject', () {
      final trend = subjectTrend(
        studentId: 'S1',
        subjectId: 'MATH',
        assessmentId: 'A',
        assessmentDate: assessmentA.date,
        assessments: [assessmentA, assessmentB, otherSubject],
        subs: [
          // Before A — 50% and 100% on earlier maths work.
          sub('x1', 'B', '2026-09-05', 5, 10),
          sub('x2', 'B', '2026-09-08', 10, 10),
          // English in the same window must be ignored.
          sub('x3', 'C', '2026-09-06', 9, 10),
          // This assessment itself is excluded.
          sub('x4', 'A', '2026-09-10', 8, 9),
          // After A — 100%.
          sub('x5', 'B', '2026-09-20', 10, 10),
        ],
      );
      expect(trend.before, closeTo(75, 1e-9));
      expect(trend.after, closeTo(100, 1e-9));
    });

    test('returns nulls when there is no comparable data', () {
      final trend = subjectTrend(
        studentId: 'S2',
        subjectId: 'MATH',
        assessmentId: 'A',
        assessmentDate: assessmentA.date,
        assessments: [assessmentA],
        subs: [sub('x1', 'A', '2026-09-10', 8, 9)],
      );
      expect(trend.before, isNull);
      expect(trend.after, isNull);
    });
  });
}