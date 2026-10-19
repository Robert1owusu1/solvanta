import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/attendance.dart';
import '../../core/models/school.dart';
import '../../core/models/school_term.dart';
import '../../core/models/submission.dart';
import '../../core/models/student.dart';
import '../../core/models/user.dart';
import '../../core/platform/file_share.dart';
import '../../core/settings/app_settings.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/offline_lite.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../assessment/assessment_repository.dart';
import '../calendar/term_repository.dart';
import '../students/students_repository.dart';
import 'report_card_pdf.dart';

/// Failures never surface as an exception: a SnackBar on the brand danger
/// surface (`AppColors.dangerSolid`) with white text.
void reportCardFailSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w600),
        ),
        backgroundColor: AppColors.dangerSolid,
        duration: const Duration(seconds: 3),
      ),
    );
}

/// Report cards: pick a student, switch between the Classic / Modern /
/// Transcript templates, watch a live first-page preview and share the
/// generated A4 PDF.
///
/// Everything is built from the local store, so the screen works offline; the
/// data-saver preference ([shouldSkipHeavyFetch]) additionally reuses the last
/// built card instead of re-walking the class roster for the rank.
class ReportCardScreen extends StatefulWidget {
  const ReportCardScreen({super.key});

  @override
  State<ReportCardScreen> createState() => _ReportCardScreenState();
}

class _ReportCardScreenState extends State<ReportCardScreen> {
  /// Preview paper size in design units (A4 ratio) — the parent scales it to
  /// the available width.
  static const double _paperW = 420;
  static const double _paperH = 594;

  late Future<_ReportSource> _data;
  String? _studentId;
  ReportCardTemplate _template = ReportCardTemplate.classic;
  bool _working = false;

  /// Built cards and when they were built — the data-saver cache behind
  /// [shouldSkipHeavyFetch].
  final Map<String, ReportCardData> _cards = {};
  final Map<String, DateTime> _builtAt = {};

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_ReportSource> _load() async {
    final repo = AssessmentRepository();
    final assessments = await repo.assessments();
    final subs = await repo.submissions();
    final students = await StudentsRepository().all();
    final term = await TermRepository().current();
    final store = LocalStore();
    final school = await store.loadSchool();
    final users = await store.loadUsers();

    // Attendance is read locally (not fetched) so the card renders offline.
    final records = await store.loadAttendance();
    final attendance = <String, List<AttendanceRecord>>{};
    for (final r in records) {
      (attendance[r.studentId] ??= <AttendanceRecord>[]).add(r);
    }

    _studentId ??= students.isNotEmpty ? students.first.id : null;
    return _ReportSource(
      students: students,
      assessments: assessments,
      subs: subs,
      term: term,
      school: school ?? const School(id: 'SCH-001', name: 'SOLVANTA School'),
      users: users,
      attendance: attendance,
    );
  }

  /// Class teacher for the student's class, or `''` when none is on record.
  String _teacherNameFor(_ReportSource s, Student student) {
    final teacher = s.users
        .where((u) => u.role.isTeacher && u.classId == student.classId)
        .firstOrNull;
    return teacher?.name ?? '';
  }

  /// Builds (or reuses) the card for [student]. The rank walk is the only
  /// expensive part, so under data saver a fresh-enough card is served as is.
  ReportCardData _cardFor(_ReportSource s, Student student) {
    final cached = _cards[student.id];
    if (cached != null &&
        shouldSkipHeavyFetch(
            lastFetched: _builtAt[student.id], tier: CacheTier.heavy)) {
      return cached;
    }
    final records = s.attendance[student.id] ?? const <AttendanceRecord>[];
    ({int total, int present})? attendance;
    if (records.isNotEmpty) {
      attendance = (
        total: records.length,
        present: records
            .where((r) =>
                r.status == AttendanceStatus.present ||
                r.status == AttendanceStatus.late)
            .length,
      );
    }
    final card = ReportCardDataBuilder.build(
      student: student,
      school: s.school,
      term: s.term,
      assessments: s.assessments,
      subs: s.subs,
      roster: s.students,
      teacherName: _teacherNameFor(s, student),
      attendance: attendance,
    );
    _cards[student.id] = card;
    _builtAt[student.id] = DateTime.now();
    return card;
  }

