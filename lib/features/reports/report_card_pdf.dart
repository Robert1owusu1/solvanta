import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/models/assessment.dart';
import '../../core/models/school.dart';
import '../../core/models/school_term.dart';
import '../../core/models/student.dart';
import '../../core/models/submission.dart';
import '../../core/models/subjects.dart';
import '../../core/theme/app_theme.dart';
import '../analytics/analytics_service.dart';
import 'reporting_service.dart';

// ---------------------------------------------------------------------------
// Template identity
// ---------------------------------------------------------------------------

/// The three print-ready report-card layouts shipped with SOLVANTA.
///
/// Every template renders exactly the same [ReportCardData], so the picker can
/// swap layouts (and the live preview) without touching the data layer.
enum ReportCardTemplate {
  /// Traditional: full-bleed navy masthead, gold hairline, ruled marks table.
  classic('Classic'),

  /// Airy: white masthead, navy rules, per-subject bars, oversized overall.
  modern('Modern'),

  /// Longitudinal: per-term summary table above the current term's subjects.
  transcript('Transcript');

  const ReportCardTemplate(this.label);

  /// Picker label shown under the preview and on the chips.
  final String label;
}

// ---------------------------------------------------------------------------
// Shared data model — what all three templates agree to render
// ---------------------------------------------------------------------------

/// One subject's aggregated result on a report card.
class SubjectResult {
  const SubjectResult({
    required this.subjectId,
    required this.name,
    required this.average,
    required this.grade,
    required this.marked,
    required this.of,
  });

  /// Curriculum code (`MATH`, `ENG`, …).
  final String subjectId;

  /// Display name for [subjectId] (`Mathematics`).
  final String name;

  /// Mean percentage across marked work, or `null` when nothing is marked.
  final double? average;

  /// Letter grade for [average] (`A`–`E`), or `–` when unmarked.
  final String grade;

  /// How many of the [of] assessments carry a mark.
  final int marked;
  final int of;

  /// Print-safe label for [average] — `78.5%`, or `–` when unmarked.
  String get averageLabel =>
      average == null ? '–' : '${average!.toStringAsFixed(1)}%';
}

/// Attendance for the term, in school days.
class ReportAttendance {
  const ReportAttendance({required this.daysTotal, required this.daysPresent});

  /// Days recorded for the student (present, late, absent, excused).
  final int daysTotal;

  /// Days counted as present (present + late), matching the exports.
  final int daysPresent;

  /// `58/60 days present`, or `–` when there is no attendance to show.
  String get label => daysTotal == 0
      ? '–'
      : '$daysPresent/$daysTotal days present';

  /// Percentage of days present, or `null` when nothing is recorded.
  double? get rate =>
      daysTotal == 0 ? null : 100 * daysPresent / daysTotal;
}

/// One term's headline result — the rows of the transcript summary table.
class TermRecord {
  const TermRecord({
    required this.termLabel,
    required this.overall,
    required this.grade,
    required this.rank,
    required this.classSize,
  });

  /// `Term 1 · 2026/2027`.
  final String termLabel;

  /// Overall average for the term, or `null` when nothing was marked.
  final double? overall;

  /// Letter grade for [overall].
  final String grade;

  /// Class position for the term, or `null` when unranked.
  final int? rank;

  /// How many classmates were ranked that term.
  final int classSize;
}

/// The single source of truth every report-card template renders.
///
/// Built once by [ReportCardDataBuilder.build] and handed to both the on-screen
/// preview and [buildReportCardPdf], so the preview and the printed page can
/// never disagree.
class ReportCardData {
  const ReportCardData({
    required this.studentName,
    required this.studentId,
    required this.admissionNo,
    required this.classId,
    required this.schoolName,
    required this.schoolMotto,
    required this.schoolContact,
    required this.termLabel,
    required this.subjects,
    required this.overall,
    required this.overallGrade,
    required this.rank,
    required this.classSize,
    required this.attendance,
    required this.remark,
    required this.teacherName,
    required this.history,
    required this.generatedAt,
  });

  final String studentName;
  final String studentId;
  final String admissionNo;
  final String classId;
  final String schoolName;
  final String schoolMotto;
  final String schoolContact;
  final String termLabel;

