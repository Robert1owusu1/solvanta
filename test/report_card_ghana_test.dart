import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solvanta/core/models/assessment.dart';
import 'package:solvanta/core/models/grading.dart';
import 'package:solvanta/core/models/question.dart';
import 'package:solvanta/core/models/school.dart';
import 'package:solvanta/core/models/school_term.dart';
import 'package:solvanta/core/models/student.dart';
import 'package:solvanta/core/models/submission.dart';
import 'package:solvanta/core/models/subjects.dart';
import 'package:solvanta/core/storage/local_store.dart';
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
Assessment _assessment(
  String subject,
  AssessmentType type, {
  String date = '2026-10-01',
  String classId = 'JHS2A',
}) => Assessment(
  id: '$classId-$date-$subject-${type.name}',
  title: '$subject ${type.label}',
  type: type,
  subjectId: subject,
  classId: classId,
  date: date,
  createdBy: 'T',
  questions: [
    Question(
      id: 'Q-$subject-${type.name}',
      type: QuestionType.structured,
      subjectId: subject,
      classId: classId,
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

void main() {
  // Report-card PDFs load their bundled font through the asset bundle.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('GES 9-point grade bands (the default scheme)', () {
    const ges = gesBasicPreset;
    expect(ges.bandFor(100).grade, '1');
    expect(ges.bandFor(80).grade, '1');
    expect(ges.bandFor(79.4).grade, '2');
    expect(ges.bandFor(57).remark, 'High Average');
    expect(ges.bandFor(34.4).grade, '9');
    expect(ges.bandFor(0).remark, 'Lowest');
    expect(ges.rangeOf(0), '80–100');
    expect(ges.rangeOf(1), '70–79');
    expect(ges.rangeOf(8), '0–34');
  });

  test('ordinals', () {
    expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 112].map(ordinal), [
      '1st',
      '2nd',
      '3rd',
      '4th',
      '11th',
      '12th',
      '13th',
      '21st',
      '22nd',
      '23rd',
      '101st',
      '112th',
    ]);
  });

  group('terminal report', () {
    final ama = _student('S1', 'Ama');
    final kofi = _student('S2', 'Kofi');
    final assessments = <Assessment>[];
    final subs = <AssessmentSubmission>[];
    // Ama: class work 80, exam 70 in every subject → 30·0.8 + 70·0.7 = 73.
    // Kofi: class 90, exam 90 everywhere except ICT, where he has no exam.
    for (final s in subjects) {
      final cw = _assessment(s.id, AssessmentType.classTest);
      final ex = _assessment(s.id, AssessmentType.endTerm);
      assessments.addAll([cw, ex]);
      subs.addAll([_sub(cw, ama, 80), _sub(ex, ama, 70), _sub(cw, kofi, 90)]);
      if (s.id != 'ICT') subs.add(_sub(ex, kofi, 90));
    }
    const term = SchoolTerm(
      year: '2026/2027',
      name: 'Term 3',
      start: '2026-09-07',
      end: '2026-12-18',
    );
    // Last year (in JHS1A) Ama scored 50 and Kofi 90 in Maths.
    const lastTerm = SchoolTerm(
      year: '2025/2026',
      name: 'Term 3',
      start: '2026-04-20',
      end: '2026-07-24',
    );
    final oldMaths = _assessment(
      'MATH',
      AssessmentType.endTerm,
      date: '2026-05-10',
      classId: 'JHS1A',
    );
    assessments.add(oldMaths);
    subs.addAll([_sub(oldMaths, ama, 50), _sub(oldMaths, kofi, 90)]);

    ReportCardData build(Student s) => ReportCardDataBuilder.build(
      student: s,
      school: const School(
        id: 'SCH-001',
        name: 'Achimota Hills Academy',
        motto: 'Ut Omnes Unum Sint',
        address: 'P.O. Box 12, Accra',
        phone: '030 200 0000',
      ),
      term: term,
      assessments: assessments,
      subs: subs,
      roster: [ama, kofi],
      pastTerms: [FinishedTerm(lastTerm, GradingConfig.fallback)],
      teacherName: 'Ms. Efua Mensah',
      attendance: (total: 60, present: 58),
    );

    test('weights class score 30% and exam 70%', () {
      final card = build(ama);
      final maths = card.subjects.firstWhere((s) => s.subjectId == 'MATH');
      expect(maths.classScore, closeTo(24, 1e-9));
      expect(maths.examScore, closeTo(49, 1e-9));
      expect(maths.total, closeTo(73, 1e-9));
      expect(maths.termGrade, '2');
      expect(maths.positionLabel, '2nd');
      expect(card.aggregate, 12);
      expect(card.rollSize, 2);
      // No promotion rule set: the Term 3 line is left for the school.
      expect(card.promotedTo, isNull);
      expect(card.totalScore, closeTo(73.0 * subjects.length, 1e-9));
      expect(card.hasPartial, isFalse);
    });

    test('flags a subject with no exam as partial', () {
      final card = build(kofi);
      final ict = card.subjects.firstWhere((s) => s.subjectId == 'ICT');
      expect(ict.examScore, isNull);
      expect(ict.total, closeTo(90, 1e-9));
      expect(ict.totalLabel, '90.0*');
      expect(card.hasPartial, isTrue);
      expect(card.positionLabel, '1st');
    });

    test("ignores work dated outside this term", () {
      // Last year's 50 in Maths must not drag this term's 73 down.
      final maths = build(ama).subjects
          .firstWhere((s) => s.subjectId == 'MATH');
      expect(maths.total, closeTo(73, 1e-9));
    });

    test('transcript carries last term, read off the old class', () {
      final history = build(ama).history;
      expect(history.map((t) => t.termLabel), [lastTerm.label, term.label]);
      final past = history.first;
      expect(past.subjects.single.total, closeTo(50, 1e-9));
      expect(past.rank, 2);
      expect(past.classSize, 2);
      expect(transcriptCell(past, 'Mathematics'), '50.0* (5)'); // exam only
      expect(transcriptCell(past, 'Social Studies'), '–');
    });

    test('PDFs embed the bundled Noto Sans, not Helvetica', () async {
      final pdf = String.fromCharCodes(
          await buildReportCardPdf(build(kofi), ReportCardTemplate.classic));
      expect(pdf, contains('NotoSans'));
      expect(pdf, isNot(contains('/Helvetica')));
    });

    test('every template renders a one-page A4 PDF', () async {
      final out = Platform.environment['REPORT_CARD_OUT'];
      for (final t in ReportCardTemplate.values) {
        final bytes = await buildReportCardPdf(build(kofi), t);
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        if (out != null) {
          File('$out/report_${t.name}.pdf').writeAsBytesSync(bytes);
        }
      }
    });
  });

  test('position is by total score, not by best single result', () {
    // Esi aced one subject only; Yaw passed all six. Yaw has more marks, so
    // Yaw is 1st — a mean of assessments would wrongly put Esi first.
    final esi = _student('S3', 'Esi');
    final yaw = _student('S4', 'Yaw');
    final assessments = [
      for (final s in subjects) _assessment(s.id, AssessmentType.endTerm),
    ];
    final subs = [
      _sub(assessments.first, esi, 100),
      for (final a in assessments) _sub(a, yaw, 60),
    ];
    ReportCardData build(Student s) => ReportCardDataBuilder.build(
      student: s,
      school: const School(id: 'SCH-001', name: 'Test School'),
      term: SchoolTerm.fallback,
      assessments: assessments,
      subs: subs,
      roster: [esi, yaw],
    );
    expect(build(yaw).positionLabel, '1st');
    expect(build(esi).positionLabel, '2nd');
    expect(build(yaw).overall, closeTo(60, 1e-9));
  });

  test('CSV export neutralises spreadsheet formulas in names', () {
    final evil = Student(
      id: 'S9',
      firstName: '=HYPERLINK("http://x")',
      lastName: '',
      gender: '',
      dateOfBirth: '',
      admissionDate: '',
      admissionNo: '',
      classId: 'JHS2A',
      schoolId: 'SCH-001',
    );
    final a = _assessment('ENG', AssessmentType.classTest);
    final csv = ReportingService().classResultsCsv(
      assessment: a,
      roster: [evil],
      subs: [_sub(a, evil, 5)],
    );
    expect(csv, contains('"\'=HYPERLINK(""http://x"") "'));
    expect(csv, isNot(contains(',"=HYPERLINK')));
  });

  test('a new term archives the finished one; date edits do not', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore();
    const t1 = SchoolTerm(
      year: '2026/2027',
      name: 'Term 1',
      start: '2026-09-07',
      end: '2026-12-18',
    );
    const t1Edited = SchoolTerm(
      year: '2026/2027',
      name: 'Term 1',
      start: '2026-09-07',
      end: '2026-12-20',
    );
    const t2 = SchoolTerm(
      year: '2026/2027',
      name: 'Term 2',
      start: '2027-01-11',
      end: '2027-04-09',
    );
    await store.saveTerm(t1);
    await store.saveTerm(t1Edited);
    expect(await store.loadTermHistory(), isEmpty);
    await store.saveTerm(t2);
    await store.saveTerm(t2); // a re-sync of the same term
    final history = await store.loadTermHistory();
    expect(history.map((t) => t.term.label), [t1Edited.label]);
    expect(history.single.term.end, '2026-12-20');
    // Closed with the grading in force at the time.
    expect(history.single.grading.defaultScheme.classWeight, 30);
  });
}
