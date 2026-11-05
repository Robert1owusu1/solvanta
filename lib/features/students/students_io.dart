import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../../core/models/class_room.dart';
import '../../core/models/student.dart';

/// Template generation, upload parsing and preview validation for **bulk
/// student registration** — the same preview-then-confirm pattern as scores and
/// payments. Pure (no Flutter, no I/O) so it is unit-testable.

const List<String> studentColumns = [
  'firstName',
  'lastName',
  'gender',
  'admissionNo',
  'classId',
];

enum StudentRowStatus { valid, warning, error }

class StudentUploadRow {
  final String firstName;
  final String lastName;
  final String gender;
  final String admissionNo;
  final String classId;

  const StudentUploadRow({
    this.firstName = '',
    this.lastName = '',
    this.gender = '',
    this.admissionNo = '',
    this.classId = '',
  });

  bool get isBlank =>
      firstName.isEmpty &&
      lastName.isEmpty &&
      gender.isEmpty &&
      admissionNo.isEmpty &&
      classId.isEmpty;
}

class StudentPreviewRow {
  final int line;
  final StudentUploadRow raw;
  final StudentRowStatus status;
  final String message;
  final String firstName;
  final String lastName;
  final String gender; // 'M' | 'F'
  final String admissionNo;
  final String classId;

  const StudentPreviewRow({
    required this.line,
    required this.raw,
    required this.status,
    required this.message,
    this.firstName = '',
    this.lastName = '',
    this.gender = '',
    this.admissionNo = '',
    this.classId = '',
  });

  bool get willWrite => status != StudentRowStatus.error;
}

String _gender(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'm':
    case 'male':
    case 'boy':
      return 'M';
    case 'f':
    case 'female':
    case 'girl':
      return 'F';
    default:
      return '';
  }
}

// ---------------------------------------------------------------------------
// Template
// ---------------------------------------------------------------------------

/// A blank import template. [classIds] is listed in a note so the teacher knows
/// the valid class ids to use.
String studentTemplateCsv(List<ClassRoom> classes) {
  final b = StringBuffer();
  b.writeln('SOLVANTA — Register Students');
  b.writeln(_csv('gender is M or F. classId is one of: '
      '${classes.map((c) => c.id).join(', ')}'));
  b.writeln();
  b.writeln(studentColumns.map(_csv).join(','));
  // A couple of blank example rows to type into.
  for (var i = 0; i < 3; i++) {
    b.writeln(List.filled(studentColumns.length, '').join(','));
  }
  return b.toString();
}