  /// Per-subject rows, sorted by name.
  final List<SubjectResult> subjects;

  /// Mean across every marked assessment, or `null` when nothing is marked.
  final double? overall;
  final String overallGrade;

  /// Class position, or `null` when the student could not be ranked.
  final int? rank;
  final int classSize;

  final ReportAttendance? attendance;

  /// Neutral, text-only class teacher's remark (never colour-coded).
  final String remark;

  /// Class teacher's name for the signature block (may be empty).
  final String teacherName;

  /// Prior terms — the transcript template's summary table. Model-ready for
  /// multi-term history; today it carries the current term only.
  final List<TermRecord> history;

  /// When this card was built, printed in the footer.
  final DateTime generatedAt;

  /// `2 of 6`, or `–` when unranked.
  String get rankLabel =>
      rank == null || classSize == 0 ? '–' : '$rank of $classSize';

  /// `86.0%`, or `–` when nothing is marked.
  String get overallLabel => overall == null
      ? '–'
      : '${overall!.toStringAsFixed(1)}%';
}

// ---------------------------------------------------------------------------
// Builder
// ---------------------------------------------------------------------------

/// Turns raw assessment data into [ReportCardData] — the aggregates, the class
/// rank and the teacher's remark live here so all three templates share them.
class ReportCardDataBuilder {
  const ReportCardDataBuilder._();

  /// Builds the report card for [student].
  ///
  /// [roster] is used to walk the class and compute [ReportCardData.rank];
  /// [attendance] is optional so a card still renders with no roll data.
  static ReportCardData build({
    required Student student,
    required School school,
    required SchoolTerm term,
    required List<Assessment> assessments,
    required List<AssessmentSubmission> subs,
    required List<Student> roster,
    String teacherName = '',
    ({int total, int present})? attendance,
  }) {
    final svc = ReportingService();
    final rows = svc.rowsFor(
        student: student, assessments: assessments, subs: subs);
    final summaries = svc.subjectsFor(rows: rows);
    final overall = svc.overallFor(rows: rows);

    final subjects = [
      for (final s in summaries)
        SubjectResult(
          subjectId: s.subjectId,
          name: subjectName(s.subjectId),
          average: s.average,
          grade: s.average == null ? '–' : gradeLetter(s.average!),
          marked: s.attempts,
          of: s.of,
        ),
    ]..sort((a, b) => a.name.compareTo(b.name));

    // Rank: count classmates that finished ahead of this student.
    var ahead = 0;
    var ranked = 0;
    for (final mate in roster.where((s) => s.classId == student.classId)) {
      final mateRows = svc.rowsFor(
          student: mate, assessments: assessments, subs: subs);
      final mateOverall = svc.overallFor(rows: mateRows);
      if (mateOverall == null) continue;
      ranked++;
      if (overall != null && mateOverall > overall) ahead++;
    }
    final rank = overall == null ? null : ahead + 1;

    final att = attendance == null || attendance.total == 0
        ? null
        : ReportAttendance(
            daysTotal: attendance.total,
            daysPresent: attendance.present,
          );

    final remark =
        _remarkFor(student.firstName, overall, rank, ranked, subjects);

    return ReportCardData(
      studentName: student.fullName,
      studentId: student.id,
      admissionNo: student.admissionNo,
      classId: student.classId,
      schoolName: school.name,
      schoolMotto: school.motto,
      schoolContact: [school.address, school.phone]
          .where((x) => x.trim().isNotEmpty)
          .join(' · '),
      termLabel: term.label,
      subjects: subjects,
      overall: overall,
      overallGrade: overall == null ? '–' : gradeLetter(overall),
      rank: rank,
      classSize: ranked,
      attendance: att,
      remark: remark,
      teacherName: teacherName,
      history: [
        TermRecord(
          termLabel: term.label,
          overall: overall,
          grade: overall == null ? '–' : gradeLetter(overall),
          rank: rank,
          classSize: ranked,
        ),
      ],
      generatedAt: DateTime.now(),
    );
  }

