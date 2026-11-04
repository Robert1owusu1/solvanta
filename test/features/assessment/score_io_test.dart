import 'package:flutter_test/flutter_test.dart';

import 'package:solvanta/core/models/assessment.dart';
import 'package:solvanta/core/models/student.dart';
import 'package:solvanta/features/assessment/manual_scores/score_io.dart';

Student _student(String id, String admissionNo, String first, String last) =>
    Student(
      id: id,
      firstName: first,
      lastName: last,
      gender: 'M',
      dateOfBirth: '2010-01-01',
      admissionDate: '2023-09-01',
      admissionNo: admissionNo,
      classId: 'JHS2A',
      schoolId: 'SCH-001',
    );

Assessment _scoreOnly({double max = 20}) => Assessment(
      id: 'ASSMT-1',
      title: 'Paper Test',
      type: AssessmentType.classTest,
      subjectId: 'MATH',
      classId: 'JHS2A',
      date: '2026-10-01',
      createdBy: 'Ms. Efua Mensah',
      questions: const [],
      maxScore: max,
    );

void main() {
  final roster = [
    _student('STU-001', 'S-2023-001', 'Kojo', 'Owusu'),
    _student('STU-002', 'S-2023-002', 'Akosua', 'Boaduwaa'),
    _student('STU-003', 'S-2023-003', 'Kwabena', 'Adjei'),
  ];
  final assessment = _scoreOnly();

  group('template generation', () {
    test('CSV carries the title, max score, header and the whole roster', () {
      final csv = scoreTemplateCsv(assessment, roster);
      final lines = csv.trim().split('\n');
      expect(lines.first, contains('SOLVANTA'));
      expect(csv, contains('Max Score,20'));
      expect(csv, contains(scoreColumns.join(',')));
      // One prefilled line per pupil, carrying id and admission number.
      expect(csv, contains('STU-001,S-2023-001,Kojo Owusu,,,'));
      expect(csv, contains('STU-003,S-2023-003,Kwabena Adjei,,,'));
    });

    test('XLSX round-trips back to the same roster rows', () {
      final bytes = scoreTemplateXlsx(assessment, roster);
      expect(bytes, isNotEmpty);
      final rows = parseScoreXlsx(bytes);
      expect(rows.length, 3);
      expect(rows[0].studentId, 'STU-001');
      expect(rows[0].admissionNo, 'S-2023-001');
      expect(rows[0].studentName, 'Kojo Owusu');
      expect(rows[0].scoreText, '');
    });
  });

  group('CSV parsing', () {
    test('skips metadata rows and reads data by header, not column order', () {
      const csv = 'SOLVANTA — Score Sheet\n'
          'Assessment,Paper Test\n'
          'Max Score,20\n'
          '\n'
          'studentId,admissionNo,studentName,score,absent,remark\n'
          'STU-001,S-2023-001,Kojo Owusu,15,,good\n'
          'STU-002,S-2023-002,Akosua Boaduwaa,,yes,sick\n';
      final rows = parseScoreCsv(csv);
      expect(rows.length, 2);
      expect(rows[0].studentId, 'STU-001');
      expect(rows[0].scoreText, '15');
      expect(rows[0].remark, 'good');
      expect(rows[1].absentText, 'yes');
    });

    test('handles quoted fields with commas', () {
      const csv = 'studentId,admissionNo,studentName,score,absent,remark\n'
          'STU-001,S-2023-001,"Owusu, Kojo",15,,"neat, tidy"\n';
      final rows = parseScoreCsv(csv);
      expect(rows.single.studentName, 'Owusu, Kojo');
      expect(rows.single.remark, 'neat, tidy');
    });

    test('returns nothing when there is no header row', () {
      expect(parseScoreCsv('just,some,noise\n1,2,3\n'), isEmpty);
    });
  });

  group('preview validation', () {
    List<ScorePreviewRow> preview(List<ScoreUploadRow> rows) =>
        buildScorePreview(assessment: assessment, roster: roster, rows: rows);

    test('a clean numeric score is valid and goes into the payload', () {
      final p = preview([const ScoreUploadRow(studentId: 'STU-001', scoreText: '15')]);
      expect(p.single.status, ScoreRowStatus.valid);
      expect(p.single.willWrite, isTrue);
      expect(scorePayload(p).single['score'], 15.0);
    });

    test('matches on admission number when no id is given', () {
      final p = preview([const ScoreUploadRow(admissionNo: 'S-2023-002', scoreText: '10')]);
      expect(p.single.status, ScoreRowStatus.valid);
      expect(p.single.resolvedStudentId, 'STU-002');
    });

    test('never matches on name alone', () {
      final p = preview([const ScoreUploadRow(studentName: 'Kojo Owusu', scoreText: '10')]);
      expect(p.single.status, ScoreRowStatus.error);
      expect(p.single.resolvedStudentId, isNull);
    });

    test('unknown student is an error', () {
      final p = preview([const ScoreUploadRow(studentId: 'STU-999', scoreText: '5')]);
      expect(p.single.status, ScoreRowStatus.error);
      expect(p.single.message, contains('Unknown'));
    });

    test('a score over the max is an error', () {
      final p = preview([const ScoreUploadRow(studentId: 'STU-001', scoreText: '25')]);
      expect(p.single.status, ScoreRowStatus.error);
      expect(p.single.message, contains('above the maximum'));
    });

    test('a non-numeric score is an error', () {
      final p = preview([const ScoreUploadRow(studentId: 'STU-001', scoreText: 'abc')]);
      expect(p.single.status, ScoreRowStatus.error);
      expect(p.single.message, contains('not a number'));
    });

    test('a duplicate row for the same pupil is an error', () {
      final p = preview([
        const ScoreUploadRow(studentId: 'STU-001', scoreText: '10'),
        const ScoreUploadRow(studentId: 'STU-001', scoreText: '12'),
      ]);
      expect(p[0].status, ScoreRowStatus.valid);
      expect(p[1].status, ScoreRowStatus.error);
      expect(p[1].message, contains('Duplicate'));
    });

    test('absent is recorded, half marks are allowed, blank rows are skipped', () {
      final p = preview([
        const ScoreUploadRow(studentId: 'STU-001', absentText: 'yes'),
        const ScoreUploadRow(studentId: 'STU-002', scoreText: '7.5'),
        const ScoreUploadRow(studentId: 'STU-003', scoreText: ''),
      ]);
      expect(p[0].status, ScoreRowStatus.valid);
      expect(p[0].absent, isTrue);
      expect(p[1].score, 7.5);
      expect(p[2].status, ScoreRowStatus.warning); // empty, skipped
      expect(p[2].willWrite, isFalse);

      final payload = scorePayload(p);
      expect(payload.length, 2); // absent + the 7.5 score; blank skipped
      expect(payload.firstWhere((r) => r['studentId'] == 'STU-001')['absent'], isTrue);
    });

    test('a score alongside absent warns and keeps the absence', () {
      final p = preview([const ScoreUploadRow(studentId: 'STU-001', scoreText: '10', absentText: 'true')]);
      expect(p.single.status, ScoreRowStatus.warning);
      expect(p.single.absent, isTrue);
      expect(p.single.score, isNull);
    });

    test('summary tallies the three verdicts', () {
      final p = preview([
        const ScoreUploadRow(studentId: 'STU-001', scoreText: '10'), // valid
        const ScoreUploadRow(studentId: 'STU-002', scoreText: ''), // warning
        const ScoreUploadRow(studentId: 'STU-999', scoreText: '5'), // error
      ]);
      final s = summarizePreview(p);
      expect(s.valid, 1);
      expect(s.warning, 1);
      expect(s.error, 1);
      expect(s.hasBlockingErrors, isTrue);
    });
  });
}
