import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:solvanta/core/models/assessment.dart';
import 'package:solvanta/core/models/class_ladder.dart';
import 'package:solvanta/core/models/class_room.dart';
import 'package:solvanta/core/models/grading.dart';
import 'package:solvanta/core/models/question.dart';
import 'package:solvanta/core/models/school.dart';
import 'package:solvanta/core/models/school_term.dart';
import 'package:solvanta/core/models/student.dart';
import 'package:solvanta/core/models/submission.dart';
import 'package:solvanta/features/reports/report_card_pdf.dart';

const _t1 = SchoolTerm(
    year: '2026/2027', name: 'Term 1', start: '2026-09-07', end: '2026-12-18');
const _t2 = SchoolTerm(
    year: '2026/2027', name: 'Term 2', start: '2027-01-11', end: '2027-04-09');
const _t3 = SchoolTerm(
    year: '2026/2027', name: 'Term 3', start: '2027-04-26', end: '2027-07-23');
// Last year's term must not count towards this year.
const _lastYear = SchoolTerm(
    year: '2025/2026', name: 'Term 3', start: '2026-04-20', end: '2026-07-24');

const _classes = [
  ClassRoom(id: 'JHS1A', name: 'JHS1', stream: 'A'),
  ClassRoom(id: 'JHS2A', name: 'JHS2', stream: 'A'),
  ClassRoom(id: 'JHS2B', name: 'JHS2', stream: 'B'),
  ClassRoom(id: 'JHS3A', name: 'JHS3', stream: 'A'),
];

/// JHS: promoted at 50+, repeats under 40, parents asked in under 45.
final _grading = GradingConfig(schemes: [
  gesBasicPreset
      .copyWith(name: 'JHS', isDefault: true)
      .withYearRules(promoteAt: 50, repeatBelow: 40, interventionBelow: 45),
]);

/// Ten subjects, like a real JHS timetable.
const _subjects = [
  'MATH', 'ENG', 'SCI', 'SOC', 'ICT', 'RME', 'FRE', 'GHL', 'CAD', 'CTE',
];

Student _student(String classId) => Student(
      id: 'S1',
      firstName: 'Kofi',
      lastName: 'Asante',
      gender: 'Male',
      dateOfBirth: '2012-05-01',
      admissionDate: '2024-09-02',
      admissionNo: 'ADM-0001',
      classId: classId,
      schoolId: 'SCH-001',
    );

/// One 100-mark end-of-term exam per subject per term, scored [marks][term].
({List<Assessment> papers, List<AssessmentSubmission> subs}) _year(
    Student s, Map<SchoolTerm, double> marks) {
  final papers = <Assessment>[];
  final subs = <AssessmentSubmission>[];
  for (final e in marks.entries) {
    final date = e.key.start.replaceRange(8, 10, '28');
    for (final subj in _subjects) {
      final a = Assessment(
        id: '${e.key.year}-${e.key.name}-$subj',
        title: '$subj exam',
        type: AssessmentType.endTerm,
        subjectId: subj,
        classId: s.classId,
        date: date,
        createdBy: 'T',
        questions: [
          Question(
            id: 'Q-$subj',
            type: QuestionType.structured,
            subjectId: subj,
            classId: s.classId,
            topic: 't',
            difficulty: 1,
            cognitiveLevel: 'Knowledge',
            marks: 100,
            stem: 's',
          ),
        ],
      );
      papers.add(a);
      subs.add(AssessmentSubmission(
        id: '${a.id}-${s.id}',
        assessmentId: a.id,
        studentId: s.id,
        classId: s.classId,
        date: date,
        answers: const {},
        teacherMarks: const {},
        earned: e.value,
      ));
    }
  }
  return (papers: papers, subs: subs);
}

ReportCardData _card(SchoolTerm term, Map<SchoolTerm, double> marks,
    {String classId = 'JHS2A',
    String? nowIn,
    GradingConfig? grading,
    GradingConfig? pastGrading}) {
  final s = _student(classId);
  final y = _year(s, marks);
  return ReportCardDataBuilder.build(
    // [nowIn]: the class the student has since been moved to.
    student: nowIn == null ? s : s.copyWith(classId: nowIn),
    school: const School(id: 'SCH-001', name: 'Achimota Hills Academy'),
    term: term,
    assessments: y.papers,
    subs: y.subs,
    roster: [s],
    pastTerms: [
      for (final t in [_lastYear, _t1, _t2])
        FinishedTerm(t, pastGrading ?? grading ?? _grading),
    ],
    teacherName: 'Ms. Efua Mensah',
    grading: grading ?? _grading,
    classes: _classes,
  );
}