  /// A neutral remark built from the numbers — strengths and position only,
  /// never green/red verdicts (grades stay black on white in print).
  static String _remarkFor(String firstName, double? overall, int? rank,
      int classSize, List<SubjectResult> subjects) {
    if (overall == null) {
      return 'No marks have been recorded for $firstName this term yet. '
          'The report will be completed once assessments are marked.';
    }
    final effort = overall >= 75
        ? 'a strong, consistent effort'
        : overall >= 55
            ? 'a steady effort with clear room to build on'
            : 'an honest effort; further practice will build confidence';
    final ranked = subjects.where((s) => s.average != null).toList()
      ..sort((a, b) => (b.average ?? 0).compareTo(a.average ?? 0));
    final strength = ranked.isEmpty
        ? ''
        : ' ${ranked.first.name} is the strongest area '
            '(${ranked.first.averageLabel}).';
    final place =
        rank == null || classSize == 0 ? '' : ' Ranked $rank of $classSize.';
    return '$firstName has shown $effort this term, averaging '
        '${overall.toStringAsFixed(1)}% (${gradeLetter(overall)}).'
        '$strength$place';
  }
}

// ---------------------------------------------------------------------------
// PDF palette — derived from the const brand tokens (never raw hex).
// Printed pages are always white, so the light palette is the correct choice
// regardless of the app's current brightness.
// ---------------------------------------------------------------------------

final PdfColor _navy = PdfColor.fromInt(AppTheme.brand.toARGB32());
final PdfColor _navyLight = PdfColor.fromInt(AppTheme.brandLight.toARGB32());
final PdfColor _navy100 = PdfColor.fromInt(AppTheme.navy100.toARGB32());
final PdfColor _navy50 = PdfColor.fromInt(AppTheme.navy50.toARGB32());
final PdfColor _gold = PdfColor.fromInt(AppTheme.gold.toARGB32());
final PdfColor _paper = PdfColor.fromInt(AppPalette.light.surface.toARGB32());
final PdfColor _ink = PdfColor.fromInt(AppPalette.light.ink.toARGB32());
final PdfColor _muted = PdfColor.fromInt(AppPalette.light.body.toARGB32());
final PdfColor _hair = PdfColor.fromInt(AppPalette.light.border.toARGB32());

// Text styles are runtime `final`s rather than `const`: pdf's `TextStyle`
// const-ctor evaluates its initializer list at compile time, and the analyzer
// rejects `const` for every style that passes `fontWeight: FontWeight.bold`.
// They are also referenced only from runtime widget arguments.
final pw.TextStyle _tHeader =
    pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white);
final pw.TextStyle _tCell =
    pw.TextStyle(fontSize: 8, color: PdfColors.black);
final pw.TextStyle _kvValue =
    pw.TextStyle(fontSize: 8.5, color: PdfColors.black);
final pw.TextStyle _statValue =
    pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: PdfColors.black);
final pw.TextStyle _grade =
    pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold, color: PdfColors.black);
final pw.TextStyle _score =
    pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: PdfColors.black);
final pw.TextStyle _mastheadSmall =
    pw.TextStyle(fontSize: 7.5, letterSpacing: 2.4, color: PdfColors.white);
final pw.TextStyle _mastheadTitle =
    pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold, color: PdfColors.white);
final pw.TextStyle _signature =
    pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: PdfColors.black);
final pw.TextStyle _kicker =
    pw.TextStyle(fontSize: 9, letterSpacing: 1.6, fontWeight: pw.FontWeight.bold, color: PdfColors.black);

final pw.TextStyle _kvLabel =
    pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: _ink);
final pw.TextStyle _section =
    pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _navy);
final pw.TextStyle _mastheadSub = pw.TextStyle(fontSize: 8, color: _navy100);
final pw.TextStyle _body = pw.TextStyle(fontSize: 8.5, color: PdfColors.black);
final pw.TextStyle _mutedText = pw.TextStyle(fontSize: 7.5, color: _muted);
final pw.TextStyle _statLabel =
    pw.TextStyle(fontSize: 6.5, letterSpacing: 0.8, color: _muted);
final pw.TextStyle _modernSchool =
    pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: _navy);
final pw.TextStyle _modernName =
    pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold, color: _ink);
