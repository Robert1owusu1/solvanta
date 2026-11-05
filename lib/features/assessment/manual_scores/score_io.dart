import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../../../core/models/assessment.dart';
import '../../../core/models/student.dart';

/// Template generation, upload parsing and preview validation for bulk manual
/// score entry (schools that mark on paper).
///
/// This is deliberately pure — no Flutter, no I/O — so the template a teacher
/// downloads, the file they upload, and the valid/warning/error preview they
/// confirm are all unit-testable without a widget or a device. The confirmed
/// payload goes to `POST /api/assessments/:id/scores/bulk`.

/// The upload columns, in order. These are the headers the template writes and
/// the names the parser looks for.
const List<String> scoreColumns = [
  'studentId',
  'admissionNo',
  'studentName',
  'score',
  'absent',
  'remark',
];

/// A single verdict on a parsed row.
enum ScoreRowStatus { valid, warning, error }

/// One row as it was read from the upload, before validation.
class ScoreUploadRow {
  final String studentId;
  final String admissionNo;
  final String studentName;
  final String scoreText;
  final String absentText;
  final String remark;

  const ScoreUploadRow({
    this.studentId = '',
    this.admissionNo = '',
    this.studentName = '',
    this.scoreText = '',
    this.absentText = '',
    this.remark = '',
  });

  bool get isBlank =>
      studentId.isEmpty &&
      admissionNo.isEmpty &&
      studentName.isEmpty &&
      scoreText.isEmpty &&
      absentText.isEmpty &&
      remark.isEmpty;
}

/// One row after validation: its verdict, a human message, and — when it will
/// be written — the resolved student, score and absent flag.
class ScorePreviewRow {
  final int line; // 1-based data-row number, for the teacher to find it
  final ScoreUploadRow raw;
  final ScoreRowStatus status;
  final String message;
  final String? resolvedStudentId;
  final String? resolvedStudentName;
  final double? score;
  final bool absent;

  const ScorePreviewRow({
    required this.line,
    required this.raw,
    required this.status,
    required this.message,
    this.resolvedStudentId,
    this.resolvedStudentName,
    this.score,
    this.absent = false,
  });

  /// Whether this row contributes a score to the confirmed upload. Error rows
  /// never do; an empty, not-absent row is a warning that is skipped.
  bool get willWrite =>
      status != ScoreRowStatus.error &&
      resolvedStudentId != null &&
      (absent || score != null);

  bool get isError => status == ScoreRowStatus.error;
}

// ---------------------------------------------------------------------------
// Template generation
// ---------------------------------------------------------------------------

/// A filled-in CSV template: metadata header rows, the column header, then one
/// line per roster student with the score/absent/remark columns left blank.
String scoreTemplateCsv(Assessment assessment, List<Student> roster) {
  final b = StringBuffer();
  b.writeln('SOLVANTA — Score Sheet');
  b.writeln('${_csv('Assessment')},${_csv(assessment.title)}');
  b.writeln('${_csv('Max Score')},${_csv(_num(assessment.effectiveTotal))}');
  b.writeln();
  b.writeln(scoreColumns.map(_csv).join(','));
  for (final s in roster) {
    b.writeln([s.id, s.admissionNo, s.fullName, '', '', ''].map(_csv).join(','));
  }
  return b.toString();
}