void main() {
  group('class ladder', () {
    test('keeps the stream and moves up a level', () {
      expect(nextClassId('JHS1A'), 'JHS2A');
      expect(nextClassId('JHS2B', _classes), 'JHS3A'); // no JHS3B: first stream
      expect(nextClassId('JHS3A'), isNull);
      expect(nextClassId('KG2A'), 'B1A');
      expect(nextClassId('B6A'), 'JHS1A');
      expect(
        nextClassId('B6A', const [ClassRoom(id: 'B7A', name: 'B7', stream: 'A')]),
        'B7A',
      );
      expect(nextClassId('B9A',
              const [ClassRoom(id: 'B9A', name: 'B9', stream: 'A')]),
          isNull);
      expect(classLevel('JHS2A'), 'JHS2');
    });
  });

  group('year average', () {
    test('is the mean of this year\'s term averages, out of 300', () {
      final card = _card(_t3, {_lastYear: 10, _t1: 60, _t2: 70, _t3: 80});
      expect(card.year.terms.map((t) => t.name), ['Term 1', 'Term 2', 'Term 3']);
      expect(card.year.total, closeTo(210, 1e-9));
      expect(card.year.outOf, 300);
      expect(card.year.average, closeTo(70, 1e-9));
      expect(card.year.formula, '(60.0 + 70.0 + 80.0) ÷ 3 = 70.0');
    });

    test('Term 2 shows the year so far', () {
      final card = _card(_t2, {_t1: 60, _t2: 70});
      expect(card.year.formula, '(60.0 + 70.0) ÷ 2 = 65.0');
      expect(card.outcome, isNull); // decided only on Term 3
      expect(yearBars(card.year).map((b) => b.label),
          ['Term 1', 'Term 2', 'Term 3', 'Year avg.']);
      expect(yearBars(card.year)[2].value, isNull);
    });
  });

  test('a student who joined in Term 3 gets Term 3 in the third slot', () {
    final bars = yearBars(const YearProgress([YearTerm('Term 3', 72)]));
    expect(bars.map((b) => b.label),
        ['Term 1', 'Term 2', 'Term 3', 'Year avg.']);
    expect(bars.map((b) => b.value), [null, null, 72, 72]);
  });

  test('a past term is graded with the set-up it ended under', () {
    // Term 1 was awarded on letters; the school has since moved to 1–9.
    final letters = GradingConfig(
        schemes: [letterPreset.copyWith(name: 'Old', isDefault: true)]);
    final card =
        _card(_t2, {_t1: 75, _t2: 75}, pastGrading: letters);
    final t1 = card.history.firstWhere((t) => t.termLabel == _t1.label);
    expect(t1.subjects.first.termGrade, 'B'); // letters: 70–79 is B
    expect(card.subjects.first.termGrade, '2'); // today: 70–79 is 2
  });

  test('a Term 3 card printed after promotion still reports JHS2A', () {
    final card =
        _card(_t3, {_t1: 60, _t2: 70, _t3: 80}, nowIn: 'JHS3A');
    expect(card.classId, 'JHS2A');
    expect(card.subjects, hasLength(_subjects.length));
    expect(card.promotedTo, 'JHS3A');
    expect(card.year.average, closeTo(70, 1e-9));
  });

  group('end of year', () {
    test('50+ is promoted to the next class, same stream', () {
      final card = _card(_t3, {_t1: 60, _t2: 70, _t3: 80});
      expect(card.outcome, YearOutcome.promoted);
      expect(card.promotedTo, 'JHS3A');
      expect(endOfYearLabel(card), 'JHS3A');
      expect(card.remark, contains('Promoted to JHS3A.'));
      expect(card.interventionNeeded, isFalse);
    });

    test('under 40 repeats, and the parents are asked in', () {
      final card = _card(_t3, {_t1: 30, _t2: 35, _t3: 38});
      expect(card.outcome, YearOutcome.repeated);
      expect(card.promotedTo, isNull);
      expect(endOfYearLabel(card), 'Repeated - stays in JHS2');
      expect(card.remark, contains('To repeat JHS2 next year.'));
      expect(card.interventionNeeded, isTrue);
      expect(card.remark, contains("meet Kofi's parents"));
    });

    test('between the marks goes to the headteacher', () {
      final card = _card(_t3, {_t1: 44, _t2: 46, _t3: 47});
      expect(card.outcome, YearOutcome.review);
      expect(endOfYearLabel(card), "Awaiting headteacher's decision");
    });

    test('the final class completes instead of moving up', () {
      final card = _card(_t3, {_t1: 70, _t2: 70, _t3: 70}, classId: 'JHS3A');
      expect(card.outcome, YearOutcome.completed);
      expect(card.promotedTo, isNull);
    });

    test('with no thresholds set, the line is left to be written in', () {
      final card = _card(_t3, {_t1: 70, _t2: 70, _t3: 70},
          grading: GradingConfig.fallback);
      expect(card.outcome, isNull);
      expect(endOfYearLabel(card), '');
      expect(card.interventionNeeded, isFalse);
    });

    test('intervention shows from Term 2, not Term 1', () {
      expect(_card(_t1, {_t1: 30}).interventionNeeded, isFalse);
      expect(_card(_t2, {_t1: 30, _t2: 30}).interventionNeeded, isTrue);
    });

    test('a rule set from one side splits the year in two', () {
      final onlyPromote = gesBasicPreset.withYearRules(promoteAt: 50);
      expect(onlyPromote.outcomeFor(49.9, finalClass: false),
          YearOutcome.repeated);
      expect(onlyPromote.outcomeFor(50, finalClass: false),
          YearOutcome.promoted);
      // 49.96 prints as 50.0, so it is decided as 50.
      expect(onlyPromote.outcomeFor(49.96, finalClass: false),
          YearOutcome.promoted);
      expect(
          gesBasicPreset
              .copyWith(isDefault: true)
              .withYearRules(repeatBelow: 50, promoteAt: 40)
              .problem(),
          contains("can't be above"));
    });
  });

  test('Term 2 and Term 3 cards fit one page with ten subjects', () async {
    final out = Platform.environment['REPORT_CARD_OUT'];
    for (final (name, card) in [
      ('term2', _card(_t2, {_t1: 44, _t2: 41})),
      ('term3', _card(_t3, {_t1: 60, _t2: 70, _t3: 80})),
    ]) {
      for (final t in ReportCardTemplate.values) {
        final bytes = await buildReportCardPdf(card, t);
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        if (out != null) {
          File('$out/year_${name}_${t.name}.pdf').writeAsBytesSync(bytes);
        }
      }
    }
  });
}