final pw.TextStyle _subjectName = pw.TextStyle(fontSize: 9, color: _ink);
final pw.TextStyle _navyTitle = pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: _navyLight);

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Renders [data] as a single-page A4 PDF in [template] and returns its bytes.
///
/// Pure Dart — no build context — so the caller can write the bytes to a file
/// and hand them to the share sheet.
Future<Uint8List> buildReportCardPdf(
  ReportCardData data,
  ReportCardTemplate template,
) async {
  final doc = pw.Document();
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: pw.EdgeInsets.zero,
      build: (context) => switch (template) {
        ReportCardTemplate.classic => _classicPage(data),
        ReportCardTemplate.modern => _modernPage(data),
        ReportCardTemplate.transcript => _transcriptPage(data),
      },
    ),
  );
  return doc.save();
}

// ---------------------------------------------------------------------------
// Shared building blocks
// ---------------------------------------------------------------------------

/// Label/value row used by the Classic and Transcript headers.
pw.Widget _kv(String label, String value) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(width: 84, child: pw.Text(label, style: _kvLabel)),
          pw.Expanded(child: pw.Text(value, style: _kvValue)),
        ],
      ),
    );

/// Section heading (`Subjects`, `Term record`, …).
pw.Widget _title(String text) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 12, bottom: 5),
      child: pw.Text(text, style: _section),
    );

/// Compact statistic tile (Class / Rank / Attendance).
pw.Widget _stat(String label, String value) => pw.Expanded(
      child: pw.Container(
        margin: const pw.EdgeInsets.only(right: 6),
        padding: const pw.EdgeInsets.all(6),
        decoration: pw.BoxDecoration(
          color: _navy50,
          border: pw.Border.all(color: _navy100, width: 0.6),
          borderRadius: pw.BorderRadius.circular(4),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(label.toUpperCase(), style: _statLabel),
            pw.SizedBox(height: 2),
            pw.Text(value, style: _statValue),
          ],
        ),
      ),
    );

/// Marks table: navy header, **pure black** marks on white, hairline grid.
pw.Widget _marksTable(List<SubjectResult> subjects) => pw.TableHelper.fromTextArray(
      headers: const ['Subject', 'Marked', 'Average', 'Grade'],
      data: [
        for (final s in subjects)
          [s.name, '${s.marked}/${s.of}', s.averageLabel, s.grade],
      ],
      headerStyle: _tHeader,
      cellStyle: _tCell,
      headerDecoration: pw.BoxDecoration(color: _navy),
      headerAlignment: pw.Alignment.centerLeft,
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      headerPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      headerAlignments: const {
        0: pw.Alignment.centerLeft,
        1: pw.Alignment.centerRight,
        2: pw.Alignment.centerRight,
        3: pw.Alignment.centerRight,
      },
      cellAlignments: const {
        0: pw.Alignment.centerLeft,
        1: pw.Alignment.centerRight,
        2: pw.Alignment.centerRight,
        3: pw.Alignment.centerRight,
      },
      columnWidths: const {
        0: pw.FlexColumnWidth(3),
        1: pw.FlexColumnWidth(1.1),
        2: pw.FlexColumnWidth(1.4),
        3: pw.FlexColumnWidth(1),
      },
      border: pw.TableBorder(
        left: pw.BorderSide(color: _hair, width: 0.5),
        right: pw.BorderSide(color: _hair, width: 0.5),
        top: pw.BorderSide(color: _hair, width: 0.5),
        bottom: pw.BorderSide(color: _hair, width: 0.5),
        horizontalInside: pw.BorderSide(color: _hair, width: 0.5),
        verticalInside: pw.BorderSide(color: _hair, width: 0.5),
      ),
    );

/// Teacher's remark in a hairline box.
pw.Widget _remark(ReportCardData d) => pw.Container(
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _navy100, width: 0.8),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text("Class teacher's remark", style: _kvLabel),
          pw.SizedBox(height: 3),
          pw.Text(d.remark, style: _body),
        ],
      ),
    );

/// Two ruled signature lines.
pw.Widget _signatures(
  ReportCardData d, {
  String rightLabel = 'Head teacher',
}) =>
    pw.Row(
      children: [
        pw.Expanded(child: _signatureLine('Class teacher', d.teacherName)),
        pw.SizedBox(width: 24),
        pw.Expanded(child: _signatureLine(rightLabel, '')),
      ],
    );

pw.Widget _signatureLine(String label, String name) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(height: 22),
        pw.Text(name.isEmpty ? ' ' : name, style: _signature),
        pw.Container(height: 0.6, color: _hair),
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 2),
          child: pw.Text(label, style: _mutedText),
        ),
      ],
    );

