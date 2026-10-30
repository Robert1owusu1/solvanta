import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/models/assessment.dart';
import '../../core/models/grading.dart';
import '../../core/models/student.dart';
import '../../core/models/subjects.dart';
import '../../core/models/submission.dart';

/// Quotes a CSV field. Text a spreadsheet would run as a formula (`=`, `+`,
/// `-`, `@`, tab or CR first — e.g. a student named `=HYPERLINK(…)`) gets a
/// leading `'` so it opens as plain text; numbers are left alone.
String _q(String v) {
  final formula = v.length > 1 &&
      '=+-@\t\r'.contains(v[0]) &&
      double.tryParse(v) == null;
  return '"${formula ? "'" : ''}${v.replaceAll('"', '""')}"';
}

/// One assessed row in a report card: a single assessment and the student's
/// outcome (or an unmarked placeholder).
class ReportCardRow {
  final String subjectId;
  final String title;
  final String date;
  final double total;
  final double? earned; // null → pending

  /// What kind of work this was — the terminal report splits class work from
  /// the end-of-term examination.
  final AssessmentType type;

  /// The assessment's class — whose grading scheme grades this row.
  final String classId;

  const ReportCardRow({
    required this.subjectId,
    required this.title,
    required this.date,
    required this.total,
    this.earned,
    this.type = AssessmentType.exercise,
    this.classId = '',
  });

  double? get pct => total > 0 && earned != null ? 100 * earned! / total : null;

  String get grade => pct == null ? '–' : schoolGrade(pct!, classId);

  String get marksLabel => earned == null ? '–' : earned!.toStringAsFixed(1);
}

/// Section 30: CSV/PDF/Excel export of class results and term report cards
/// (doc §39).
class ReportingService {
  String classResultsCsv({
    required Assessment assessment,
    required List<Student> roster,
    required List<AssessmentSubmission> subs,
  }) {
    final buf = StringBuffer();
    buf.writeln('Assessment,${_q(assessment.title)}');
    buf.writeln(
        'Subject,${_q(assessment.subjectId)} · Total marks,'
        '${assessment.totalMarks.toStringAsFixed(2)}');
    buf.writeln(
        'Student ID,Name,Class,Total,Earned,Percent,Grade');
    var earned = 0.0, possible = 0.0;
    for (final s in roster) {
      final sub = subs.firstWhere(
        (x) =>
            x.assessmentId == assessment.id && x.studentId == s.id,
        orElse: () => AssessmentSubmission(
          id: '',
          assessmentId: assessment.id,
          studentId: s.id,
          classId: s.classId,
          date: '',
          answers: const {},
          teacherMarks: const {},
          earned: 0,
        ),
      );
      final pct = assessment.totalMarks > 0
          ? 100 * sub.earned / assessment.totalMarks
          : 0.0;
      final marked = sub.id.isNotEmpty;
      earned += sub.earned;
      possible += assessment.totalMarks;
      buf.writeln([
        _q(s.id),
        _q(s.fullName),
        _q(s.classId),
        _q(assessment.totalMarks.toStringAsFixed(2)),
        marked ? _q(sub.earned.toStringAsFixed(1)) : _q('pending'),
        marked ? _q('${pct.toStringAsFixed(1)}%') : _q('–'),
        marked ? _q(schoolGrade(pct, assessment.classId)) : _q('–'),
      ].join(','));
    }
    buf.writeln(
        'Class average,'
        '${possible > 0 ? '${(100 * earned / possible).toStringAsFixed(1)}%' : '–'}');
    return buf.toString();
  }

  String studentReportCsv({
    required Student student,
    required List<Assessment> assessments,
    required List<AssessmentSubmission> subs,
  }) {
    final buf = StringBuffer();
    buf.writeln('SOLVANTA — Student Report Card');
    buf.writeln(
        'Student,${_q('${student.fullName} (${student.classId}, ${student.id})')}');
    buf.writeln('Generated,SOLVANTA offline report');
    buf.writeln('Subject,Assessment,Date,Total,Marks,Percent,Grade');
    for (final r in rowsFor(
        student: student, assessments: assessments, subs: subs)) {
      buf.writeln([
        _q(r.subjectId),
        _q(r.title),
        _q(r.date),
        _q(r.total.toStringAsFixed(2)),
        _q(r.marksLabel),
        _q(r.pct == null ? '–' : '${r.pct!.toStringAsFixed(1)}%'),
        _q(r.grade),
      ].join(','));
    }
    return buf.toString();
  }