  /// Renders the PDF, writes it to the temp dir and opens the share sheet.
  /// Any failure degrades to a SnackBar instead of an exception.
  Future<void> _share(ReportCardData card) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final bytes = await buildReportCardPdf(card, _template);
      final name = 'report_${card.studentId}_${_template.name}';
      svHaptic(SvHaptic.medium);
      if (!mounted) return;
      await saveAndShareFile(bytes, '$name.pdf', 'application/pdf');
    } catch (_) {
      if (mounted) {
        reportCardFailSnack(
            context, "Couldn't build the PDF. Please try again.");
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Staggered entrance, honouring Reduce motion / Data saver.
  Widget _entrance(Widget child) {
    if (AppSettings.instance.motionOff) return child;
    return SvEntrance(child: child);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SvScreenHeader(
        title: 'Report Cards',
        subtitle: 'Classic, Modern & Transcript layouts',
      ),
      body: FutureBuilder<_ReportSource>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return SvErrorState(
              title: "Couldn't load report data",
              message: 'We couldn\'t load students or assessments. '
                  'Please try again.',
              onRetry: () => setState(() => _data = _load()),
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const _PreviewSkeleton();
          }
          final src = snap.data;
          if (src == null) return const SvErrorState();
          if (src.students.isEmpty) {
            return const SvEmptyState(
              icon: Icons.school_outlined,
              title: 'No students yet',
              message: 'Enrol students first — a report card needs someone '
                  'to report on.',
            );
          }
          if (src.assessments.isEmpty) {
            return const SvEmptyState(
              icon: Icons.assignment_outlined,
              title: 'No assessments yet',
              message: 'Record some results first — report cards are built '
                  'from marks.',
            );
          }
          final student = src.students.firstWhere((s) => s.id == _studentId,
              orElse: () => src.students.first);
          final card = _cardFor(src, student);

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: DropdownButtonFormField<String>(
                  initialValue: student.id,
                  // "name · class" is dynamic — expanded + ellipsis keeps it
                  // sharing the row with the arrow (no right overflow).
                  isExpanded: true,
                  decoration: const InputDecoration(
                      border: OutlineInputBorder(), labelText: 'Student'),
                  items: [
                    for (final s in src.students)
                      DropdownMenuItem(
                        value: s.id,
                        child: Text(
                          '${s.fullName} · ${s.classId}',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _studentId = v),
                ),
              ),
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Template',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13)),
                ),
              ),
              const SizedBox(height: 6),
              _entrance(
                SvFilterChips(
                  options: [
                    for (final t in ReportCardTemplate.values)
                      SvFilterOption(t.label, selected: t == _template),
                  ],
                  onSelected: (i) {
                    svHaptic(SvHaptic.selection);
                    setState(() => _template = ReportCardTemplate.values[i]);
                  },
                ),
              ),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Live preview',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 13)),
                    ),
                    Text('A4 · first page',
                        style: TextStyle(fontSize: 11.5)),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final scale =
                        ((constraints.maxWidth - 24) / _paperW)
                            .clamp(0.4, 3.0)
                            .toDouble();
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      child: Center(
                        child: SizedBox(
                          width: _paperW * scale,
                          height: _paperH * scale,
                          child: Transform.scale(
                            scale: scale,
                            alignment: Alignment.topLeft,
                            child: MediaQuery(
                              data: MediaQuery.of(context)
                                  .copyWith(textScaler: TextScaler.noScaling),
                              child: _ReportPreview(
                                data: card,
                                template: _template,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: _working ? null : () => _share(card),
                      icon: _working
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.ios_share),
                      label: Text(
                          _working ? 'Building PDF…' : 'Generate & share'),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------

// Paper tokens. The printed page is always white, so the preview uses the
// light palette in both brightnesses; every one is a runtime `final` so the
// surrounding widgets can never accidentally become const.
final BoxDecoration _pvRowRule = BoxDecoration(
    border:
        Border(bottom: BorderSide(color: AppPalette.light.border, width: 0.6)));
final TextStyle _pvInk =
    TextStyle(color: AppPalette.light.ink, fontSize: 9);
final TextStyle _pvLabel = TextStyle(
    color: AppPalette.light.ink, fontSize: 8, fontWeight: FontWeight.w700);
const TextStyle _pvValue = TextStyle(color: Colors.black, fontSize: 8.5);
const TextStyle _pvStatValue = TextStyle(
    color: Colors.black, fontSize: 11, fontWeight: FontWeight.w800);
const TextStyle _pvScore = TextStyle(
    color: Colors.black, fontSize: 18, fontWeight: FontWeight.w800);
final TextStyle _pvMuted =
    TextStyle(color: AppPalette.light.body, fontSize: 7.5);
final TextStyle _pvSection = TextStyle(
    color: AppTheme.brand, fontSize: 10.5, fontWeight: FontWeight.w800);
const TextStyle _pvWhite = TextStyle(
    color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800);
const TextStyle _pvWhiteSmall = TextStyle(
    color: Colors.white70, fontSize: 7.5, fontWeight: FontWeight.w400);
const TextStyle _pvHeader = TextStyle(
    color: Colors.white, fontSize: 7.5, fontWeight: FontWeight.w700);

/// The live first-page preview: a widget replica of the printed page at a
/// fixed design size, so no PDF rasteriser (or extra dependency) is needed.
class _ReportPreview extends StatelessWidget {
  const _ReportPreview({required this.data, required this.template});

  final ReportCardData data;
  final ReportCardTemplate template;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Live preview: ${template.label} report card for '
          '${data.studentName}',
      child: Container(
        width: 420,
        height: 594,
        color: AppPalette.light.surface,
        child: switch (template) {
          ReportCardTemplate.classic => _previewClassic(data),
          ReportCardTemplate.modern => _previewModern(data),
          ReportCardTemplate.transcript => _previewTranscript(data),
        },
      ),
    );
  }
}

/// Classic: full-bleed navy masthead, gold hairline, ruled marks table.
Widget _previewClassic(ReportCardData d) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        color: AppTheme.brand,
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('SOLVANTA',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 7.5,
                          letterSpacing: 2.4)),
                  const SizedBox(height: 3),
                  Text(d.schoolName, style: _pvWhite),
                  if (d.schoolMotto.isNotEmpty)
                    Text(d.schoolMotto, style: _pvWhiteSmall),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Text('REPORT CARD',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 7.5,
                        letterSpacing: 2.4)),
                const SizedBox(height: 3),
                Text(d.termLabel, style: _pvWhiteSmall),
              ],
            ),
          ],
        ),
      ),
      Container(height: 3, color: AppTheme.gold),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _pvKv('Student', d.studentName),
              _pvKv('Adm. No.', d.admissionNo),
              _pvKv('Class', d.classId),
              _pvKv('Term', d.termLabel),
              if (d.attendance != null)
                _pvKv('Attendance', d.attendance!.label),
              const SizedBox(height: 8),
              Row(
                children: [
                  _pvStat('Overall', d.overallLabel),
                  _pvStat('Grade', d.overallGrade),
                  _pvStat('Position', d.rankLabel),
                ],
              ),
              const SizedBox(height: 10),
              Text('Subjects', style: _pvSection),
              const SizedBox(height: 4),
              _pvTableHeader(),
              for (final s in d.subjects) _pvTableRow(s),
              const SizedBox(height: 10),
              _pvRemark(d),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _pvSignature('Class teacher', d.teacherName)),
                  const SizedBox(width: 24),
                  Expanded(child: _pvSignature('Head teacher', '')),
                ],
              ),
              const SizedBox(height: 10),
              _pvFooter(d),
            ],
          ),
        ),
      ),
    ],
  );
}

