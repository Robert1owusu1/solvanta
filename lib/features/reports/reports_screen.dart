import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/student.dart';
import '../../core/models/school_term.dart';
import '../../core/models/submission.dart';
import '../../core/models/subjects.dart';
import '../../core/platform/file_share.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../analytics/analytics_service.dart';
import '../assessment/assessment_repository.dart';
import '../attendance/attendance_repository.dart';
import '../calendar/term_repository.dart';
import '../students/students_repository.dart';
import 'report_card_screen.dart';
import 'reporting_service.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late Future<ReportsData> _data;
  String? _studentId;
  String? _assessmentId;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<ReportsData> _load() async {
    final repo = AssessmentRepository();
    final assessments = await repo.assessments();
    final subs = await repo.submissions();
    final students = await StudentsRepository().all();
    final term = await TermRepository().current();
    _studentId ??= students.isNotEmpty ? students.first.id : null;
    _assessmentId ??= assessments.isNotEmpty ? assessments.first.id : null;
    return ReportsData(
        assessments: assessments,
        subs: subs,
        students: students,
        term: term);
  }

  Future<void> _save(Uint8List bytes, String name, String extension,
      String mime) async {
    await saveAndShareFile(bytes, '$name.$extension', mime);
  }

  Future<void> _shareCsv(String csv, String name) =>
      _save(Uint8List.fromList(utf8.encode(csv)), name, 'csv', 'text/csv');

  Future<void> _busy(String message, Future<void> Function() action) async {
    svSnack(context, message);
    await action();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Reports & Export'),
      body: FutureBuilder<ReportsData>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return SvErrorState(
              title: "Couldn't load reports",
              message: 'Something went wrong. Please try again.',
              onRetry: () => setState(() => _data = _load()),
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const SvLoading(message: 'Preparing reports…');
          }
          final d = snap.data ?? ReportsData.empty;
          if (d.students.isEmpty || d.assessments.isEmpty) {
            return const SvEmptyState(
              icon: Icons.receipt_long,
              title: 'No data to report yet',
              message: 'Add students and assessments first.',
            );
          }
          final student = d.students
              .firstWhere((s) => s.id == _studentId, orElse: () => d.students.first);
          final assessment = d.assessments
              .firstWhere((a) => a.id == _assessmentId,
                  orElse: () => d.assessments.first);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _termChip(d.term),
              const SizedBox(height: 16),
              Text('Report card — student', style: _head2),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: student.id,
                // Long "name · class" labels share the row with the dropdown
                // arrow — expanded + ellipsis keeps them from painting past
                // the field's right edge (same fix as the Marking dashboard).
                isExpanded: true,
                decoration: const InputDecoration(
                    border: OutlineInputBorder(), labelText: 'Student'),
                items: [
                  for (final s in d.students)
                    DropdownMenuItem(
                        value: s.id,
                        child: Text(
                          '${s.fullName} · ${s.classId}',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        )),
                ],
                onChanged: (v) => setState(() => _studentId = v),
              ),
              const SizedBox(height: 12),
              _StudentReportCard(d, student),
              const SizedBox(height: 8),
              // Branded templates (Classic / Modern / Transcript) with a live
              // preview and a shareable A4 PDF.
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ReportCardScreen()),
                ),
                icon: const Icon(Icons.palette_outlined),
                label: const Text('Design & share report card (PDF)'),
              ),
              const SizedBox(height: 8),
              _exportRow(
                onTap: () => _busy('Building PDF…', () async {
                  final bytes = await ReportingService().reportCardPdf(
                    student: student,
                    termLabel: d.term.label,
                    assessments: d.assessments,
                    subs: d.subs,
                    attendance: await _attendance(student.id),
                  );
                  if (mounted) {
                    await _save(bytes, 'report_${student.id}', 'pdf',
                        'application/pdf');
                  }
                }),
                onExcel: () => _busy('Building Excel workbook…', () async {
                  final bytes = ReportingService().reportCardXlsx(
                    student: student,
                    termLabel: d.term.label,
                    assessments: d.assessments,
                    subs: d.subs,
                    attendance: await _attendance(student.id),
                  );
                  if (mounted) {
                    await _save(bytes, 'report_${student.id}', 'xlsx',
                        'application/vnd.openxmlformats-officedocument'
                            '.spreadsheetml.sheet');
                  }
                }),
                onCsv: () => _shareCsv(
                  ReportingService().studentReportCsv(
                      student: student,
                      assessments: d.assessments,
                      subs: d.subs),
                  'report_${student.id}',
                ),
              ),
              const Divider(height: 32),
              Text('Class results', style: _head2),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: assessment.id,
                // "Title · subject" runs well past the field on this screen
                // (observed: RIGHT OVERFLOWED BY 55 PIXELS) — expanded +
                // ellipsis keeps it sharing the row with the arrow.
                isExpanded: true,
                decoration: const InputDecoration(
                    border: OutlineInputBorder(), labelText: 'Assessment'),
                items: [
                  for (final a in d.assessments)
                    DropdownMenuItem(
                        value: a.id,
                        child: Text(
                          '${a.title} · ${subjectName(a.subjectId)}',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        )),
                ],
                onChanged: (v) => setState(() => _assessmentId = v),
              ),
              const SizedBox(height: 12),
              _exportRow(
                onTap: null,
                onExcel: () => _busy('Building Excel workbook…', () async {
                  final bytes = ReportingService().classResultsXlsx(
                    assessment: assessment,
                    roster: d.students
                        .where((s) => s.classId == assessment.classId)
                        .toList(),
                    subs: d.subs,
                  );
                  if (mounted) {
                    await _save(bytes, 'class_${assessment.id}', 'xlsx',
                        'application/vnd.openxmlformats-officedocument'
                            '.spreadsheetml.sheet');
                  }
                }),
                onCsv: () => _shareCsv(
                  ReportingService().classResultsCsv(
                    assessment: assessment,
                    roster: d.students
                        .where((s) => s.classId == assessment.classId)
                        .toList(),
                    subs: d.subs,
                  ),
                  'class_${assessment.id}',
                ),
              ),
              const Divider(height: 32),
              Text('School summary — ${d.term.label}', style: _head2),
              const SizedBox(height: 8),
              _SchoolSummary(d),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _busy('Building Excel workbook…', () async {
                  final bytes = ReportingService().schoolSummaryXlsx(
                    students: d.students,
                    assessments: d.assessments,
                    subs: d.subs,
                    termLabel: d.term.label,
                  );
                  if (mounted) {
                    await _save(bytes, 'school_summary', 'xlsx',
                        'application/vnd.openxmlformats-officedocument'
                            '.spreadsheetml.sheet');
                  }
                }),
                icon: const Icon(Icons.ios_share),
                label: const Text('Export school summary (Excel)'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<({int total, int present})?> _attendance(String studentId) async {
    final s = await AttendanceRepository().summaryForStudent(studentId);
    final total = s.total;
    if (total == 0) return null;
    return (total: total, present: s.present + s.late);
  }

  Widget _termChip(SchoolTerm term) => Card(
        color: AppTheme.brand.withValues(alpha: .05),
        child: ListTile(
          leading: Icon(Icons.school, color: AppTheme.brand),
          title: Text(term.label,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text('${term.start} → ${term.end}'),
        ),
      );

  Widget _exportRow({
    required VoidCallback? onTap,
    required VoidCallback onExcel,
    required VoidCallback onCsv,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (onTap != null)
          FilledButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('PDF'),
          ),
        OutlinedButton.icon(
          onPressed: onExcel,
          icon: const Icon(Icons.grid_on_outlined),
          label: const Text('Excel'),
        ),
        OutlinedButton.icon(
          onPressed: onCsv,
          icon: const Icon(Icons.ios_share),
          label: const Text('CSV'),
        ),
      ],
    );
  }
}