/// The same template as an `.xlsx` workbook.
Uint8List scoreTemplateXlsx(Assessment assessment, List<Student> roster) {
  final excel = Excel.createExcel();
  final sheet = excel['Scores'];
  sheet.appendRow([TextCellValue('SOLVANTA — Score Sheet')]);
  sheet.appendRow([TextCellValue('Assessment'), TextCellValue(assessment.title)]);
  sheet.appendRow(
      [TextCellValue('Max Score'), TextCellValue(_num(assessment.effectiveTotal))]);
  sheet.appendRow([TextCellValue('')]);
  sheet.appendRow(scoreColumns.map(TextCellValue.new).toList());
  for (final s in roster) {
    sheet.appendRow([
      TextCellValue(s.id),
      TextCellValue(s.admissionNo),
      TextCellValue(s.fullName),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(''),
    ]);
  }
  return Uint8List.fromList(excel.encode() ?? const []);
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// Parses an uploaded CSV into raw rows, skipping the metadata header rows and
/// locating the column header by its first cell (`studentId`).
List<ScoreUploadRow> parseScoreCsv(String text) {
  return _rowsFromGrid(_parseCsvGrid(text));
}

/// Parses an uploaded `.xlsx` into raw rows. Every worksheet is tried (a
/// freshly created workbook carries an empty default sheet alongside ours), and
/// the first one that holds the `studentId` header wins.
List<ScoreUploadRow> parseScoreXlsx(Uint8List bytes) {
  final excel = Excel.decodeBytes(bytes);
  for (final table in excel.tables.values) {
    final grid = <List<String>>[];
    for (final row in table.rows) {
      grid.add([for (final cell in row) cell?.value?.toString() ?? '']);
    }
    final rows = _rowsFromGrid(grid);
    if (rows.isNotEmpty) return rows;
  }
  return const [];
}

/// Turns a parsed grid into score rows: finds the header, maps columns by name
/// (so column order can vary), and reads each non-blank data row.
List<ScoreUploadRow> _rowsFromGrid(List<List<String>> grid) {
  var headerAt = -1;
  for (var i = 0; i < grid.length; i++) {
    if (grid[i].isNotEmpty && grid[i][0].trim().toLowerCase() == 'studentid') {
      headerAt = i;
      break;
    }
  }
  if (headerAt < 0) return const [];

  final header = grid[headerAt].map((h) => h.trim().toLowerCase()).toList();
  int col(String name) => header.indexOf(name.toLowerCase());
  final iId = col('studentId');
  final iAdm = col('admissionNo');
  final iName = col('studentName');
  final iScore = col('score');
  final iAbsent = col('absent');
  final iRemark = col('remark');

  String at(List<String> r, int i) =>
      (i >= 0 && i < r.length) ? r[i].trim() : '';

  final out = <ScoreUploadRow>[];
  for (var i = headerAt + 1; i < grid.length; i++) {
    final r = grid[i];
    final row = ScoreUploadRow(
      studentId: at(r, iId),
      admissionNo: at(r, iAdm),
      studentName: at(r, iName),
      scoreText: at(r, iScore),
      absentText: at(r, iAbsent),
      remark: at(r, iRemark),
    );
    if (row.isBlank) continue;
    out.add(row);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Preview validation
// ---------------------------------------------------------------------------

/// Validates parsed rows against the class roster and the assessment's maximum,
/// returning a verdict per row. Rows are matched on [ScoreUploadRow.studentId]
/// first and [ScoreUploadRow.admissionNo] second — never on name.
List<ScorePreviewRow> buildScorePreview({
  required Assessment assessment,
  required List<Student> roster,
  required List<ScoreUploadRow> rows,
}) {
  final max = assessment.effectiveTotal;
  final byId = {for (final s in roster) s.id: s};
  final byAdmission = <String, List<Student>>{};
  for (final s in roster) {
    if (s.admissionNo.isNotEmpty) {
      byAdmission.putIfAbsent(s.admissionNo, () => []).add(s);
    }
  }

  final seen = <String, int>{}; // studentId -> first line it appeared on
  final out = <ScorePreviewRow>[];

  for (var i = 0; i < rows.length; i++) {
    final raw = rows[i];
    final line = i + 1;

    // Resolve the student.
    Student? student;
    String? resolveError;
    if (raw.studentId.isNotEmpty) {
      student = byId[raw.studentId];
      if (student == null) resolveError = 'Unknown student id "${raw.studentId}"';
    } else if (raw.admissionNo.isNotEmpty) {
      final matches = byAdmission[raw.admissionNo] ?? const [];
      if (matches.isEmpty) {
        resolveError = 'Unknown admission number "${raw.admissionNo}"';
      } else if (matches.length > 1) {
        resolveError = 'Admission number "${raw.admissionNo}" matches more than one pupil';
      } else {
        student = matches.first;
      }
    } else {
      resolveError = 'No student id or admission number';
    }

    if (student == null) {
      out.add(ScorePreviewRow(
        line: line, raw: raw, status: ScoreRowStatus.error,
        message: resolveError ?? 'Unknown student'));
      continue;
    }

    // Duplicate row for the same resolved student.
    if (seen.containsKey(student.id)) {
      out.add(ScorePreviewRow(
        line: line, raw: raw, status: ScoreRowStatus.error,
        resolvedStudentId: student.id, resolvedStudentName: student.fullName,
        message: 'Duplicate row (already on line ${seen[student.id]})'));
      continue;
    }
    seen[student.id] = line;

    final absent = _parseAbsent(raw.absentText);
    final scoreText = raw.scoreText.trim();

    // Absent wins over any score in the row.
    if (absent) {
      final msg = scoreText.isEmpty
          ? 'Absent'
          : 'Marked absent — the score is ignored';
      out.add(ScorePreviewRow(
        line: line, raw: raw,
        status: scoreText.isEmpty ? ScoreRowStatus.valid : ScoreRowStatus.warning,
        message: msg, resolvedStudentId: student.id,
        resolvedStudentName: student.fullName, absent: true));
      continue;
    }

    if (scoreText.isEmpty) {
      out.add(ScorePreviewRow(
        line: line, raw: raw, status: ScoreRowStatus.warning,
        resolvedStudentId: student.id, resolvedStudentName: student.fullName,
        message: 'No score — this row will be skipped'));
      continue;
    }

    final score = double.tryParse(scoreText.replaceAll(',', '.'));
    if (score == null) {
      out.add(ScorePreviewRow(
        line: line, raw: raw, status: ScoreRowStatus.error,
        resolvedStudentId: student.id, resolvedStudentName: student.fullName,
        message: '"${raw.scoreText}" is not a number'));
      continue;
    }
    if (score < 0) {
      out.add(ScorePreviewRow(
        line: line, raw: raw, status: ScoreRowStatus.error,
        resolvedStudentId: student.id, resolvedStudentName: student.fullName,
        message: 'Score cannot be negative'));
      continue;
    }
    if (score > max) {
      out.add(ScorePreviewRow(
        line: line, raw: raw, status: ScoreRowStatus.error,
        resolvedStudentId: student.id, resolvedStudentName: student.fullName,
        message: 'Score ${_num(score)} is above the maximum of ${_num(max)}'));
      continue;
    }

    out.add(ScorePreviewRow(
      line: line, raw: raw, status: ScoreRowStatus.valid,
      resolvedStudentId: student.id, resolvedStudentName: student.fullName,
      message: 'OK', score: score));
  }
  return out;
}

/// The bulk request body for the rows that will be written — valid scores and
/// absences. Error and skipped rows are left out.
List<Map<String, dynamic>> scorePayload(List<ScorePreviewRow> preview) {
  final out = <Map<String, dynamic>>[];
  for (final r in preview) {
    if (!r.willWrite) continue;
    out.add({
      'studentId': r.resolvedStudentId,
      'absent': r.absent,
      if (!r.absent) 'score': r.score,
      if (r.raw.remark.isNotEmpty) 'remark': r.raw.remark,
    });
  }
  return out;
}

/// A tally of the preview, for the confirmation sheet's summary line.
class ScorePreviewSummary {
  final int valid;
  final int warning;
  final int error;
  const ScorePreviewSummary(this.valid, this.warning, this.error);

  int get total => valid + warning + error;
  bool get hasBlockingErrors => error > 0;
}

ScorePreviewSummary summarizePreview(List<ScorePreviewRow> preview) {
  var v = 0, w = 0, e = 0;
  for (final r in preview) {
    switch (r.status) {
      case ScoreRowStatus.valid:
        v++;
      case ScoreRowStatus.warning:
        w++;
      case ScoreRowStatus.error:
        e++;
    }
  }
  return ScorePreviewSummary(v, w, e);
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

bool _parseAbsent(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'true':
    case 'yes':
    case 'y':
    case '1':
    case 'absent':
    case 'abs':
      return true;
    default:
      return false;
  }
}

/// Formats a number without a trailing `.0`, keeping halves (`7.5`).
String _num(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toString();
}

/// Quotes a field for CSV, doubling embedded quotes, and prefixes a `'` to a
/// value a spreadsheet would run as a formula (the same injection guard the Go
/// exporter uses).
String _csv(String s) {
  var value = s;
  if (value.isNotEmpty && '=+-@\t\r'.contains(value[0])) {
    value = "'$value";
  }
  if (value.contains(',') || value.contains('"') || value.contains('\n')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

/// A minimal RFC-4180 CSV reader: handles quoted fields, escaped quotes and
/// CRLF/LF line endings, returning a grid of trimmed-of-nothing cell strings.
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
        // swallow; the \n (or end) closes the row
        i++;
      case '\n':
        endRow();
        i++;
      default:
        field.write(ch);
        i++;
    }
  }
  // Flush the trailing field/row if the file didn't end with a newline.
  if (field.isNotEmpty || row.isNotEmpty) {
    endRow();
  }
  return rows;
}
