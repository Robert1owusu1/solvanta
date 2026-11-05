import 'package:flutter_test/flutter_test.dart';

import 'package:solvanta/core/models/class_room.dart';
import 'package:solvanta/core/models/student.dart';
import 'package:solvanta/features/students/students_io.dart';

Student _existing(String id, String adm) => Student(
      id: id,
      firstName: 'Old',
      lastName: 'Pupil',
      gender: 'M',
      dateOfBirth: '2010-01-01',
      admissionDate: '2023-09-01',
      admissionNo: adm,
      classId: 'JHS1A',
      schoolId: 'SCH-001',
    );

void main() {
  const classes = [
    ClassRoom(id: 'JHS1A', name: 'JHS 1', stream: 'A'),
    ClassRoom(id: 'JHS2A', name: 'JHS 2', stream: 'A'),
  ];
  final existing = [_existing('STU-OLD', 'S-OLD')];

  List<StudentPreviewRow> preview(List<StudentUploadRow> rows) =>
      buildStudentPreview(classes: classes, existing: existing, rows: rows);

  test('template lists valid class ids and round-trips XLSX headers', () {
    expect(studentTemplateCsv(classes), contains('JHS1A, JHS2A'));
    final rows = parseStudentXlsx(studentTemplateXlsx(classes));
    expect(rows, isEmpty); // template has only blank example rows
  });

  test('a complete valid row is accepted', () {
    final p = preview([
      const StudentUploadRow(
          firstName: 'Ama', lastName: 'K', gender: 'female', classId: 'JHS1A')
    ]);
    expect(p.single.status, StudentRowStatus.valid);
    expect(p.single.gender, 'F');
    expect(p.single.willWrite, isTrue);
  });

  test('missing name, bad gender and unknown class are errors', () {
    expect(preview([const StudentUploadRow(gender: 'M', classId: 'JHS1A')]).single.status,
        StudentRowStatus.error);
    expect(preview([const StudentUploadRow(firstName: 'A', gender: 'X', classId: 'JHS1A')]).single.status,
        StudentRowStatus.error);
    expect(preview([const StudentUploadRow(firstName: 'A', gender: 'M', classId: 'ZZZ')]).single.status,
        StudentRowStatus.error);
  });

  test('a duplicate admission number warns but still writes', () {
    final p = preview([
      const StudentUploadRow(
          firstName: 'A', gender: 'M', classId: 'JHS1A', admissionNo: 'S-OLD'),
    ]);
    expect(p.single.status, StudentRowStatus.warning);
    expect(p.single.willWrite, isTrue);
  });

  test('parsing finds the header and reads data rows', () {
    const csv = 'SOLVANTA — Register Students\n'
        'note\n\n'
        'firstName,lastName,gender,admissionNo,classId\n'
        'Ama,Mensah,F,S-100,JHS1A\n';
    final rows = parseStudentCsv(csv);
    expect(rows.single.firstName, 'Ama');
    expect(rows.single.classId, 'JHS1A');
  });

  test('summary tallies verdicts', () {
    final p = preview([
      const StudentUploadRow(firstName: 'A', gender: 'M', classId: 'JHS1A'),
      const StudentUploadRow(firstName: 'B', gender: 'M', classId: 'JHS1A', admissionNo: 'S-OLD'),
      const StudentUploadRow(firstName: 'C', gender: 'M', classId: 'ZZZ'),
    ]);
    final s = summarizeStudents(p);
    expect(s.valid, 1);
    expect(s.warning, 1);
    expect(s.error, 1);
  });
}
