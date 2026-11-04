import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/models/assessment.dart';
import '../../../core/models/grading.dart';
import '../../../core/models/school_term.dart';
import '../../../core/models/student.dart';
import '../../../core/models/submission.dart';
import '../../../core/models/subjects.dart';

/// The score sheet (gradebook) for one class and subject in one term: students
/// as rows, assessments as columns, a weighted term total (the school's
/// class-score/exam split and grade bands) and the position in class.
///
/// Built locally from the offline store so it works without a connection; the
/// same computation runs on the server for `GET /api/reports/score-sheet`.

/// Whether an assessment type counts as an examination for the weighting — the
/// exam-type assessments (Mid-Term, End-of-Term, Mock, Diagnostic, Remedial).
/// The rest are continuous assessment. Mirrors `domain.IsExamType` in Go.
bool isExamType(AssessmentType t) =>
    t == AssessmentType.midTerm ||
    t == AssessmentType.endTerm ||
    t == AssessmentType.mock ||
    t == AssessmentType.diagnostic ||
    t == AssessmentType.remedial;

class SheetColumn {
  final Assessment assessment;
  const SheetColumn(this.assessment);

  String get id => assessment.id;
  String get title => assessment.title;
  AssessmentType get type => assessment.type;
  String get date => assessment.date;
  double get total => assessment.effectiveTotal;
  bool get isExam => isExamType(assessment.type);
}

class SheetCell {
  final String assessmentId;
  final bool present;
  final double earned;
  final double total;
  final double percent;
  final SubmissionSource? source;
  final bool absent;

  const SheetCell({
    required this.assessmentId,
    required this.present,
    required this.total,
    this.earned = 0,
    this.percent = 0,
    this.source,
    this.absent = false,
  });

  /// The short cell marker: `AI`, `Manual`, `Absent`, or empty.
  String get marker {
    if (!present) return '';
    if (absent) return 'Absent';
    return switch (source) {
      SubmissionSource.ai => 'AI',
      SubmissionSource.manual => 'Manual',
      _ => '',
    };
  }
}

class SheetRow {
  final Student student;
  final List<SheetCell> cells;
  final bool hasTotal;
  final double termTotal;
  final String grade;
  final int position; // 0 = unranked (no total)

  const SheetRow({
    required this.student,
    required this.cells,
    this.hasTotal = false,
    this.termTotal = 0,
    this.grade = '',
    this.position = 0,
  });
}

class ScoreSheet {
  final String classId;
  final String subjectId;
  final SchoolTerm term;
  final GradingScheme scheme;
  final List<SheetColumn> columns;
  final List<SheetRow> rows;

  const ScoreSheet({
    required this.classId,
    required this.subjectId,
    required this.term,
    required this.scheme,
    required this.columns,
    required this.rows,
  });

  String get subjectName => subjectNameOf(subjectId);
}

/// Resolves a subject id to its name (indirection kept so the pure module does
/// not import UI helpers directly in tests).
String subjectNameOf(String id) => subjectName(id);

/// Builds the score sheet from the class roster, its assessments and the
/// submissions. Only [subjectId] assessments in [term] are columns; an undated
/// assessment counts as the current term's when [isCurrent]. [typeFilter], when
/// set, keeps only that assessment type.
ScoreSheet buildScoreSheet({
  required String classId,
  required String subjectId,
  required List<Assessment> assessments,
  required List<Student> students,
  required List<AssessmentSubmission> subs,
  required GradingScheme scheme,
  required SchoolTerm term,
  bool isCurrent = true,
  AssessmentType? typeFilter,
}) {
  final columns = <SheetColumn>[];
  for (final a in assessments) {
    if (a.classId != classId || a.subjectId != subjectId) continue;
    if (typeFilter != null && a.type != typeFilter) continue;
    final inTerm = a.date.isEmpty ? isCurrent : term.contains(a.date);
    if (inTerm) columns.add(SheetColumn(a));
  }
  columns.sort((x, y) {
    final c = x.date.compareTo(y.date);
    return c != 0 ? c : x.id.compareTo(y.id);
  });

  AssessmentSubmission? subFor(String assessmentId, String studentId) {
    for (final s in subs) {
      if (s.assessmentId == assessmentId && s.studentId == studentId) return s;
    }
    return null;
  }

  final roster = students.where((s) => s.classId == classId).toList();
  final rows = <SheetRow>[];
  for (final st in roster) {
    final cells = <SheetCell>[];
    var classSum = 0.0, examSum = 0.0;
    var classN = 0, examN = 0;
    for (final col in columns) {
      final sub = subFor(col.id, st.id);
      if (sub == null) {
        cells.add(SheetCell(assessmentId: col.id, present: false, total: col.total));
        continue;
      }
      if (sub.absent) {
        cells.add(SheetCell(
            assessmentId: col.id,
            present: true,
            total: col.total,
            absent: true,
            source: sub.source));
        continue;
      }
      final pct = col.total > 0 ? 100 * sub.earned / col.total : 0.0;
      cells.add(SheetCell(
          assessmentId: col.id,
          present: true,
          earned: sub.earned,
          total: col.total,
          percent: pct,
          source: sub.source));
      if (col.isExam) {
        examSum += pct;
        examN++;
      } else {
        classSum += pct;
        classN++;
      }
    }
    final (total, has) = _weighted(scheme, classSum, classN, examSum, examN);
    rows.add(SheetRow(
      student: st,
      cells: cells,
      hasTotal: has,
      termTotal: has ? total : 0,
      grade: has ? scheme.bandFor(total).grade : '',
    ));
  }

  return ScoreSheet(
    classId: classId,
    subjectId: subjectId,
    term: term,
    scheme: scheme,
    columns: columns,
    rows: _withPositions(rows),
  );
}

