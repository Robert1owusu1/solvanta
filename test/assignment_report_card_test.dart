import 'package:flutter_test/flutter_test.dart';
import 'package:solvanta/core/models/assessment.dart';
import 'package:solvanta/core/models/assignment.dart';
import 'package:solvanta/core/models/assignment_submission.dart';
import 'package:solvanta/core/models/marking_draft.dart';
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

/// One 100-mark assessment, so earned marks read as percentages.
Assessment _assessment(String subject, AssessmentType type, {String date = '2026-10-01'}) =>
    Assessment(
      id: '$subject-${type.name}',
      title: '$subject ${type.label}',
      type: type,
      subjectId: subject,
      classId: 'JHS2A',
      date: date,
      createdBy: 'T',
      questions: [
        Question(
          id: 'Q-$subject-${type.name}',
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

Assignment _assignment(
  String id, {
  String subject = 'MATH',
  String deadline = '2026-09-25',
}) => Assignment(
  id: id,
  classId: 'JHS2A',
  subjectId: subject,
  title: 'Title $id',
  instructions: 'Show all working.',
  deadline: deadline,
  createdBy: 'Ms. Efua Mensah',
  createdAt: '2026-09-18',
);

AssignmentSubmission _asub(String id, String assignmentId, String studentId) =>
    AssignmentSubmission(
      id: id,
      assignmentId: assignmentId,
      studentId: studentId,
      classId: 'JHS2A',
      subjectId: 'MATH',
      recorder: 'Ms. Efua Mensah',
      capturedAt: '2026-09-20',
    );

/// A marking draft with one recorded mark per entry in [marks].
MarkingDraft _draft({
  required String id,
  required String submissionId,
  required String studentId,
  String targetKind = 'assignment',
  String status = 'finalized',
  String finalizedAt = '2026-09-21',
  double maxTotal = 100,
  List<double> marks = const [60],
}) => MarkingDraft(
  id: id,
  schemeId: 'MS-$id',
  schemeVersion: 1,
  targetKind: targetKind,
  submissionId: submissionId,
  studentId: studentId,
  classId: 'JHS2A',
  sourceText: 'working',
  ocrJobIds: const [],
  unassigned: const [],
  status: status,
  draftTotal: marks.fold(0, (a, b) => a + b),
  maxTotal: maxTotal,
  needsReview: 0,
  createdAt: '2026-09-20',
  finalizedAt: finalizedAt,
  answers: [
    for (var i = 0; i < marks.length; i++)
      MarkingDraftAnswer(
        schemeQuestionId: 'Q$i',
        questionNumber: i + 1,
        studentAnswer: 'answer $i',
        working: const ['line'],
        draftMarks: marks[i],
        totalMarks: maxTotal,
        method: 'exact',
        matchedText: 'answer $i',
        likelyCause: '',
        needsReview: false,
        reasons: const [],
        steps: const [],
        finalMarks: marks[i],
      ),
  ],
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

  group('ReportingService.assignmentRowsFor', () {
    test('a finalized assignment draft becomes a row on its scheme total', () {
      final rows = ReportingService.assignmentRowsFor(
        assignments: [_assignment('ASG-1')],
        assignmentSubs: [_asub('SUB-1', 'ASG-1', 'S1')],
        drafts: [_draft(id: 'D1', submissionId: 'SUB-1', studentId: 'S1')],
      );
      final row = rows['S1']!.single;
      expect(row.subjectId, 'MATH');
      expect(row.title, 'Title ASG-1');
      // The assignment itself carries no marks; the scheme the draft was
      // marked against is where the total comes from.
      expect(row.total, 100);
      expect(row.earned, 60);
      expect(row.date, '2026-09-25');
      // Class work: the terminal report must never read this as the exam.
      expect(row.type, AssessmentType.homework);
      expect(row.type, isNot(AssessmentType.endTerm));
    });

    test('a draft still open for review is a proposal, not a mark', () {
      for (final status in ['draft', 'discarded']) {
        final rows = ReportingService.assignmentRowsFor(
          assignments: [_assignment('ASG-1')],
          assignmentSubs: [_asub('SUB-1', 'ASG-1', 'S1')],
          drafts: [
            _draft(
              id: 'D1',
              submissionId: 'SUB-1',
              studentId: 'S1',
              status: status,
            ),
          ],
        );
        expect(rows, isEmpty, reason: 'status $status must not be a mark');
      }
    });

    test('an assessment draft is not assignment work', () {
      final rows = ReportingService.assignmentRowsFor(
        assignments: [_assignment('ASG-1')],
        assignmentSubs: [_asub('SUB-1', 'ASG-1', 'S1')],
        drafts: [
          _draft(
            id: 'D1',
            submissionId: 'SUB-1',
            studentId: 'S1',
            targetKind: 'assessment',
          ),
        ],
      );
      expect(rows, isEmpty);
    });

    test('the newest finalization wins, so one assignment is counted once', () {
      final rows = ReportingService.assignmentRowsFor(
        assignments: [_assignment('ASG-1')],
        assignmentSubs: [_asub('SUB-1', 'ASG-1', 'S1')],
        drafts: [
          _draft(
            id: 'D-old',
            submissionId: 'SUB-1',
            studentId: 'S1',
            finalizedAt: '2026-09-21',
            marks: const [40],
          ),
          _draft(
            id: 'D-new',
            submissionId: 'SUB-1',
            studentId: 'S1',
            finalizedAt: '2026-09-23',
            marks: const [75],
          ),
        ],
      );
      expect(rows['S1']!.single.earned, 75);
    });

    test('a submission for an assignment that no longer exists is skipped', () {
      final rows = ReportingService.assignmentRowsFor(
        assignments: [_assignment('ASG-1')],
        assignmentSubs: [_asub('SUB-1', 'ASG-GONE', 'S1')],
        drafts: [_draft(id: 'D1', submissionId: 'SUB-1', studentId: 'S1')],
      );
      expect(rows, isEmpty);
    });

    test('rows land under the student who sat them', () {
      final rows = ReportingService.assignmentRowsFor(
        assignments: [_assignment('ASG-1')],
        assignmentSubs: [
          _asub('SUB-1', 'ASG-1', 'S1'),
          _asub('SUB-2', 'ASG-1', 'S2'),
        ],
        drafts: [
          _draft(id: 'D1', submissionId: 'SUB-1', studentId: 'S1'),
          _draft(
            id: 'D2',
            submissionId: 'SUB-2',
            studentId: 'S2',
            marks: const [30],
          ),
        ],
      );
      expect(rows['S1']!.single.earned, 60);
      expect(rows['S2']!.single.earned, 30);
      expect(rows['S3'], isNull);
    });
  });

  group('rowsFor', () {
    test('assignment rows join the assessment rows for that student only', () {
      final ama = _student('S1', 'Ama');
      final kofi = _student('S2', 'Kofi');
      final cw = _assessment('MATH', AssessmentType.classTest);
      final assignmentRows = ReportingService.assignmentRowsFor(
        assignments: [_assignment('ASG-1')],
        assignmentSubs: [_asub('SUB-1', 'ASG-1', 'S1')],
        drafts: [_draft(id: 'D1', submissionId: 'SUB-1', studentId: 'S1')],
      );

      final forAma = ReportingService().rowsFor(
        student: ama,
        assessments: [cw],
        subs: [_sub(cw, ama, 80)],
        assignmentRows: assignmentRows,
      );
      expect(forAma.map((r) => r.title), ['MATH Class Test', 'Title ASG-1']);
      expect(forAma.last.earned, 60);

      // Kofi has no assignment of his own and must not inherit Ama's.
      final forKofi = ReportingService().rowsFor(
        student: kofi,
        assessments: [cw],
        subs: [_sub(cw, kofi, 50)],
        assignmentRows: assignmentRows,
      );
      expect(forKofi.map((r) => r.title), ['MATH Class Test']);
    });
  });

  group('report card', () {
    // Ama: class work 80, exam 70, plus one homework worth 60 of 100.
    // Without the homework the terminal report reads 30·0.8 + 70·0.7 = 73.
    final ama = _student('S1', 'Ama');
    final kofi = _student('S2', 'Kofi');
    final cw = _assessment('MATH', AssessmentType.classTest);
    final ex = _assessment('MATH', AssessmentType.endTerm);
    final assessments = [cw, ex];
    final subs = [_sub(cw, ama, 80), _sub(ex, ama, 70), _sub(cw, kofi, 90)];

    final assignmentRows = ReportingService.assignmentRowsFor(
      assignments: [_assignment('ASG-1')],
      assignmentSubs: [_asub('SUB-1', 'ASG-1', 'S1')],
      drafts: [_draft(id: 'D1', submissionId: 'SUB-1', studentId: 'S1')],
    );

    ReportCardData build({Map<String, List<ReportCardRow>> assignmentRows = const {}}) =>
        ReportCardDataBuilder.build(
          student: ama,
          school: const School(id: 'SCH-001', name: 'Achimota Hills Academy'),
          term: _term,
          assessments: assessments,
          subs: subs,
          roster: [ama, kofi],
          assignmentRows: assignmentRows,
        );

    mathsOf(ReportCardData card) => card.subjects
        .firstWhere((s) => s.subjectId == 'MATH');

    test('homework counts as class work and moves the class score', () {
      final maths = mathsOf(build(assignmentRows: assignmentRows));
      // class work is now mean(80, 60) = 70, weighted 30% → 21.
      expect(maths.classScore, closeTo(21, 1e-9));
      // The exam is untouched: homework is never read as the end-of-term.
      expect(maths.examScore, closeTo(49, 1e-9));
      expect(maths.total, closeTo(70, 1e-9));
    });

    test('a card with no finalized assignment is unchanged', () {
      final maths = mathsOf(build());
      expect(maths.classScore, closeTo(24, 1e-9));
      expect(maths.examScore, closeTo(49, 1e-9));
      expect(maths.total, closeTo(73, 1e-9));
    });

    test('homework counts for ranking, so a classmate is scored on it too', () {
      // Kofi has no homework, Ama does — both are still ranked on the same
      // set of papers, so Ama's card must not place her against a shorter
      // list than the students she is measured with.
      final withHw = build(assignmentRows: assignmentRows);
      expect(withHw.rollSize, 2);

      final withoutHw = build();
      expect(withoutHw.rollSize, 2);
    });
  });
}
