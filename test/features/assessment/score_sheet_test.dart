import 'package:flutter_test/flutter_test.dart';

import 'package:solvanta/core/models/assessment.dart';
import 'package:solvanta/core/models/grading.dart';
import 'package:solvanta/core/models/school_term.dart';
import 'package:solvanta/core/models/student.dart';
import 'package:solvanta/core/models/submission.dart';
import 'package:solvanta/features/assessment/score_sheet/score_sheet.dart';

Student _student(String id, String admission, String first, String last) =>
    Student(
      id: id,
      firstName: first,
      lastName: last,
      gender: 'M',
      dateOfBirth: '2010-01-01',
      admissionDate: '2023-09-01',
      admissionNo: admission,
      classId: 'JHS2A',
      schoolId: 'SCH-001',
    );

Assessment _assessment(String id, AssessmentType type, double max, String date) =>
    Assessment(
      id: id,
      title: id,
      type: type,
      subjectId: 'SCI',
      classId: 'JHS2A',
      date: date,
      createdBy: 'T',
      questions: const [],
      maxScore: max,
    );

AssessmentSubmission _manual(String aId, String sId, double earned,
        {bool absent = false}) =>
    AssessmentSubmission(
      id: 'SUB-$aId-$sId',
      assessmentId: aId,
      studentId: sId,
      classId: 'JHS2A',
      date: '2026-10-01',
      answers: const {},
      teacherMarks: const {},
      earned: earned,
      source: SubmissionSource.manual,
      absent: absent,
    );

void main() {
  final term = const SchoolTerm(
      year: '2026/2027', name: 'Term 1', start: '2026-09-01', end: '2026-12-20');
  final scheme = gesBasicPreset; // 30 / 70, grades 1–9
  final students = [
    _student('STU-001', 'S-001', 'Kojo', 'Owusu'),
    _student('STU-002', 'S-002', 'Akosua', 'Boaduwaa'),
    _student('STU-003', 'S-003', 'Kwabena', 'Adjei'),
  ];
  final assessments = [
    _assessment('CA', AssessmentType.classTest, 10, '2026-10-01'),
    _assessment('EX', AssessmentType.endTerm, 20, '2026-10-02'),
  ];

  ScoreSheet build(List<AssessmentSubmission> subs) => buildScoreSheet(
        classId: 'JHS2A',
        subjectId: 'SCI',
        assessments: assessments,
        students: students,
        subs: subs,
        scheme: scheme,
        term: term,
      );

  group('weighting', () {
    test('applies the class/exam split and grades the total', () {
      // 80% class work, 70% exam → 80*.3 + 70*.7 = 73 → grade "2".
      final sheet = build([_manual('CA', 'STU-001', 8), _manual('EX', 'STU-001', 14)]);
      final row = sheet.rows.firstWhere((r) => r.student.id == 'STU-001');
      expect(row.hasTotal, isTrue);
      expect(row.termTotal, closeTo(73, 1e-9));
      expect(row.grade, '2');
      expect(row.cells.length, 2);
    });

    test('a pupil with no scores has no total and no position', () {
      final sheet = build([_manual('CA', 'STU-001', 8)]);
      final row = sheet.rows.firstWhere((r) => r.student.id == 'STU-002');
      expect(row.hasTotal, isFalse);
      expect(row.position, 0);
    });

    test('ranks pupils by term total, best first', () {
      final sheet = build([
        _manual('CA', 'STU-001', 8), _manual('EX', 'STU-001', 14), // 73
        _manual('CA', 'STU-002', 10), _manual('EX', 'STU-002', 20), // 100
      ]);
      final p1 = sheet.rows.firstWhere((r) => r.student.id == 'STU-002');
      final p2 = sheet.rows.firstWhere((r) => r.student.id == 'STU-001');
      expect(p1.position, 1);
      expect(p2.position, 2);
    });
  });

  group('absent', () {
    test('an absence is excluded from the weighted total', () {
      // Absent class work, 100% exam → total is the exam alone, not a zero.
      final sheet = build([
        _manual('CA', 'STU-002', 0, absent: true),
        _manual('EX', 'STU-002', 20),
      ]);
      final row = sheet.rows.firstWhere((r) => r.student.id == 'STU-002');
      expect(row.termTotal, closeTo(100, 1e-9));
      final caCell = row.cells.firstWhere((c) => c.assessmentId == 'CA');
      expect(caCell.absent, isTrue);
      expect(caCell.marker, 'Absent');
    });
  });

  group('export generation', () {
    final sheet = buildScoreSheet(
      classId: 'JHS2A',
      subjectId: 'SCI',
      assessments: assessments,
      students: students,
      subs: [_manual('CA', 'STU-001', 8), _manual('EX', 'STU-001', 14)],
      scheme: scheme,
      term: term,
    );

    test('xlsx workbook is produced', () {
      final bytes = scoreSheetXlsx(sheet);
      expect(bytes, isNotEmpty);
      // XLSX is a zip: it begins with "PK".
      expect(bytes[0], 0x50);
      expect(bytes[1], 0x4B);
    });

    test('pdf document is produced', () async {
      final bytes = await scoreSheetPdf(sheet);
      expect(bytes, isNotEmpty);
      // PDF begins with "%PDF".
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });
  });
}