Uint8List studentTemplateXlsx(List<ClassRoom> classes) {
  final excel = Excel.createExcel();
  final ws = excel['Students'];
  ws.appendRow([TextCellValue('SOLVANTA — Register Students')]);
  ws.appendRow([
    TextCellValue('gender M/F · classId one of: '
        '${classes.map((c) => c.id).join(', ')}')
  ]);
  ws.appendRow([TextCellValue('')]);
  ws.appendRow(studentColumns.map(TextCellValue.new).toList());
  for (var i = 0; i < 3; i++) {
    ws.appendRow(
        List<CellValue>.filled(studentColumns.length, TextCellValue('')));
  }
  return Uint8List.fromList(excel.encode() ?? const []);
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

List<StudentUploadRow> parseStudentCsv(String text) =>
    _rows(_parseCsvGrid(text));

List<StudentUploadRow> parseStudentXlsx(Uint8List bytes) {
  final excel = Excel.decodeBytes(bytes);
  for (final table in excel.tables.values) {
    final grid = <List<String>>[
      for (final row in table.rows)
        [for (final cell in row) cell?.value?.toString() ?? '']
    ];
    final rows = _rows(grid);
    if (rows.isNotEmpty) return rows;
  }
  return const [];
}

List<StudentUploadRow> _rows(List<List<String>> grid) {
  var headerAt = -1;
  for (var i = 0; i < grid.length; i++) {
    if (grid[i].isNotEmpty && grid[i][0].trim().toLowerCase() == 'firstname') {
      headerAt = i;
      break;
    }
  }
  if (headerAt < 0) return const [];
  final header = grid[headerAt].map((h) => h.trim().toLowerCase()).toList();
  int col(String n) => header.indexOf(n.toLowerCase());
  final iF = col('firstName'),
      iL = col('lastName'),
      iG = col('gender'),
      iA = col('admissionNo'),
      iC = col('classId');
  String at(List<String> r, int i) => (i >= 0 && i < r.length) ? r[i].trim() : '';

  final out = <StudentUploadRow>[];
  for (var i = headerAt + 1; i < grid.length; i++) {
    final r = grid[i];
    final row = StudentUploadRow(
      firstName: at(r, iF),
      lastName: at(r, iL),
      gender: at(r, iG),
      admissionNo: at(r, iA),
      classId: at(r, iC),
    );
    if (!row.isBlank) out.add(row);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Preview validation
// ---------------------------------------------------------------------------

List<StudentPreviewRow> buildStudentPreview({
  required List<ClassRoom> classes,
  required List<Student> existing,
  required List<StudentUploadRow> rows,
}) {
  final classIds = {for (final c in classes) c.id};
  final existingAdmissions = {
    for (final s in existing)
      if (s.admissionNo.isNotEmpty) s.admissionNo
  };
  final seenAdmissions = <String>{};

  final out = <StudentPreviewRow>[];
  for (var i = 0; i < rows.length; i++) {
    final raw = rows[i];
    final line = i + 1;
    final first = raw.firstName.trim();
    final last = raw.lastName.trim();
    final gender = _gender(raw.gender);

    if (first.isEmpty && last.isEmpty) {
      out.add(StudentPreviewRow(
          line: line, raw: raw, status: StudentRowStatus.error,
          message: 'A name is required'));
      continue;
    }
    if (gender.isEmpty) {
      out.add(StudentPreviewRow(
          line: line, raw: raw, status: StudentRowStatus.error,
          message: 'gender must be M or F'));
      continue;
    }
    if (raw.classId.isEmpty || !classIds.contains(raw.classId)) {
      out.add(StudentPreviewRow(
          line: line, raw: raw, status: StudentRowStatus.error,
          message: raw.classId.isEmpty
              ? 'classId is required'
              : 'Unknown class "${raw.classId}"'));
      continue;
    }

    // Duplicate admission numbers are a warning, not a block (some schools
    // leave them blank, and the independent flow allows it).
    var status = StudentRowStatus.valid;
    var message = 'OK';
    if (raw.admissionNo.isNotEmpty) {
      if (!seenAdmissions.add(raw.admissionNo) ||
          existingAdmissions.contains(raw.admissionNo)) {
        status = StudentRowStatus.warning;
        message = 'Admission no. ${raw.admissionNo} already exists — added anyway';
      }
    }

    out.add(StudentPreviewRow(
      line: line, raw: raw, status: status, message: message,
      firstName: first, lastName: last, gender: gender,
      admissionNo: raw.admissionNo, classId: raw.classId,
    ));
  }
  return out;
}

class StudentPreviewSummary {
  final int valid, warning, error;
  const StudentPreviewSummary(this.valid, this.warning, this.error);
  bool get hasBlockingErrors => error > 0;
}

StudentPreviewSummary summarizeStudents(List<StudentPreviewRow> preview) {
  var v = 0, w = 0, e = 0;
  for (final r in preview) {
    switch (r.status) {
      case StudentRowStatus.valid:
        v++;
      case StudentRowStatus.warning:
        w++;
      case StudentRowStatus.error:
        e++;
    }
  }
  return StudentPreviewSummary(v, w, e);
}

// ---------------------------------------------------------------------------
// CSV helpers
// ---------------------------------------------------------------------------

String _csv(String s) {
  var v = s;
  if (v.isNotEmpty && '=+-@\t\r'.contains(v[0])) v = "'$v";
  if (v.contains(',') || v.contains('"') || v.contains('\n')) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}

List<List<String>> _parseCsvGrid(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var i = 0;
  void endField() {
    row.add(field.toString());
    field.clear();
  }

  void endRow() {
    endField();
    rows.add(row);
    row = <String>[];
  }

  while (i < text.length) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
        i++;
        continue;
      }
      field.write(ch);
      i++;
      continue;
    }
    switch (ch) {
      case '"':
        inQuotes = true;
        i++;
      case ',':
        endField();
        i++;
      case '\r':
        i++;
      case '\n':
        endRow();
        i++;
      default:
        field.write(ch);
        i++;
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}