  /// All assessments for the student's class ([classId] when given — e.g.
  /// the class they were in last year), each paired with their outcome.
  List<ReportCardRow> rowsFor({
    required Student student,
    required List<Assessment> assessments,
    required List<AssessmentSubmission> subs,
    String? classId,
  }) {
    final rows = <ReportCardRow>[];
    for (final a in assessments) {
      if (a.classId != (classId ?? student.classId)) continue;
      final sub = subs.firstWhere(
        (x) => x.assessmentId == a.id && x.studentId == student.id,
        orElse: () => AssessmentSubmission.empty,
      );
      rows.add(ReportCardRow(
        subjectId: a.subjectId,
        title: a.title,
        date: a.date,
        total: a.totalMarks,
        earned: sub.id.isNotEmpty ? sub.earned : null,
        type: a.type,
        classId: a.classId,
      ));
    }
    return rows;
  }

  /// Per-subject aggregates for the report-card summary table.
  List<SubjectSummary> subjectsFor({
    required List<ReportCardRow> rows,
  }) {
    final bySubject = <String, List<ReportCardRow>>{};
    for (final r in rows) {
      bySubject.putIfAbsent(r.subjectId, () => []).add(r);
    }
    final out = <SubjectSummary>[];
    for (final e in bySubject.entries) {
      final marked = e.value.where((r) => r.pct != null).toList();
      final avg = marked.isEmpty
          ? null
          : marked.map((r) => r.pct!).reduce((a, b) => a + b) / marked.length;
      out.add(SubjectSummary(
        subjectId: e.key,
        attempts: marked.length,
        of: e.value.length,
        average: avg,
      ));
    }
    return out;
  }

  /// Overall average across every marked assessment.
  double? overallFor({required List<ReportCardRow> rows}) {
    final marked = rows.where((r) => r.pct != null).toList();
    if (marked.isEmpty) return null;
    return marked.map((r) => r.pct!).reduce((a, b) => a + b) / marked.length;
  }

  /// Excel workbook for a single assessment's class results.
  Uint8List classResultsXlsx({
    required Assessment assessment,
    required List<Student> roster,
    required List<AssessmentSubmission> subs,
  }) {
    final excel = Excel.createExcel();
    final sheet = excel['Class Results'];
    sheet.appendRow([TextCellValue('SOLVANTA — Class Results')]);
    sheet.appendRow([TextCellValue('Assessment'), TextCellValue(assessment.title)]);
    sheet.appendRow([
      TextCellValue('Subject'),
      TextCellValue(subjectName(assessment.subjectId)),
    ]);
    sheet.appendRow([
      TextCellValue('Student ID'),
      TextCellValue('Name'),
      TextCellValue('Class'),
      TextCellValue('Total'),
      TextCellValue('Marks'),
      TextCellValue('Percent'),
      TextCellValue('Grade'),
    ]);
    var earned = 0.0, possible = 0.0;
    for (final s in roster) {
      final sub = subs.firstWhere(
        (x) =>
            x.assessmentId == assessment.id && x.studentId == s.id,
        orElse: () => AssessmentSubmission(
          id: '',
          assessmentId: assessment.id,
          studentId: s.id,
          classId: s.classId,
          date: '',
          answers: const {},
          teacherMarks: const {},
          earned: 0,
        ),
      );
      final marked = sub.id.isNotEmpty;
      final pct = assessment.totalMarks > 0
          ? 100 * sub.earned / assessment.totalMarks
          : 0.0;
      earned += sub.earned;
      possible += assessment.totalMarks;
      sheet.appendRow([
        TextCellValue(s.id),
        TextCellValue(s.fullName),
        TextCellValue(s.classId),
        TextCellValue(assessment.totalMarks.toStringAsFixed(1)),
        TextCellValue(marked ? sub.earned.toStringAsFixed(1) : 'pending'),
        TextCellValue(marked ? '${pct.toStringAsFixed(1)}%' : '–'),
        TextCellValue(marked ? schoolGrade(pct, assessment.classId) : '–'),
      ]);
    }
    sheet.appendRow([
      TextCellValue('Class average'),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(
          possible > 0 ? '${(100 * earned / possible).toStringAsFixed(1)}%' : '–'),
      TextCellValue(''),
    ]);
    return Uint8List.fromList(excel.encode() ?? const []);
  }