class _StudentReportCard extends StatelessWidget {
  final ReportsData d;
  final Student student;

  const _StudentReportCard(this.d, this.student);

  @override
  Widget build(BuildContext context) {
    final rows = ReportingService().rowsFor(
        student: student, assessments: d.assessments, subs: d.subs);
    final subjects = ReportingService().subjectsFor(rows: rows);
    final overall = ReportingService().overallFor(rows: rows);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(student.fullName,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            Text('${student.classId} · ${student.id}', style: _muted2),
            const SizedBox(height: 10),
            for (final s in subjects)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 140,
                      child: Text(subjectName(s.subjectId),
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    Expanded(
                      child: Text('${s.attempts}/${s.of} marked',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                    ),
                    Text(
                      s.average == null
                          ? '–'
                          : '${s.average!.toStringAsFixed(0)}%',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: s.average == null
                              ? AppColors.muted
                              : AppTheme.brand),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 20,
                      child: Text(
                        s.average == null ? '–' : gradeLetter(s.average!),
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 15),
                      ),
                    ),
                  ],
                ),
              ),
            const Divider(),
            Row(
              children: [
                const Text('Overall',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(
                  overall == null
                      ? 'No marked work yet'
                      : '${overall.toStringAsFixed(0)}%',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: AppTheme.brand),
                ),
                if (overall != null) ...[
                  const SizedBox(width: 8),
                  Text(gradeLetter(overall),
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SchoolSummary extends StatelessWidget {
  final ReportsData d;

  const _SchoolSummary(this.d);

  @override
  Widget build(BuildContext context) {
    final summaries = <(Student, double?)>[];
    for (final s in d.students) {
      final rows = ReportingService()
          .rowsFor(student: s, assessments: d.assessments, subs: d.subs);
      summaries.add((s, ReportingService().overallFor(rows: rows)));
    }
    summaries.sort((a, b) => (b.$2 ?? -1).compareTo(a.$2 ?? -1));
    final ranked = summaries
        .where((x) => x.$2 != null)
        .take(20)
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (s, overall) in ranked)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('${s.fullName} · ${s.classId}',
                          style: const TextStyle(fontSize: 13),
                          overflow: TextOverflow.ellipsis),
                    ),
                    Text('${overall!.toStringAsFixed(0)}%',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13)),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 18,
                      child: Text(gradeLetter(overall),
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 14)),
                    ),
                  ],
                ),
              ),
            if (ranked.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text('No marked assessments yet.',
                    style: TextStyle(color: AppColors.muted)),
              ),
          ],
        ),
      ),
    );
  }
}

// Data + styling for this screen.
class ReportsData {
  final List<Assessment> assessments;
  final List<AssessmentSubmission> subs;
  final List<Student> students;
  final SchoolTerm term;

  const ReportsData({
    required this.assessments,
    required this.subs,
    required this.students,
    required this.term,
  });

  static const empty = ReportsData(
      assessments: [], subs: [], students: [], term: SchoolTerm.fallback);
}

final _head2 = const TextStyle(fontSize: 16, fontWeight: FontWeight.w700);
final _muted2 = TextStyle(fontSize: 12, color: AppColors.muted);