/// Footer line, always centred.
pw.Widget _footer(ReportCardData d) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 12),
      child: pw.Text(
        'Generated by SOLVANTA · ${_iso(d.generatedAt)} · ${d.schoolName}',
        textAlign: pw.TextAlign.center,
        style: _mutedText,
      ),
    );

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

// ---------------------------------------------------------------------------
// Template 1 — Classic
// ---------------------------------------------------------------------------

pw.Widget _classicPage(ReportCardData d) => pw.Container(
      color: _paper,
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          // Full-bleed navy masthead with the school crest line.
          pw.Container(
            color: _navy,
            padding: const pw.EdgeInsets.fromLTRB(30, 22, 30, 16),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('SOLVANTA', style: _mastheadSmall),
                      pw.SizedBox(height: 3),
                      pw.Text(d.schoolName, style: _mastheadTitle),
                      if (d.schoolMotto.isNotEmpty)
                        pw.Text(d.schoolMotto, style: _mastheadSub),
                    ],
                  ),
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text('REPORT CARD', style: _mastheadSmall),
                    pw.SizedBox(height: 3),
                    pw.Text(d.termLabel, style: _mastheadSub),
                  ],
                ),
              ],
            ),
          ),
          pw.Container(height: 3, color: _gold),
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(30, 16, 30, 0),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _kv('Student', d.studentName),
                _kv('Adm. No.', d.admissionNo),
                _kv('Class', d.classId),
                _kv('Term', d.termLabel),
                if (d.attendance != null)
                  _kv('Attendance', d.attendance!.label),
                pw.SizedBox(height: 10),
                pw.Row(
                  children: [
                    _stat('Overall', d.overallLabel),
                    _stat('Grade', d.overallGrade),
                    _stat('Class position', d.rankLabel),
                  ],
                ),
                _title('Subjects'),
                _marksTable(d.subjects),
                pw.SizedBox(height: 12),
                _remark(d),
                pw.SizedBox(height: 6),
                _signatures(d),
                _footer(d),
              ],
            ),
          ),
        ],
      ),
    );

// ---------------------------------------------------------------------------
// Template 2 — Modern
// ---------------------------------------------------------------------------

pw.Widget _modernPage(ReportCardData d) => pw.Container(
      color: _paper,
      padding: const pw.EdgeInsets.fromLTRB(34, 30, 34, 26),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(d.schoolName, style: _modernSchool),
                    pw.Text(d.schoolMotto, style: _mutedText),
                  ],
                ),
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text('REPORT CARD', style: _kicker),
                  pw.Text(d.termLabel, style: _mutedText),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Container(height: 2, color: _navy),
          pw.SizedBox(height: 2),
          pw.Container(height: 0.8, color: _navyLight),
          pw.SizedBox(height: 16),
          pw.Text(d.studentName, style: _modernName),
          pw.SizedBox(height: 2),
          pw.Text('${d.classId} · ${d.admissionNo}', style: _mutedText),
          pw.SizedBox(height: 12),
          pw.Row(
            children: [
              _stat('Class', d.classId),
              _stat('Position', d.rankLabel),
              _stat('Attendance', d.attendance?.label ?? '–'),
            ],
          ),
          _title('Subjects'),
          for (final s in d.subjects) _modernSubjectRow(s),
          pw.SizedBox(height: 6),
          pw.Divider(thickness: 0.6, color: _hair),
          pw.SizedBox(height: 6),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('OVERALL', style: _statLabel),
                    pw.SizedBox(height: 2),
                    pw.Text("Class teacher's remark", style: _kvLabel),
                  ],
                ),
              ),
              pw.Text(d.overallLabel, style: _score),
              pw.SizedBox(width: 6),
              pw.SizedBox(
                width: 18,
                child: pw.Text(d.overallGrade,
                    textAlign: pw.TextAlign.right, style: _grade),
              ),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Text(d.remark, style: _body),
          pw.SizedBox(height: 4),
          pw.Text(
            d.teacherName.isEmpty ? 'Class teacher' : 'Class teacher · ${d.teacherName}',
            style: _mutedText,
          ),
          _footer(d),
        ],
      ),
    );