  /// Excel workbook for a student's term report card (doc §39).
  Uint8List reportCardXlsx({
    required Student student,
    required String termLabel,
    required List<Assessment> assessments,
    required List<AssessmentSubmission> subs,
    ({int total, int present})? attendance,
  }) {
    final rows = rowsFor(
        student: student, assessments: assessments, subs: subs);
    final excel = Excel.createExcel();
    final sheet = excel['Report Card'];
    sheet.appendRow([TextCellValue('SOLVANTA — Term Report Card')]);
    sheet.appendRow([TextCellValue('Student'), TextCellValue(student.fullName)]);
    sheet.appendRow([TextCellValue('Class'), TextCellValue(student.classId)]);
    sheet.appendRow([TextCellValue('Term'), TextCellValue(termLabel)]);
    if (attendance != null) {
      sheet.appendRow([
        TextCellValue('Attendance'),
        TextCellValue('${attendance.present}/${attendance.total} days present'),
      ]);
    }
    sheet.appendRow([]);
    sheet.appendRow([
      TextCellValue('Subject'),
      TextCellValue('Assessment'),
      TextCellValue('Date'),
      TextCellValue('Total'),
      TextCellValue('Marks'),
      TextCellValue('Percent'),
      TextCellValue('Grade'),
    ]);
    for (final r in rows) {
      sheet.appendRow([
        TextCellValue(subjectName(r.subjectId)),
        TextCellValue(r.title),
        TextCellValue(r.date),
        TextCellValue(r.total.toStringAsFixed(1)),
        TextCellValue(r.marksLabel),
        TextCellValue(r.pct == null ? '–' : '${r.pct!.toStringAsFixed(1)}%'),
        TextCellValue(r.grade),
      ]);
    }
    sheet.appendRow([]);
    sheet.appendRow([
      TextCellValue('Subject'),
      TextCellValue('Marked'),
      TextCellValue('Average'),
      TextCellValue('Grade'),
    ]);
    for (final s in subjectsFor(rows: rows)) {
      sheet.appendRow([
        TextCellValue(subjectName(s.subjectId)),
        TextCellValue('${s.attempts}/${s.of}'),
        TextCellValue(s.average == null ? '–' : '${s.average!.toStringAsFixed(1)}%'),
        TextCellValue(s.average == null
            ? '–'
            : schoolGrade(s.average!, student.classId)),
      ]);
    }
    final overall = overallFor(rows: rows);
    sheet.appendRow([
      TextCellValue('Overall'),
      TextCellValue(''),
      TextCellValue(overall == null ? '–' : '${overall.toStringAsFixed(1)}%'),
      TextCellValue(overall == null ? '–' : schoolGrade(overall, student.classId)),
    ]);
    return Uint8List.fromList(excel.encode() ?? const []);
  }

  /// PDF document for a student's term report card (doc §39).
  Future<Uint8List> reportCardPdf({
    required Student student,
    required String termLabel,
    required List<Assessment> assessments,
    required List<AssessmentSubmission> subs,
    ({int total, int present})? attendance,
  }) async {
    final rows = rowsFor(
        student: student, assessments: assessments, subs: subs);
    final doc = pw.Document();

    pw.Widget header(String text, String value) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 1),
          child: pw.Row(
            children: [
              pw.SizedBox(
                  width: 110,
                  child: pw.Text(text,
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
              pw.Expanded(child: pw.Text(value)),
            ],
          ),
        );

    final tableWidget = pw.TableHelper.fromTextArray(
      headers: [
        'Subject', 'Assessment', 'Date', 'Total', 'Marks', '%', 'Grade',
      ],
      data: [
        for (final r in rows)
          [
            subjectName(r.subjectId),
            r.title,
            r.date,
            r.total.toStringAsFixed(1),
            r.marksLabel,
            r.pct == null ? '–' : '${r.pct!.toStringAsFixed(1)}%',
            r.grade,
          ],
      ],
      headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8),
      cellStyle: const pw.TextStyle(fontSize: 8),
      cellAlignments: {
        0: pw.Alignment.centerLeft,
        1: pw.Alignment.centerLeft,
        2: pw.Alignment.centerLeft,
        3: pw.Alignment.centerRight,
        4: pw.Alignment.centerRight,
        5: pw.Alignment.centerRight,
        6: pw.Alignment.centerRight,
      },
    );