/// Modern: white masthead, navy rules, per-subject bars, oversized overall.
Widget _previewModern(ReportCardData d) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(26, 22, 26, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(d.schoolName,
                            style: const TextStyle(
                                color: AppTheme.brand,
                                fontSize: 14,
                                fontWeight: FontWeight.w800)),
                        Text(d.schoolMotto, style: _pvMuted),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text('REPORT CARD',
                          style: TextStyle(
                              color: Colors.black,
                              fontSize: 9,
                              letterSpacing: 1.6,
                              fontWeight: FontWeight.w700)),
                      Text(d.termLabel, style: _pvMuted),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(height: 2, color: AppTheme.brand),
              const SizedBox(height: 2),
              Container(height: 1, color: AppTheme.brandLight),
              const SizedBox(height: 14),
              Text(d.studentName,
                  style: TextStyle(
                      color: AppPalette.light.ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text('${d.classId} · ${d.admissionNo}', style: _pvMuted),
              const SizedBox(height: 12),
              Row(
                children: [
                  _pvStat('Class', d.classId),
                  _pvStat('Position', d.rankLabel),
                  _pvStat(
                      'Attendance', d.attendance?.label ?? '–'),
                ],
              ),
              const SizedBox(height: 12),
              Text('Subjects', style: _pvSection),
              const SizedBox(height: 4),
              for (final s in d.subjects) _pvModernRow(s),
              const SizedBox(height: 6),
              const Divider(height: 12, thickness: 0.6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('OVERALL', style: _pvMuted),
                        const SizedBox(height: 2),
                        Text("Class teacher's remark", style: _pvLabel),
                      ],
                    ),
                  ),
                  Text(d.overallLabel, style: _pvScore),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 18,
                    child: Text(d.overallGrade,
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            color: Colors.black,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(d.remark, style: _pvValue),
              const SizedBox(height: 4),
              Text(
                d.teacherName.isEmpty
                    ? 'Class teacher'
                    : 'Class teacher · ${d.teacherName}',
                style: _pvMuted,
              ),
              const SizedBox(height: 8),
              _pvFooter(d),
            ],
          ),
        ),
      ),
    ],
  );
}