/// One modern subject row: name, navy progress bar, average and grade.
pw.Widget _modernSubjectRow(SubjectResult s) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.Row(
        children: [
          pw.Expanded(child: pw.Text(s.name, style: _subjectName)),
          _bar(s.average),
          pw.SizedBox(width: 8),
          pw.SizedBox(
            width: 46,
            child: pw.Text(s.averageLabel,
                textAlign: pw.TextAlign.right, style: _kvValue),
          ),
          pw.SizedBox(width: 6),
          pw.SizedBox(
            width: 18,
            child: pw.Text(s.grade,
                textAlign: pw.TextAlign.right, style: _grade),
          ),
        ],
      ),
    );

/// Navy-only bar (one navy ramp — never traffic lights).
pw.Widget _bar(double? average) {
  final filled =
      average == null ? 0.0 : average.clamp(0, 100).toDouble() / 100 * 92;
  return pw.Container(
    width: 92,
    height: 6,
    color: _navy100,
    child: pw.Align(
      alignment: pw.Alignment.centerLeft,
      child: pw.Container(width: filled, height: 6, color: _navy),
    ),
  );
}

// ---------------------------------------------------------------------------
// Template 3 — Transcript
// ---------------------------------------------------------------------------

pw.Widget _transcriptPage(ReportCardData d) => pw.Container(
      color: _paper,
      padding: const pw.EdgeInsets.fromLTRB(34, 30, 34, 26),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(d.schoolName, style: _modernSchool),
                    pw.Text(d.schoolMotto, style: _mutedText),
                  ],
                ),
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text('TRANSCRIPT', style: _kicker),
                  pw.Text(d.termLabel, style: _mutedText),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Container(height: 2, color: _navy),
          pw.SizedBox(height: 4),
          pw.Text(d.studentName, style: _navyTitle),
          pw.SizedBox(height: 6),
          _kv('Adm. No.', d.admissionNo),
          _kv('Class', d.classId),
          _kv('Term', d.termLabel),
          _title('Term record'),
          pw.TableHelper.fromTextArray(
            headers: const ['Term', 'Average', 'Grade', 'Rank'],
            data: [
              for (final t in d.history)
                [
                  t.termLabel,
                  t.overall == null
                      ? '–'
                      : '${t.overall!.toStringAsFixed(1)}%',
                  t.grade,
                  t.rank == null || t.classSize == 0
                      ? '–'
                      : '${t.rank} of ${t.classSize}',
                ],
            ],
            headerStyle: _tHeader,
            cellStyle: _tCell,
            headerDecoration: pw.BoxDecoration(color: _navy),
            headerAlignment: pw.Alignment.centerLeft,
            cellPadding:
                const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            headerPadding:
                const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            headerAlignments: const {
              0: pw.Alignment.centerLeft,
              1: pw.Alignment.centerRight,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.centerRight,
            },
            cellAlignments: const {
              0: pw.Alignment.centerLeft,
              1: pw.Alignment.centerRight,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.centerRight,
            },
            columnWidths: const {
              0: pw.FlexColumnWidth(3),
              1: pw.FlexColumnWidth(1.2),
              2: pw.FlexColumnWidth(1),
              3: pw.FlexColumnWidth(1.2),
            },
            border: pw.TableBorder(
              left: pw.BorderSide(color: _hair, width: 0.5),
              right: pw.BorderSide(color: _hair, width: 0.5),
              top: pw.BorderSide(color: _hair, width: 0.5),
              bottom: pw.BorderSide(color: _hair, width: 0.5),
              horizontalInside: pw.BorderSide(color: _hair, width: 0.5),
              verticalInside: pw.BorderSide(color: _hair, width: 0.5),
            ),
          ),
          _title('Subjects — ${d.termLabel}'),
          _marksTable(d.subjects),
          pw.SizedBox(height: 10),
          pw.Row(
            children: [
              _stat('Overall', d.overallLabel),
              _stat('Grade', d.overallGrade),
              _stat('Attendance', d.attendance?.label ?? '–'),
            ],
          ),
          pw.SizedBox(height: 10),
          _remark(d),
          pw.SizedBox(height: 6),
          _signatures(d),
          _footer(d),
        ],
      ),
    );
