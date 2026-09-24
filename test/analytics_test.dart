import 'package:flutter_test/flutter_test.dart';
import 'package:solvanta/features/analytics/analytics_service.dart';
import 'package:solvanta/features/reports/reporting_service.dart';
import 'package:solvanta/core/models/assessment.dart';
import 'package:solvanta/core/models/question.dart';
import 'package:solvanta/core/models/student.dart';
import 'package:solvanta/core/models/submission.dart';

void main() {
  test('gradeLetter buckets', () {
    expect(gradeLetter(90), 'A');
    expect(gradeLetter(70), 'B');
    expect(gradeLetter(62), 'C');
    expect(gradeLetter(52), 'D');
    expect(gradeLetter(30), 'F');
  });

  test('question gaps flag weak topics', () {
    final assessment = Assessment(
      id: 'ASSMT-T',
      title: 'Fractions Diagnostic',
      type: AssessmentType.classTest,
      subjectId: 'MATH',
      classId: 'JHS2A',
      date: '2026-09-20',
      createdBy: 't',
      questions: [
        const Question(
          id: 'Q1',
          type: QuestionType.mcq,
          subjectId: 'MATH',
          classId: 'JHS2A',
          topic: 'Fractions',
          difficulty: 1,
          cognitiveLevel: 'Knowledge',
          marks: 2,
          stem: 'x',
          options: ['a', 'b'],
          correctAnswer: 'a',
        ),
      ],
    );
    final students = [
      Student(
        id: 'S1',
        classId: 'JHS2A',
        firstName: 'A',
        lastName: 'B',
        gender: 'M',
        dateOfBirth: '2010-01-01',
        admissionDate: '2025-01-01',
        admissionNo: 'ADM1',
        schoolId: 'SCH',
      ),
      Student(
        id: 'S2',
        classId: 'JHS2A',
        firstName: 'C',
        lastName: 'D',
        gender: 'F',
        dateOfBirth: '2010-02-01',
        admissionDate: '2025-01-01',
        admissionNo: 'ADM2',
        schoolId: 'SCH',
      ),
    ];
    final subs = [
      AssessmentSubmission(
        id: 'sub1',
        assessmentId: 'ASSMT-T',
        studentId: 'S1',
        classId: 'JHS2A',
        date: '2026-09-20',
        answers: const {'Q1': 'a'},
        teacherMarks: const {},
        earned: 2,
      ),
      AssessmentSubmission(
        id: 'sub2',
        assessmentId: 'ASSMT-T',
        studentId: 'S2',
        classId: 'JHS2A',
        date: '2026-09-20',
        answers: const {'Q1': 'b'},
        teacherMarks: const {},
        earned: 0,
      ),
    ];
    final p = ClassPerformance(
      assessments: [assessment],
      subs: subs,
      students: students,
    );
    expect(p.averageFor(assessment), closeTo(0.5, 1e-9));
    final gaps = p.gapsFor(assessment);
    expect(gaps.single.topic, 'Fractions');
    expect(gaps.single.correctRate, 0.5);
    expect(p.atRisk(threshold: 50).map((a) => a.student.id), contains('S2'));
  });

  test('CSV export quotes and lists students', () {
    final assessment = Assessment(
      id: 'A',
      title: 'Class Test',
      type: AssessmentType.quiz,
      subjectId: 'ENG',
      classId: 'JHS2A',
      date: '2026-09-20',
      createdBy: 't',
      questions: const [],
    );
    final student = Student(
      id: 'S1',
      classId: 'JHS2A',
      firstName: 'Kojo',
      lastName: 'Owusu',
      gender: 'M',
      dateOfBirth: '2010-01-01',
      admissionDate: '2025-01-01',
      admissionNo: 'ADM1',
      schoolId: 'SCH',
    );
    final csv = ReportingService().classResultsCsv(
      assessment: assessment,
      roster: [student],
      subs: const [],
    );
    expect(csv, contains('Kojo Owusu'));
    expect(csv, contains('pending'));
  });
}