/// Transcript: term-summary table above the current term's subjects.
Widget _previewTranscript(ReportCardData d) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(26, 22, 26, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(d.schoolName,
                            style: const TextStyle(
                                color: AppTheme.brand,
                                fontSize: 14,
                                fontWeight: FontWeight.w800)),
                        Text(d.schoolMotto, style: _pvMuted),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text('TRANSCRIPT',
                          style: TextStyle(
                              color: Colors.black,
                              fontSize: 9,
                              letterSpacing: 1.6,
                              fontWeight: FontWeight.w700)),
                      Text(d.termLabel, style: _pvMuted),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(height: 2, color: AppTheme.brand),
              const SizedBox(height: 10),
              Text(d.studentName, style: _pvSection),
              const SizedBox(height: 4),
              _pvKv('Adm. No.', d.admissionNo),
              _pvKv('Class', d.classId),
              _pvKv('Term', d.termLabel),
              const SizedBox(height: 8),
              Text('Term record', style: _pvSection),
              const SizedBox(height: 4),
              _pvTermHeader(),
              for (final t in d.history) _pvTermRow(t),
              const SizedBox(height: 10),
              Text('Subjects — ${d.termLabel}', style: _pvSection),
              const SizedBox(height: 4),
              _pvTableHeader(),
              for (final s in d.subjects) _pvTableRow(s),
              const SizedBox(height: 10),
              Row(
                children: [
                  _pvStat('Overall', d.overallLabel),
                  _pvStat('Grade', d.overallGrade),
                  _pvStat('Attendance', d.attendance?.label ?? '–'),
                ],
              ),
              const SizedBox(height: 10),
              _pvRemark(d),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _pvSignature('Class teacher', d.teacherName)),
                  const SizedBox(width: 24),
                  Expanded(child: _pvSignature('Head teacher', '')),
                ],
              ),
              const SizedBox(height: 10),
              _pvFooter(d),
            ],
          ),
        ),
      ),
    ],
  );
}

Widget _pvKv(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 76, child: Text(label, style: _pvLabel)),
          Expanded(child: Text(value, style: _pvValue)),
        ],
      ),
    );

Widget _pvStat(String label, String value) => Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: AppPalette.light.background,
          border: Border.all(color: AppPalette.light.border, width: 0.6),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label.toUpperCase(), style: _pvMuted),
            const SizedBox(height: 2),
            Text(value, style: _pvStatValue),
          ],
        ),
      ),
    );

Widget _pvRemark(ReportCardData d) => Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.brand, width: 0.8),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Class teacher's remark", style: _pvLabel),
          const SizedBox(height: 3),
          Text(d.remark, style: _pvValue),
        ],
      ),
    );

Widget _pvSignature(String label, String name) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(name.isEmpty ? ' ' : name, style: _pvLabel),
        Container(height: 0.8, color: AppPalette.light.border),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(label, style: _pvMuted),
        ),
      ],
    );

Widget _pvFooter(ReportCardData d) => Text(
      'Generated by SOLVANTA · ${d.schoolName}',
      textAlign: TextAlign.center,
      style: _pvMuted,
    );

Widget _pvTableHeader() => Container(
      color: AppTheme.brand,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: const Row(
        children: [
          Expanded(child: Text('Subject', style: _pvHeader)),
          SizedBox(
            width: 46,
            child: Text('Marked',
                textAlign: TextAlign.right, style: _pvHeader),
          ),
          SizedBox(
            width: 54,
            child: Text('Average',
                textAlign: TextAlign.right, style: _pvHeader),
          ),
          SizedBox(
            width: 34,
            child:
                Text('Grade', textAlign: TextAlign.right, style: _pvHeader),
          ),
        ],
      ),
    );

