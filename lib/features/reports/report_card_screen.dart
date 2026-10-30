import 'package:flutter/material.dart';

import '../../core/models/grading.dart';
import '../../core/models/role.dart';
import '../../core/models/term_report.dart';
import '../../core/models/user.dart';
import '../../core/models/student.dart';
import '../../core/platform/file_share.dart';
import '../../core/settings/app_settings.dart';
import '../../core/sync/offline_lite.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import 'report_card_pdf.dart';
import 'report_card_source.dart';
import 'term_reports_repository.dart';
import '../auth/auth_repository.dart';

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
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: AppColors.dangerSolid,
        duration: const Duration(seconds: 3),
      ),
    );
}

/// Report cards: pick a student, switch between the Ghanaian terminal
/// report / Modern / Transcript templates, watch a live first-page preview and share the
/// generated A4 PDF.
///
/// The class teacher writes each pupil's remark and conduct / attitude /
/// interest; a school leader adds the headteacher's remark and approves,
/// which freezes the card and releases it to the family. A teacher sees only
/// their own class. A whole class prints as one PDF.
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

  late Future<ReportCardSource> _data;
  String? _studentId;
  User? _me;
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

  Future<ReportCardSource> _load() async {
    final source = await ReportCardSource.load();
    _me = await AuthRepository().currentUser();
    _studentId ??= _students(source).firstOrNull?.id;
    return source;
  }

  /// School leaders approve and reopen reports and write the head's remark.
  bool get _leader =>
      _me?.role == AppRole.superAdmin ||
      _me?.role == AppRole.schoolAdmin ||
      _me?.role == AppRole.headteacher;

  /// The students this user reports on: a teacher only their own class.
  List<Student> _students(ReportCardSource s) => _me?.role == AppRole.teacher
      ? [
          for (final st in s.students)
            if (st.classId == _me?.classId) st,
        ]
      : s.students;

  /// Whether this user may write [student]'s class-teacher fields now.
  bool _canWriteRemarks(Student student, TermReport report) =>
      !report.approved &&
      (_leader ||
          (_me?.role == AppRole.teacher && _me?.classId == student.classId));

  Future<void> _editRemarks(
    ReportCardSource src,
    Student student,
    ReportCardData card,
  ) async {
    final report = src.reportFor(student);
    final saved = await showModalBottomSheet<TermReport>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RemarksSheet(
        report: report,
        studentName: student.fullName,
        draftRemark: card.remark,
        leader: _leader,
      ),
    );
    if (saved == null) return;
    await TermReportsRepository().save(saved);
    _reload();
  }

  Future<void> _approve(ReportCardSource src, Student student) async {
    final ok = await svConfirm(
      context,
      title: 'Approve ${student.firstName}\'s card?',
      message:
          'The card is frozen exactly as it is now and released to the '
          'family. Later mark changes won\'t alter it unless you reopen it.',
      confirmLabel: 'Approve',
    );
    if (!ok) return;
    final report = src.reportFor(student);
    await TermReportsRepository().approve(
      report,
      ReportCardSource.withReport(src.liveCardFor(student), report),
      _me?.name ?? 'Headteacher',
    );
    _reload();
  }

  Future<void> _reopen(ReportCardSource src, Student student) async {
    final ok = await svConfirm(
      context,
      title: 'Reopen ${student.firstName}\'s card?',
      message:
          'It goes back to a draft built from the latest marks, and the '
          'family no longer sees it until it is approved again.',
      confirmLabel: 'Reopen',
    );
    if (!ok) return;
    await TermReportsRepository().reopen(src.reportFor(student));
    _reload();
  }

  /// Students of [classId] in name order.
  List<Student> _classOf(ReportCardSource src, String classId) => [
    for (final s in _students(src))
      if (s.classId == classId) s,
  ]..sort((a, b) => a.fullName.compareTo(b.fullName));

  Future<void> _approveClass(ReportCardSource src, String classId) async {
    final todo = [
      for (final s in _classOf(src, classId))
        if (!src.reportFor(s).approved && src.liveCardFor(s).overall != null) s,
    ];
    if (todo.isEmpty) {
      reportCardFailSnack(context, 'Nothing to approve in $classId.');
      return;
    }
    final ok = await svConfirm(
      context,
      title: 'Approve $classId?',
      message:
          'Approve ${todo.length} card(s) as they are now and release '
          'them to families. Pupils with no marks yet are left as drafts.',
      confirmLabel: 'Approve all',
    );
    if (!ok) return;
    setState(() => _working = true);
    for (final s in todo) {
      final report = src.reportFor(s);
      await TermReportsRepository().approve(
        report,
        ReportCardSource.withReport(src.liveCardFor(s), report),
        _me?.name ?? 'Headteacher',
      );
    }
    if (!mounted) return;
    setState(() => _working = false);
    _reload();
  }

  /// The whole class as one PDF, a page per pupil — approved cards exactly
  /// as approved, the rest as drafts marked so.
  Future<void> _printClass(String classId) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final src = await _load();
      final cards = [for (final s in _classOf(src, classId)) src.cardFor(s)];
      if (cards.isEmpty) throw StateError('no students in $classId');
      final bytes = await buildClassReportPdf(cards, _template);
      if (!mounted) return;
      await saveAndShareFile(
        bytes,
        'reports_${classId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}_${_template.name}.pdf',
        'application/pdf',
      );
    } catch (_) {
      if (mounted) {
        reportCardFailSnack(context, "Couldn't build the class PDF.");
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Builds (or reuses) the card for [student]. The rank walk is the only
  /// expensive part, so under data saver a fresh-enough card is served as is.
  ReportCardData _cardFor(ReportCardSource s, Student student) {
    final cached = _cards[student.id];
    if (cached != null &&
        shouldSkipHeavyFetch(
          lastFetched: _builtAt[student.id],
          tier: CacheTier.heavy,
        )) {
      return cached;
    }
    final card = s.cardFor(student);
    _cards[student.id] = card;
    _builtAt[student.id] = DateTime.now();
    return card;
  }

  /// Re-reads marks, attendance and terms and drops every built card, so
  /// nothing on screen predates the latest saved (or synced) data.
  void _reload() {
    _cards.clear();
    _builtAt.clear();
    setState(() => _data = _load());
  }

  /// Re-reads the latest data, rebuilds [studentId]'s card from it, renders
  /// the PDF, writes it to the temp dir and opens the share sheet — so a
  /// shared card always reflects marks entered since the screen opened.
  /// Any failure degrades to a SnackBar instead of an exception.
  Future<void> _share(String studentId) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final src = await _load();
      final student = _students(src)
          .where((s) => s.id == studentId)
          .firstOrNull;
      if (student == null) throw StateError('student $studentId is gone');
      _cards.remove(studentId);
      final card = _cardFor(src, student);
      if (mounted) setState(() => _data = Future.value(src));
      final bytes = await buildReportCardPdf(card, _template);
      final safeId = card.studentId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final name = 'report_${safeId}_${_template.name}';
      svHaptic(SvHaptic.medium);
      if (!mounted) return;
      await saveAndShareFile(bytes, '$name.pdf', 'application/pdf');
    } catch (_) {
      if (mounted) {
        reportCardFailSnack(
          context,
          "Couldn't build the PDF. Please try again.",
        );
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
      appBar: SvScreenHeader(
        title: 'Report Cards',
        subtitle: 'Terminal report, Modern & Transcript layouts',
        actions: [
          IconButton(
            tooltip: 'Refresh marks & attendance',
            icon: const Icon(Icons.refresh),
            onPressed: _working ? null : _reload,
          ),
          FutureBuilder<ReportCardSource>(
            future: _data,
            builder: (context, snap) {
              final src = snap.data;
              final student = src == null
                  ? null
                  : _students(src).where((s) => s.id == _studentId).firstOrNull;
              if (src == null || student == null) {
                return const SizedBox.shrink();
              }
              final classId = student.classId;
              return PopupMenuButton<String>(
                tooltip: 'Whole class',
                icon: const Icon(Icons.more_vert, color: Colors.white),
                enabled: !_working,
                onSelected: (v) => v == 'print'
                    ? _printClass(classId)
                    : _approveClass(src, classId),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'print',
                    child: Text('Print all of $classId'),
                  ),
                  if (_leader)
                    PopupMenuItem(
                      value: 'approve',
                      child: Text('Approve all of $classId'),
                    ),
                ],
              );
            },
          ),
        ],
      ),
      body: FutureBuilder<ReportCardSource>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return SvErrorState(
              title: "Couldn't load report data",
              message:
                  'We couldn\'t load students or assessments. '
                  'Please try again.',
              onRetry: _reload,
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const _PreviewSkeleton();
          }
          final src = snap.data;
          if (src == null) return const SvErrorState();
          final students = _students(src);
          if (students.isEmpty) {
            return const SvEmptyState(
              icon: Icons.school_outlined,
              title: 'No students yet',
              message:
                  'Enrol students first — a report card needs someone '
                  'to report on.',
            );
          }
          if (src.assessments.isEmpty) {
            return const SvEmptyState(
              icon: Icons.assignment_outlined,
              title: 'No assessments yet',
              message:
                  'Record some results first — report cards are built '
                  'from marks.',
            );
          }
          final student = students.firstWhere(
            (s) => s.id == _studentId,
            orElse: () => students.first,
          );
          final card = _cardFor(src, student);
          final report = src.reportFor(student);

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
                    border: OutlineInputBorder(),
                    labelText: 'Student',
                  ),
                  items: [
                    for (final s in students)
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
              _ReportStatusBar(
                report: report,
                canWrite: _canWriteRemarks(student, report),
                leader: _leader,
                busy: _working,
                onRemarks: () => _editRemarks(src, student, card),
                onApprove: () => _approve(src, student),
                onReopen: () => _reopen(src, student),
              ),
              const SizedBox(height: 4),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Template',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
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
                      child: Text(
                        'Live preview',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Text('A4 · first page', style: TextStyle(fontSize: 11.5)),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final scale = ((constraints.maxWidth - 24) / _paperW)
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
                            // Lay the page out at its design size, then scale
                            // it — otherwise narrow screens squeeze it first.
                            child: OverflowBox(
                              alignment: Alignment.topLeft,
                              minWidth: _paperW,
                              maxWidth: _paperW,
                              minHeight: _paperH,
                              maxHeight: _paperH,
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
                      onPressed: _working ? null : () => _share(student.id),
                      icon: _working
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.ios_share),
                      label: Text(
                        _working ? 'Building PDF…' : 'Generate & share',
                      ),
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
final TextStyle _pvInk = TextStyle(color: AppPalette.light.ink, fontSize: 9);
final TextStyle _pvLabel = TextStyle(
  color: AppPalette.light.ink,
  fontSize: 8,
  fontWeight: FontWeight.w700,
);
const TextStyle _pvValue = TextStyle(color: Colors.black, fontSize: 8.5);
const TextStyle _pvStatValue = TextStyle(
  color: Colors.black,
  fontSize: 11,
  fontWeight: FontWeight.w800,
);
const TextStyle _pvScore = TextStyle(
  color: Colors.black,
  fontSize: 18,
  fontWeight: FontWeight.w800,
);
final TextStyle _pvMuted = TextStyle(
  color: AppPalette.light.body,
  fontSize: 7.5,
);
final TextStyle _pvSection = TextStyle(
  color: AppColors.brand,
  fontSize: 10.5,
  fontWeight: FontWeight.w800,
);

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
      label:
          'Live preview: ${template.label} report card for '
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
                        Text(
                          d.schoolName,
                          style: TextStyle(
                            color: AppColors.brand,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(d.schoolMotto, style: _pvMuted),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text(
                        'REPORT CARD',
                        style: TextStyle(
                          color: Colors.black,
                          fontSize: 9,
                          letterSpacing: 1.6,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
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
              Text(
                d.studentName,
                style: TextStyle(
                  color: AppPalette.light.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text('${d.classId} · ${d.admissionNo}', style: _pvMuted),
              const SizedBox(height: 12),
              Row(
                children: [
                  _pvStat('Class', d.classId),
                  _pvStat('Position', d.rankLabel),
                  _pvStat('Attendance', d.attendance?.label ?? '–'),
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
                    child: Text(
                      d.overallGrade,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
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

// --- Ghanaian layouts (terminal report & transcript) -----------------------

const TextStyle _pvGhTh = TextStyle(
  color: Colors.black,
  fontSize: 5.6,
  fontWeight: FontWeight.w800,
);
const TextStyle _pvGhTd = TextStyle(color: Colors.black, fontSize: 6.6);
const TextStyle _pvGhTdBold = TextStyle(
  color: Colors.black,
  fontSize: 6.6,
  fontWeight: FontWeight.w800,
);
final TextStyle _pvGhLabel = TextStyle(
  color: AppPalette.light.ink,
  fontSize: 6.4,
  fontWeight: FontWeight.w700,
);
const TextStyle _pvGhValue = TextStyle(
  color: Colors.black,
  fontSize: 7,
  fontWeight: FontWeight.w700,
);
final TextStyle _pvGhSmall = TextStyle(
  color: AppPalette.light.body,
  fontSize: 5.6,
);
final TextStyle _pvGhSection = TextStyle(
  color: AppColors.brand,
  fontSize: 6.6,
  letterSpacing: 1,
  fontWeight: FontWeight.w800,
);
final BoxDecoration _pvGhDotted = BoxDecoration(
  border: Border(bottom: BorderSide(color: AppPalette.light.body, width: 0.4)),
);
final TableBorder _pvGhGrid = TableBorder.all(color: Colors.black, width: 0.5);

/// Double-ruled frame around a scrollable page body.
Widget _pvGhFrame(List<Widget> children) => Padding(
  padding: const EdgeInsets.all(12),
  child: Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      border: Border.all(color: AppTheme.brand, width: 1.2),
    ),
    child: Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.brand, width: 0.4),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(11, 10, 11, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  ),
);

Widget _pvGhHeader(ReportCardData d, String title) {
  final level = schoolLevelFor(d.classId);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.navy50,
              border: Border.all(color: AppTheme.brand, width: 1),
            ),
            child: Text(
              schoolInitials(d.schoolName),
              style: TextStyle(
                color: AppColors.brand,
                fontSize: 9,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              children: [
                Text(
                  d.schoolName.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.brand,
                    fontSize: 11,
                    letterSpacing: 0.4,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (d.schoolContact.isNotEmpty)
                  Text(
                    d.schoolContact,
                    textAlign: TextAlign.center,
                    style: _pvGhSmall,
                  ),
                if (d.schoolMotto.isNotEmpty)
                  Text(
                    'Motto: ${d.schoolMotto}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppPalette.light.ink,
                      fontSize: 6,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 31,
            height: 37,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: AppPalette.light.border, width: 0.6),
            ),
            child: Text('PHOTO', style: _pvGhSmall),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Container(
        color: AppTheme.brand,
        padding: const EdgeInsets.symmetric(vertical: 3),
        alignment: Alignment.center,
        child: Text(
          level.isEmpty ? title : '$level · $title',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 7.4,
            letterSpacing: 1.6,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      Container(height: 1.5, color: AppTheme.gold),
    ],
  );
}

Widget _pvGhField(String label, String value, {double labelWidth = 0}) =>
    Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (labelWidth > 0)
            SizedBox(
              width: labelWidth,
              child: Text(label, style: _pvGhLabel),
            )
          else
            Text('$label ', style: _pvGhLabel),
          Expanded(
            child: Container(
              padding: const EdgeInsets.only(left: 2, bottom: 1),
              decoration: _pvGhDotted,
              child: Text(value.isEmpty ? ' ' : value, style: _pvGhValue),
            ),
          ),
        ],
      ),
    );

Widget _pvGhPair(String l1, String v1, String l2, String v2) => Row(
  children: [
    Expanded(child: _pvGhField(l1, v1, labelWidth: 54)),
    const SizedBox(width: 10),
    Expanded(child: _pvGhField(l2, v2, labelWidth: 54)),
  ],
);

Widget _pvGhLines(String label, String text, {int lines = 2}) => Padding(
  padding: const EdgeInsets.only(top: 5),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: _pvGhLabel),
      if (text.isNotEmpty)
        Container(
          padding: const EdgeInsets.only(top: 2, bottom: 1),
          decoration: _pvGhDotted,
          child: Text(text, style: _pvGhTd),
        ),
      for (var i = text.isEmpty ? 0 : 1; i < lines; i++)
        Container(height: 11, decoration: _pvGhDotted),
    ],
  ),
);

Widget _pvGhSectionTitle(String text) => Container(
  margin: const EdgeInsets.only(top: 8, bottom: 3),
  padding: const EdgeInsets.only(bottom: 1.5),
  decoration: BoxDecoration(
    border: Border(bottom: BorderSide(color: AppTheme.brand, width: 0.6)),
  ),
  child: Text(text, style: _pvGhSection),
);

Widget _pvGhCell(
  String text, {
  TextStyle style = _pvGhTd,
  TextAlign align = TextAlign.center,
}) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
  child: Text(text, textAlign: align, style: style),
);

Widget _pvGhGradingKey(GradingScheme scheme) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    Text('GRADING SYSTEM', style: _pvGhSection),
    const SizedBox(height: 2),
    Table(
      border: _pvGhGrid,
      children: [
        TableRow(
          children: [
            for (final (i, b) in scheme.bands.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  children: [
                    Text(b.grade, style: _pvGhTdBold),
                    Text(
                      scheme.rangeOf(i),
                      style: _pvGhTh.copyWith(
                        fontWeight: FontWeight.w400,
                        fontSize: 5,
                      ),
                    ),
                    Text(
                      b.remark,
                      textAlign: TextAlign.center,
                      style: _pvGhTh.copyWith(
                        fontWeight: FontWeight.w400,
                        fontSize: 5,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    ),
  ],
);

/// "Progress this year" — the term averages beside the year average, the
/// sum that makes it, the school's rules and the Term 3 decision. Used by
/// the card preview and by the parent / student results screen.
class YearProgressChart extends StatelessWidget {
  const YearProgressChart(this.d, {super.key, this.scale = 1});

  final ReportCardData d;

  /// 1 on the A4 preview; larger on a results screen.
  final double scale;

  @override
  Widget build(BuildContext context) {
    final chartH = 38.0 * scale;
    final labelH = 9.0 * scale;
    final promote = d.scheme.promoteAt ?? d.scheme.repeatBelow;
    final rules = d.scheme.yearRulesLine;
    final small = _pvGhSmall.copyWith(fontSize: 5.6 * scale);
    final body = _pvGhTd.copyWith(fontSize: 6.6 * scale);
    final bold = _pvGhTdBold.copyWith(fontSize: 6.6 * scale);
    final chart = SizedBox(
      width: 150 * scale,
      height: chartH + labelH + 10 * scale,
      child: Stack(
        children: [
          if (promote != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: labelH + chartH * promote / 100,
              child: Container(height: 0.6, color: AppPalette.light.body),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final b in yearBars(d.year))
                Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      b.value == null ? '–' : b.value!.toStringAsFixed(1),
                      style: bold,
                    ),
                    Container(
                      width: 20 * scale,
                      height: b.value == null
                          ? 0.6
                          : (chartH * b.value!.clamp(0, 100) / 100)
                                .clamp(0.6, chartH)
                                .toDouble(),
                      color: b.value == null
                          ? AppPalette.light.border
                          : (b.year ? AppTheme.gold : AppTheme.brand),
                    ),
                    SizedBox(
                      height: labelH,
                      child: Text(b.label, style: small),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
    final explain = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Year total: ${d.year.total!.toStringAsFixed(1)} out of '
          '${d.year.outOf}',
          style: bold,
        ),
        Text('Year average = ${d.year.formula}', style: body),
        Text(
          'Each term counts its average out of 100; the year average is '
          'their mean${promote == null ? '' : ' (line: promotion mark)'}.',
          style: small,
        ),
        if (rules.isNotEmpty) Text(rules, style: small),
        if (d.outcome != null)
          Container(
            margin: EdgeInsets.only(top: 3 * scale),
            padding: EdgeInsets.symmetric(
              horizontal: 5 * scale,
              vertical: 2 * scale,
            ),
            decoration: BoxDecoration(
              border: Border.all(color: AppTheme.brand, width: 0.6),
            ),
            child: Text(
              'END OF YEAR: ${d.outcome!.label.toUpperCase()}'
              '${d.outcome == YearOutcome.promoted && d.promotedTo != null ? ' TO ${d.promotedTo}' : ''}',
              style: bold,
            ),
          ),
        if (d.interventionNeeded)
          Padding(
            padding: EdgeInsets.only(top: 2 * scale),
            child: Text(
              'Parent meeting requested: the year average is below '
              '${d.scheme.interventionBelow!.toStringAsFixed(0)}.',
              style: bold,
            ),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (scale == 1)
          _pvGhSectionTitle('PROGRESS THIS YEAR')
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'This year so far',
              style: const TextStyle(
                color: AppTheme.brand,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        // Side by side on the A4 preview; stacked when scaled up on a phone.
        if (scale == 1)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              chart,
              const SizedBox(width: 8),
              Expanded(child: explain),
            ],
          )
        else ...[
          Center(child: chart),
          const SizedBox(height: 6),
          explain,
        ],
      ],
    );
  }
}

Widget _pvGhSignature(String caption, String name) => Column(
  children: [
    Text(name.isEmpty ? ' ' : name, style: _pvGhTdBold),
    const SizedBox(height: 1.5),
    Container(height: 0.5, color: Colors.black),
    const SizedBox(height: 1.5),
    Text(caption, style: _pvGhSmall),
  ],
);

Widget _pvGhSignatures(
  String left,
  String leftName,
  String right,
  String rightName,
) => Row(
  crossAxisAlignment: CrossAxisAlignment.end,
  children: [
    Expanded(child: _pvGhSignature(left, leftName)),
    const SizedBox(width: 12),
    Expanded(child: _pvGhSignature(right, rightName)),
    const SizedBox(width: 12),
    Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppPalette.light.body, width: 0.5),
      ),
      child: Text(
        'SCHOOL\nSTAMP',
        textAlign: TextAlign.center,
        style: _pvGhSmall,
      ),
    ),
  ],
);

/// Ghanaian (GES) terminal report — mirrors `_terminalPage` in the PDF.
Widget _previewClassic(ReportCardData d) {
  final att = d.attendance;
  return _pvGhFrame([
    _pvGhHeader(d, "PUPIL'S TERMINAL REPORT"),
    const SizedBox(height: 2),
    _pvGhField('Name of pupil:', d.studentName, labelWidth: 54),
    _pvGhPair('Admission No.:', d.admissionNo, 'Class:', d.classId),
    _pvGhPair('Term:', d.termName, 'Academic year:', d.academicYear),
    _pvGhPair(
      'No. on roll:',
      d.rollSize == 0 ? '' : '${d.rollSize}',
      'Position:',
      d.rank == null ? '' : '${d.positionLabel} out of ${d.classSize}',
    ),
    _pvGhPair(
      'Attendance:',
      att == null ? '' : '${att.daysPresent} out of ${att.daysTotal}',
      'Vacation date:',
      longDate(d.vacationDate),
    ),
    _pvGhPair(
      'Next term begins:',
      longDate(d.nextTermBegins),
      d.termNumber == 3 ? 'Promoted to:' : '',
      endOfYearLabel(d),
    ),
    const SizedBox(height: 8),
    Table(
      border: _pvGhGrid,
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: const {
        0: FlexColumnWidth(3.4),
        1: FlexColumnWidth(1.15),
        2: FlexColumnWidth(1.15),
        3: FlexColumnWidth(1.15),
        4: FlexColumnWidth(0.8),
        5: FlexColumnWidth(0.8),
        6: FlexColumnWidth(1.7),
      },
      children: [
        TableRow(
          decoration: BoxDecoration(color: AppTheme.navy100),
          children: [
            _pvGhCell('SUBJECT', style: _pvGhTh, align: TextAlign.left),
            _pvGhCell(
              'CLASS SCORE\n(${weightLabel(d.scheme.classWeight)})',
              style: _pvGhTh,
            ),
            _pvGhCell(
              'EXAM SCORE\n(${weightLabel(d.scheme.examWeight)})',
              style: _pvGhTh,
            ),
            _pvGhCell('TOTAL\n(100%)', style: _pvGhTh),
            _pvGhCell('GRADE', style: _pvGhTh),
            _pvGhCell('POS.', style: _pvGhTh),
            _pvGhCell('REMARKS', style: _pvGhTh),
          ],
        ),
        for (final s in d.subjects)
          TableRow(
            children: [
              _pvGhCell(s.name, align: TextAlign.left),
              _pvGhCell(s.classScoreLabel),
              _pvGhCell(s.examScoreLabel),
              _pvGhCell(s.totalLabel, style: _pvGhTdBold),
              _pvGhCell(s.termGrade ?? '–', style: _pvGhTdBold),
              _pvGhCell(s.positionLabel),
              _pvGhCell(s.termRemark.isEmpty ? '–' : s.termRemark),
            ],
          ),
      ],
    ),
    const SizedBox(height: 3),
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.navy50,
        border: Border.all(color: Colors.black, width: 0.5),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'Total: ${d.totalScore == null ? '–' : '${d.totalScore!.toStringAsFixed(1)} / ${d.gradedSubjects * 100}'}',
            style: _pvGhTdBold,
          ),
          Text('Average: ${d.overallLabel}', style: _pvGhTdBold),
          if (d.scheme.showAggregate)
            Text(
              'Aggregate: ${d.aggregate?.toString() ?? '–'}',
              style: _pvGhTdBold,
            ),
        ],
      ),
    ),
    if (d.hasPartial)
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          '* Only class work or only the exam is recorded; the total is '
          'that score out of 100.',
          style: _pvGhSmall,
        ),
      ),
    if (d.termNumber >= 2 && d.year.average != null) YearProgressChart(d),
    Row(
      children: [
        Expanded(child: _pvGhField('Conduct:', d.conduct)),
        const SizedBox(width: 8),
        Expanded(child: _pvGhField('Attitude:', d.attitude)),
        const SizedBox(width: 8),
        Expanded(child: _pvGhField('Interest:', d.interest)),
      ],
    ),
    Row(
      children: [
        Expanded(
          child: _pvGhField(
            'Fees owing:',
            d.feesOwing == null ? '' : cedis(d.feesOwing!),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _pvGhField(
            "Next term's fees:",
            d.nextTermFees == null ? '' : cedis(d.nextTermFees!),
          ),
        ),
      ],
    ),
    _pvGhLines("Class teacher's remarks:", d.remark),
    _pvGhLines("Headteacher's remarks:", d.headRemark),
    const SizedBox(height: 14),
    _pvGhSignatures(
      "Class teacher's signature",
      d.teacherName,
      "Headteacher's signature",
      d.approvedBy,
    ),
    const SizedBox(height: 8),
    _pvGhGradingKey(d.scheme),
    const SizedBox(height: 6),
    _pvFooter(d),
  ]);
}

/// Ghanaian academic transcript — mirrors `_transcriptPage` in the PDF.
Widget _previewTranscript(ReportCardData d) {
  final names = transcriptSubjects(d);
  final terms = d.history;
  return _pvGhFrame([
    _pvGhHeader(d, 'ACADEMIC TRANSCRIPT'),
    _pvGhSectionTitle("STUDENT'S PARTICULARS"),
    _pvGhField('Name of student:', d.studentName, labelWidth: 54),
    _pvGhPair('Admission No.:', d.admissionNo, 'Gender:', d.gender),
    _pvGhPair(
      'Date of birth:',
      longDate(d.dateOfBirth),
      'Admitted:',
      longDate(d.admissionDate),
    ),
    _pvGhPair('Current class:', d.classId, 'Status:', d.studentStatus),
    _pvGhSectionTitle('ACADEMIC RECORD'),
    Table(
      border: _pvGhGrid,
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: {
        0: const FlexColumnWidth(3.2),
        for (var i = 0; i < terms.length; i++)
          i + 1: const FlexColumnWidth(1.4),
        terms.length + 1: const FlexColumnWidth(1.1),
        terms.length + 2: const FlexColumnWidth(0.8),
        terms.length + 3: const FlexColumnWidth(1.6),
      },
      children: [
        TableRow(
          decoration: BoxDecoration(color: AppTheme.navy100),
          children: [
            _pvGhCell('SUBJECT', style: _pvGhTh, align: TextAlign.left),
            for (final t in terms)
              _pvGhCell(
                t.termLabel.replaceAll(' · ', '\n').toUpperCase(),
                style: _pvGhTh,
              ),
            _pvGhCell('MEAN\nSCORE', style: _pvGhTh),
            _pvGhCell('GRADE', style: _pvGhTh),
            _pvGhCell('REMARKS', style: _pvGhTh),
          ],
        ),
        for (final name in names)
          () {
            final mean = transcriptMean(d, name);
            return TableRow(
              children: [
                _pvGhCell(name, align: TextAlign.left),
                for (final t in terms) _pvGhCell(transcriptCell(t, name)),
                _pvGhCell(
                  mean == null ? '–' : mean.toStringAsFixed(1),
                  style: _pvGhTdBold,
                ),
                _pvGhCell(
                  mean == null ? '–' : d.scheme.bandFor(mean).grade,
                  style: _pvGhTdBold,
                ),
                _pvGhCell(mean == null ? '–' : d.scheme.bandFor(mean).remark),
              ],
            );
          }(),
        for (final row in [
          (
            'Term average',
            (TermRecord t) =>
                t.overall == null ? '–' : '${t.overall!.toStringAsFixed(1)}%',
          ),
          (
            'Position in class',
            (TermRecord t) => t.rank == null || t.classSize == 0
                ? '–'
                : '${ordinal(t.rank!)} / ${t.classSize}',
          ),
          if (d.scheme.showAggregate)
            (
              aggregateLabel(d.scheme),
              (TermRecord t) => t.aggregate?.toString() ?? '–',
            ),
        ])
          TableRow(
            decoration: BoxDecoration(color: AppTheme.navy50),
            children: [
              _pvGhCell(row.$1, style: _pvGhTdBold, align: TextAlign.left),
              for (final t in terms) _pvGhCell(row.$2(t), style: _pvGhTdBold),
              _pvGhCell(''),
              _pvGhCell(''),
              _pvGhCell(''),
            ],
          ),
      ],
    ),
    _pvGhSectionTitle('CONDUCT AND REMARKS'),
    _pvGhField('General conduct:', '', labelWidth: 54),
    _pvGhField('Extra-curricular:', '', labelWidth: 54),
    _pvGhLines("Headteacher's remarks:", ''),
    const SizedBox(height: 8),
    _pvGhGradingKey(d.scheme),
    _pvGhSectionTitle('CERTIFICATION'),
    Text(
      'This is to certify that the above is a true and accurate record of '
      'the academic performance of ${d.studentName} at ${d.schoolName}.',
      style: _pvGhTd,
    ),
    const SizedBox(height: 16),
    _pvGhSignatures(
      "Headteacher's signature",
      '',
      'Date issued',
      longDate(d.generatedAt.toIso8601String().substring(0, 10)),
    ),
    const SizedBox(height: 5),
    Text(
      "Not valid without the school's official stamp and the headteacher's "
      'signature.',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: AppPalette.light.ink,
        fontSize: 5.8,
        fontStyle: FontStyle.italic,
      ),
    ),
    const SizedBox(height: 4),
    _pvFooter(d),
  ]);
}

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