(double, bool) _weighted(
    GradingScheme scheme, double classSum, int classN, double examSum, int examN) {
  if (classN > 0 && examN > 0) {
    final classAvg = classSum / classN;
    final examAvg = examSum / examN;
    return (
      classAvg * scheme.classWeight / 100 + examAvg * scheme.examWeight / 100,
      true
    );
  }
  if (classN > 0) return (classSum / classN, true);
  if (examN > 0) return (examSum / examN, true);
  return (0, false);
}

/// Returns the rows with [SheetRow.position] filled in — ranked by term total
/// (descending, ties share a rank); rows without a total stay position 0. The
/// row order is unchanged (still roster order).
List<SheetRow> _withPositions(List<SheetRow> rows) {
  final ranked = [
    for (var i = 0; i < rows.length; i++)
      if (rows[i].hasTotal) (i, rows[i].termTotal)
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  final pos = List<int>.filled(rows.length, 0);
  var rank = 0;
  double? prev;
  for (var n = 0; n < ranked.length; n++) {
    final (i, val) = ranked[n];
    if (prev == null || val != prev) {
      rank = n + 1;
      prev = val;
    }
    pos[i] = rank;
  }
  return [
    for (var i = 0; i < rows.length; i++)
      SheetRow(
        student: rows[i].student,
        cells: rows[i].cells,
        hasTotal: rows[i].hasTotal,
        termTotal: rows[i].termTotal,
        grade: rows[i].grade,
        position: pos[i],
      )
  ];
}

String _num(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

String _cellText(SheetCell c) {
  if (!c.present) return '';
  if (c.absent) return 'Abs';
  return _num(c.earned);
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

/// The score sheet as an `.xlsx` workbook.
Uint8List scoreSheetXlsx(ScoreSheet sheet) {
  final excel = Excel.createExcel();
  final ws = excel['Score Sheet'];
  ws.appendRow([TextCellValue('SOLVANTA — Score Sheet')]);
  ws.appendRow([
    TextCellValue('Class'),
    TextCellValue(sheet.classId),
    TextCellValue('Subject'),
    TextCellValue(sheet.subjectName),
    TextCellValue('Term'),
    TextCellValue(sheet.term.label),
  ]);
  ws.appendRow([
    TextCellValue('Grading'),
    TextCellValue(
        'Class ${_num(sheet.scheme.classWeight)}% · Exam ${_num(sheet.scheme.examWeight)}%'),
  ]);
  ws.appendRow([TextCellValue('')]);

  final header = <CellValue>[TextCellValue('Student'), TextCellValue('Admission')];
  for (final col in sheet.columns) {
    header.add(TextCellValue('${col.title} (/${_num(col.total)})'));
  }
  header.addAll([TextCellValue('Term total'), TextCellValue('Grade'), TextCellValue('Position')]);
  ws.appendRow(header);

  for (final row in sheet.rows) {
    final cells = <CellValue>[
      TextCellValue(row.student.fullName),
      TextCellValue(row.student.admissionNo),
    ];
    for (final c in row.cells) {
      cells.add(TextCellValue(_cellText(c)));
    }
    cells.addAll([
      TextCellValue(row.hasTotal ? '${_num(row.termTotal)}%' : '–'),
      TextCellValue(row.hasTotal ? row.grade : '–'),
      TextCellValue(row.position > 0 ? '${row.position}' : '–'),
    ]);
    ws.appendRow(cells);
  }
  return Uint8List.fromList(excel.encode() ?? const []);
}

/// The score sheet as a landscape PDF table.
Future<Uint8List> scoreSheetPdf(ScoreSheet sheet) {
  final doc = pw.Document();
  final headers = <String>[
    'Student',
    for (final col in sheet.columns) '${col.title}\n/${_num(col.total)}',
    'Total',
    'Grade',
    'Pos',
  ];
  // The default PDF font (Helvetica) has no glyphs for en/em dashes, so this
  // table stays ASCII: '-' as the empty placeholder, ' / ' as the separator.
  final data = <List<String>>[
    for (final row in sheet.rows)
      [
        row.student.fullName,
        for (final c in row.cells) _cellText(c),
        row.hasTotal ? '${_num(row.termTotal)}%' : '-',
        row.hasTotal ? row.grade : '-',
        row.position > 0 ? '${row.position}' : '-',
      ],
  ];
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4.landscape,
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('SOLVANTA - Score Sheet',
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          pw.Text(
              '${sheet.classId} / ${sheet.subjectName} / ${sheet.term.label} / '
              'Class ${_num(sheet.scheme.classWeight)}% - Exam ${_num(sheet.scheme.examWeight)}%',
              style: const pw.TextStyle(fontSize: 10)),
          pw.SizedBox(height: 10),
          pw.TableHelper.fromTextArray(
            headers: headers,
            data: data,
            headerStyle:
                pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellAlignment: pw.Alignment.center,
            cellAlignments: {0: pw.Alignment.centerLeft},
          ),
        ],
      ),
    ),
  );
  return doc.save();
}