Widget _pvTableRow(SubjectResult s) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: _pvRowRule,
      child: Row(
        children: [
          Expanded(child: Text(s.name, style: _pvInk)),
          SizedBox(
            width: 46,
            child: Text('${s.marked}/${s.of}',
                textAlign: TextAlign.right, style: _pvValue),
          ),
          SizedBox(
            width: 54,
            child: Text(s.averageLabel,
                textAlign: TextAlign.right, style: _pvValue),
          ),
          SizedBox(
            width: 34,
            child: Text(s.grade,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    color: Colors.black,
                    fontSize: 9,
                    fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );

Widget _pvTermHeader() => Container(
      color: AppTheme.brand,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: const Row(
        children: [
          Expanded(child: Text('Term', style: _pvHeader)),
          SizedBox(
            width: 54,
            child: Text('Average',
                textAlign: TextAlign.right, style: _pvHeader),
          ),
          SizedBox(
            width: 34,
            child:
                Text('Grade', textAlign: TextAlign.right, style: _pvHeader),
          ),
          SizedBox(
            width: 54,
            child:
                Text('Rank', textAlign: TextAlign.right, style: _pvHeader),
          ),
        ],
      ),
    );

Widget _pvTermRow(TermRecord t) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: _pvRowRule,
      child: Row(
        children: [
          Expanded(child: Text(t.termLabel, style: _pvInk)),
          SizedBox(
            width: 54,
            child: Text(
                t.overall == null
                    ? '–'
                    : '${t.overall!.toStringAsFixed(1)}%',
                textAlign: TextAlign.right,
                style: _pvValue),
          ),
          SizedBox(
            width: 34,
            child: Text(t.grade,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    color: Colors.black,
                    fontSize: 9,
                    fontWeight: FontWeight.w800)),
          ),
          SizedBox(
            width: 54,
            child: Text(
                t.rank == null || t.classSize == 0
                    ? '–'
                    : '${t.rank} of ${t.classSize}',
                textAlign: TextAlign.right,
                style: _pvValue),
          ),
        ],
      ),
    );

/// Navy-only progress bar — one navy ramp, never traffic lights.
Widget _pvBar(double? average) {
  final filled =
      average == null ? 0.0 : average.clamp(0, 100).toDouble() / 100 * 80;
  return Container(
    width: 80,
    height: 6,
    color: AppTheme.navy100,
    child: Align(
      alignment: Alignment.centerLeft,
      child: Container(
          width: filled, height: 6, color: AppTheme.brand),
    ),
  );
}

Widget _pvModernRow(SubjectResult s) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(s.name, style: _pvInk)),
          _pvBar(s.average),
          const SizedBox(width: 8),
          SizedBox(
            width: 50,
            child: Text(s.averageLabel,
                textAlign: TextAlign.right, style: _pvValue),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 18,
            child: Text(s.grade,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    color: Colors.black,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );

// ---------------------------------------------------------------------------
// Supporting types
// ---------------------------------------------------------------------------

/// Everything the screen needs from storage, loaded once per screen session.
class _ReportSource {
  const _ReportSource({
    required this.students,
    required this.assessments,
    required this.subs,
    required this.term,
    required this.school,
    required this.users,
    required this.attendance,
  });

  final List<Student> students;
  final List<Assessment> assessments;
  final List<AssessmentSubmission> subs;
  final SchoolTerm term;
  final School school;
  final List<User> users;

  /// Attendance records bucketed by student id.
  final Map<String, List<AttendanceRecord>> attendance;
}

/// Page-shaped skeleton shown while the report source loads.
class _PreviewSkeleton extends StatelessWidget {
  const _PreviewSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SvSkeleton(height: 70, radius: 10),
          SizedBox(height: 16),
          SvSkeleton(height: 14),
          SizedBox(height: 10),
          SvSkeleton(height: 14),
          SizedBox(height: 22),
          SvSkeleton(height: 24),
          SizedBox(height: 10),
          SvSkeleton(height: 24),
          SizedBox(height: 10),
          SvSkeleton(height: 24),
          SizedBox(height: 22),
          SvSkeleton(height: 120, radius: 12),
        ],
      ),
    );
  }
}