Widget _pvFooter(ReportCardData d) => Text(
  '${approvalLine(d)} · Generated by SOLVANTA · ${d.schoolName}',
  textAlign: TextAlign.center,
  style: _pvMuted,
);

/// Navy-only progress bar — one navy ramp, never traffic lights.
Widget _pvBar(double? average) {
  final filled = average == null
      ? 0.0
      : average.clamp(0, 100).toDouble() / 100 * 80;
  return Container(
    width: 80,
    height: 6,
    color: AppTheme.navy100,
    child: Align(
      alignment: Alignment.centerLeft,
      child: Container(width: filled, height: 6, color: AppTheme.brand),
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
        child: Text(
          s.averageLabel,
          textAlign: TextAlign.right,
          style: _pvValue,
        ),
      ),
      const SizedBox(width: 6),
      SizedBox(
        width: 18,
        child: Text(
          s.grade,
          textAlign: TextAlign.right,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    ],
  ),
);

// ---------------------------------------------------------------------------
// Supporting types
// ---------------------------------------------------------------------------

/// The selected pupil's report: draft or approved, and what this user may
/// do with it.
class _ReportStatusBar extends StatelessWidget {
  const _ReportStatusBar({
    required this.report,
    required this.canWrite,
    required this.leader,
    required this.busy,
    required this.onRemarks,
    required this.onApprove,
    required this.onReopen,
  });

  final TermReport report;
  final bool canWrite;
  final bool leader;
  final bool busy;
  final VoidCallback onRemarks;
  final VoidCallback onApprove;
  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) {
    final approved = report.approved;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Chip(
            avatar: Icon(
              approved ? Icons.verified : Icons.edit_note,
              size: 18,
              color: AppColors.brand,
            ),
            label: Text(
              approved
                  ? 'Approved${report.approvedBy.isEmpty ? '' : ' by ${report.approvedBy}'}'
                  : 'Draft',
            ),
          ),
          if (canWrite)
            OutlinedButton.icon(
              onPressed: busy ? null : onRemarks,
              icon: const Icon(Icons.rate_review_outlined, size: 18),
              label: const Text('Remarks'),
            ),
          if (leader && !approved)
            FilledButton.icon(
              onPressed: busy ? null : onApprove,
              icon: const Icon(Icons.verified_outlined, size: 18),
              label: const Text('Approve'),
            ),
          if (leader && approved)
            OutlinedButton.icon(
              onPressed: busy ? null : onReopen,
              icon: const Icon(Icons.lock_open, size: 18),
              label: const Text('Reopen'),
            ),
        ],
      ),
    );
  }
}

