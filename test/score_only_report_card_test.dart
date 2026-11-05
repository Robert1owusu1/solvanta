import 'package:flutter_test/flutter_test.dart';
import 'package:solvanta/core/models/assessment.dart';
import 'package:solvanta/core/models/question.dart';
import 'package:solvanta/core/models/school.dart';
import 'package:solvanta/core/models/school_term.dart';
import 'package:solvanta/core/models/student.dart';
import 'package:solvanta/core/models/submission.dart';
import 'package:solvanta/features/reports/report_card_pdf.dart';
import 'package:solvanta/features/reports/reporting_service.dart';

Student _student(String id, String first) => Student(
  id: id,
  firstName: first,
  lastName: 'Mensah',
  gender: 'Female',
  dateOfBirth: '2012-03-14',
  admissionDate: '2023-09-04',
  admissionNo: 'ADM-$id',
  classId: 'JHS2A',
  schoolId: 'SCH-001',
);

/// A paper marked on the score sheet by hand: an explicit maximum and no
/// questions at all. `totalMarks` is 0 for this one; `effectiveTotal` is 50.
Assessment _scoreOnly(String subject, {String date = '2026-10-01'}) => Assessment(
  id: '$subject-score-only',
  title: '$subject Score Sheet',
  type: AssessmentType.classTest,
  subjectId: subject,
  classId: 'JHS2A',
  date: date,
  createdBy: 'T',
  questions: const [],
  maxScore: 50,
);

/// The ordinary question-carrying assessment the exam half of the card needs.
Assessment _exam(String subject, {String date = '2026-10-02'}) => Assessment(
  id: '$subject-exam',
  title: '$subject End-of-Term',
  type: AssessmentType.endTerm,
  subjectId: subject,
  classId: 'JHS2A',
  date: date,
  createdBy: 'T',
  questions: [
    Question(
      id: 'Q-$subject',
      type: QuestionType.structured,
      subjectId: subject,
      classId: 'JHS2A',
      topic: 't',
      difficulty: 1,
      cognitiveLevel: 'Knowledge',
      marks: 100,
      stem: 's',
    ),
  ],
);

AssessmentSubmission _sub(Assessment a, Student s, double earned) =>
    AssessmentSubmission(
      id: '${a.id}-${s.id}',
      assessmentId: a.id,
      studentId: s.id,
      classId: s.classId,
      date: a.date,
      answers: const {},
      teacherMarks: const {},
      earned: earned,
    );

const _term = SchoolTerm(
  year: '2026/2027',
  name: 'Term 3',
  start: '2026-09-07',
  end: '2026-12-18',
);

void main() {
  // Report-card PDFs load their bundled font through the asset bundle.
  TestWidgetsFlutterBinding.ensureInitialized();

  // Ama: 40 of 50 by hand on the score sheet (80%), 70 of 100 in the exam.
  final ama = _student('S1', 'Ama');
  final kofi = _student('S2', 'Kofi');
  final cw = _scoreOnly('MATH');
  final ex = _exam('MATH');
  final assessments = [cw, ex];
  final subs = [_sub(cw, ama, 40), _sub(ex, ama, 70), _sub(cw, kofi, 45)];

  test('a score-only assessment reads out of its max score, not zero', () {
    // The premise of the bug: the question sum is empty.
    expect(cw.totalMarks, 0);
    expect(cw.effectiveTotal, 50);

    final row = ReportingService()
        .rowsFor(student: ama, assessments: assessments, subs: subs)
        .firstWhere((r) => r.subjectId == 'MATH' && r.type != AssessmentType.endTerm);
    expect(row.total, 50);
    expect(row.earned, 40);
    // With total 0 this was null, and a null pct drops the row from every
    // subject average and from the terminal class/exam split.
    expect(row.pct, closeTo(80, 1e-9));
    expect(row.marksLabel, '40.0');
  });

  test('the score reaches the subject summary instead of vanishing', () {
    final rows = ReportingService()
        .rowsFor(student: ama, assessments: assessments, subs: subs);
    final maths = ReportingService().subjectsFor(rows: rows).single;
    expect(maths.attempts, 2, reason: 'both the hand-marked paper and the exam');
    // mean(80, 70)
    expect(maths.average, closeTo(75, 1e-9));
  });

  test('the report card weighs it as class work, so it is not partial', () {
    final card = ReportCardDataBuilder.build(
      student: ama,
      school: const School(id: 'SCH-001', name: 'Achimota Hills Academy'),
      term: _term,
      assessments: assessments,
      subs: subs,
      roster: [ama, kofi],
    );
    final maths = card.subjects.firstWhere((s) => s.subjectId == 'MATH');
    // class work 80 weighted 30% = 24, exam 70 weighted 70% = 49.
    expect(maths.classScore, closeTo(24, 1e-9));
    expect(maths.examScore, closeTo(49, 1e-9));
    expect(maths.total, closeTo(73, 1e-9));
    // Before the fix the class half was absent, leaving a partial card.
    expect(card.hasPartial, isFalse);
  });

  test('the class-results export prints the real maximum and percentage', () {
    final csv = ReportingService()
        .classResultsCsv(assessment: cw, roster: [ama, kofi], subs: subs);
    expect(csv, contains('Total marks,50.00'));
    expect(csv, contains('80.0%'), reason: '40 of 50, not 0 of 0');
    // The student row carries its own denominator, so a zero maximum would
    // show here as a 0.00 total beside a bogus percentage.
    expect(
      csv,
      contains('"S1","Ama Mensah","JHS2A","50.00","40.0","80.0%"'),
    );
    // 40 + 45 of (50 + 50) — both students scored against the real maximum.
    expect(csv, contains('Class average,85.0%'));
  });
}