    final summary = subjectsFor(rows: rows);
    final overall = overallFor(rows: rows);
    final summaryWidget = pw.TableHelper.fromTextArray(
      headers: ['Subject', 'Marked', 'Average', 'Grade'],
      data: [
        for (final s in summary)
          [
            subjectName(s.subjectId),
            '${s.attempts}/${s.of}',
            s.average == null ? '–' : '${s.average!.toStringAsFixed(1)}%',
            s.average == null ? '–' : schoolGrade(s.average!, student.classId),
          ],
        [
          'Overall',
          '',
          overall == null ? '–' : '${overall.toStringAsFixed(1)}%',
          overall == null ? '–' : schoolGrade(overall, student.classId),
        ],
      ],
      headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8),
      cellStyle: const pw.TextStyle(fontSize: 8),
    );

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (context) => pw.Padding(
          padding: const pw.EdgeInsets.all(24),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('SOLVANTA',
                  style: pw.TextStyle(
                      fontSize: 16, fontWeight: pw.FontWeight.bold)),
              pw.Text('Term Report Card — $termLabel',
                  style: pw.TextStyle(fontSize: 14)),
              pw.SizedBox(height: 8),
              header('Student', student.fullName),
              header('Class', student.classId),
              header('ADM No.', student.admissionNo),
              if (attendance != null)
                header('Attendance',
                    '${attendance.present}/${attendance.total} days present'),
              pw.SizedBox(height: 12),
              tableWidget,
              pw.SizedBox(height: 14),
              pw.Text('Subject summary',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 4),
              summaryWidget,
              pw.SizedBox(height: 18),
              pw.Text(
                'Generated by SOLVANTA · '
                '${DateTime.now().year}-${DateTime.now().month}-${DateTime.now().day}',
                style: pw.TextStyle(fontSize: 7, color: PdfColors.grey600),
              ),
            ],
          ),
        ),
      ),
    );
    return doc.save();
  }

  /// Whole-school per-student summary (term overview for leadership, §39).
  Uint8List schoolSummaryXlsx({
    required List<Student> students,
    required List<Assessment> assessments,
    required List<AssessmentSubmission> subs,
    required String termLabel,
  }) {
    final excel = Excel.createExcel();
    final sheet = excel['School Summary'];
    sheet.appendRow([TextCellValue('SOLVANTA — School Summary · $termLabel')]);
    sheet.appendRow([
      TextCellValue('Student'),
      TextCellValue('Class'),
      TextCellValue('Marked'),
      TextCellValue('Average'),
      TextCellValue('Grade'),
    ]);
    for (final s in students) {
      final rows =
          rowsFor(student: s, assessments: assessments, subs: subs);
      final overall = overallFor(rows: rows);
      sheet.appendRow([
        TextCellValue(s.fullName),
        TextCellValue(s.classId),
        TextCellValue(
            '${rows.where((r) => r.pct != null).length}/${rows.length}'),
        TextCellValue(overall == null ? '–' : '${overall.toStringAsFixed(1)}%'),
        TextCellValue(overall == null ? '–' : schoolGrade(overall, s.classId)),
      ]);
    }
    return Uint8List.fromList(excel.encode() ?? const []);
  }
}

/// Per-subject aggregation for a report card summary table.
class SubjectSummary {
  final String subjectId;
  final int attempts;
  final int of;
  final double? average;

  const SubjectSummary({
    required this.subjectId,
    required this.attempts,
    required this.of,
    required this.average,
  });
}