/// The class teacher's remark and assessment of the pupil, and — for school
/// leaders — the headteacher's remark. Starts from the generated remark so
/// the teacher edits rather than writes from scratch.
class _RemarksSheet extends StatefulWidget {
  const _RemarksSheet({
    required this.report,
    required this.studentName,
    required this.draftRemark,
    required this.leader,
  });

  final TermReport report;
  final String studentName;
  final String draftRemark;
  final bool leader;

  @override
  State<_RemarksSheet> createState() => _RemarksSheetState();
}

class _RemarksSheetState extends State<_RemarksSheet> {
  late final _remark = TextEditingController(
    text: widget.report.teacherRemark.isNotEmpty
        ? widget.report.teacherRemark
        : widget.draftRemark,
  );
  late final _head = TextEditingController(text: widget.report.headRemark);
  late String _conduct = widget.report.conduct;
  late String _attitude = widget.report.attitude;
  late String _interest = widget.report.interest;

  @override
  void dispose() {
    _remark.dispose();
    _head.dispose();
    super.dispose();
  }

  Widget _rating(String label, String value, ValueChanged<String> onChanged) {
    final options = {...TermReport.ratings, if (value.isNotEmpty) value};
    return DropdownButtonFormField<String>(
      initialValue: value.isEmpty ? null : value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        for (final o in options) DropdownMenuItem(value: o, child: Text(o)),
      ],
      onChanged: (v) => onChanged(v ?? ''),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Remarks for ${widget.studentName}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _remark,
              maxLines: 4,
              maxLength: 600,
              decoration: const InputDecoration(
                labelText: "Class teacher's remark",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            _rating('Conduct', _conduct, (v) => setState(() => _conduct = v)),
            const SizedBox(height: 10),
            _rating(
              'Attitude',
              _attitude,
              (v) => setState(() => _attitude = v),
            ),
            const SizedBox(height: 10),
            _rating(
              'Interest',
              _interest,
              (v) => setState(() => _interest = v),
            ),
            if (widget.leader) ...[
              const SizedBox(height: 14),
              TextField(
                controller: _head,
                maxLines: 3,
                maxLength: 600,
                decoration: const InputDecoration(
                  labelText: "Headteacher's remark",
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                widget.report.copyWith(
                  teacherRemark: _remark.text.trim(),
                  conduct: _conduct,
                  attitude: _attitude,
                  interest: _interest,
                  headRemark: widget.leader ? _head.text.trim() : null,
                ),
              ),
              child: const Text('Save remarks'),
            ),
          ],
        ),
      ),
    );
  }
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
