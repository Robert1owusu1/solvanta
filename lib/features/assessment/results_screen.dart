import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/submission.dart';
import '../../core/models/subjects.dart';
import '../../core/theme/app_theme.dart';
import '../reports/marking_feedback_screen.dart';
import '../reports/report_card_pdf.dart';
import '../reports/report_card_screen.dart' show YearProgressChart;
import '../reports/report_card_source.dart';
import '../reports/parent_meetings_repository.dart';
import '../reports/term_reports_repository.dart';
import '../../core/models/parent_meeting.dart';
import '../../core/models/term_report.dart';
import '../../core/platform/file_share.dart';
import 'assessment_repository.dart';
import 'feedback_screen.dart';

class ResultsScreen extends StatefulWidget {
  const ResultsScreen({
    super.key,
    required this.studentId,
    this.title,
    this.showAppBar = true,
  });

  final String studentId;
  final String? title;
  final bool showAppBar;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  late Future<List<({Assessment assessment, AssessmentSubmission? submission})>>
      _data;

  /// This term's card — its year chart shows from Term 2 on.
  late final Future<ReportCardData?> _card = ReportCardSource.load()
      .then((s) => s.cardForId(widget.studentId))
      .catchError((_) => null);

  @override
  void initState() {
    super.initState();
    _data = AssessmentRepository().resultsForStudent(widget.studentId);
  }

  /// Report cards the school has approved — released to the family.
  late final Future<List<TermReport>> _released =
      TermReportsRepository().approvedFor(widget.studentId);

  Future<void> _openReport(TermReport r) async {
    try {
      final card = ReportCardData.fromJson(r.snapshot!).copyWithJson({
        'approvedBy': r.approvedBy.isEmpty ? 'the school' : r.approvedBy,
        'approvedAt': r.approvedAt,
      });
      final bytes =
          await buildReportCardPdf(card, ReportCardTemplate.classic);
      await saveAndShareFile(
        bytes,
        'report_${r.id}.pdf',
        'application/pdf',
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Couldn't open the report card.")));
      }
    }
  }

  Widget _reportCards() => FutureBuilder<List<TermReport>>(
        future: _released,
        builder: (context, snap) {
          final reports = snap.data ?? const <TermReport>[];
          if (reports.isEmpty) return const SizedBox.shrink();
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
                  child: Text('Report cards',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                ),
                for (final r in reports)
                  ListTile(
                    leading: Icon(Icons.workspace_premium_outlined,
                        color: AppColors.brand),
                    title: Text('${r.term} · ${r.year}'),
                    subtitle: Text(r.approvedBy.isEmpty
                        ? 'Approved by the school'
                        : 'Approved by ${r.approvedBy}'),
                    trailing: const Icon(Icons.picture_as_pdf_outlined),
                    onTap: () => _openReport(r),
                  ),
              ],
            ),
          );
        },
      );

  /// Meetings the school has booked (or held) with this family.
  late final Future<List<ParentMeeting>> _meetings =
      ParentMeetingsRepository().forStudent(widget.studentId);

  Widget _meetingsCard() => FutureBuilder<List<ParentMeeting>>(
        future: _meetings,
        builder: (context, snap) {
          final shown = [
            for (final m in snap.data ?? const <ParentMeeting>[])
              if (m.status == MeetingStatus.scheduled ||
                  m.status == MeetingStatus.held)
                m,
          ];
          if (shown.isEmpty) return const SizedBox.shrink();
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
                  child: Text('Meetings with the school',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                ),
                for (final m in shown)
                  ListTile(
                    leading: Icon(Icons.event_available_outlined,
                        color: AppColors.brand),
                    title: Text(m.status == MeetingStatus.held
                        ? 'Held · ${m.scheduledFor}'
                        : '${m.scheduledFor}${m.place.isEmpty ? '' : ' · ${m.place}'}'),
                    subtitle: Text(m.status == MeetingStatus.held &&
                            m.outcome.isNotEmpty
                        ? 'Agreed: ${m.outcome}'
                        : m.reason),
                  ),
              ],
            ),
          );
        },
      );

  /// "This year so far": the term averages, how the year average is worked
  /// out, and — on Term 3 — the promotion decision. Hidden on Term 1.
  Widget _yearCard() => FutureBuilder<ReportCardData?>(
        future: _card,
        builder: (context, snap) {
          final card = snap.data;
          if (card == null ||
              card.termNumber < 2 ||
              card.year.average == null) {
            return const SizedBox.shrink();
          }
          // The chart is drawn in print colours, so it sits on paper white
          // in dark mode too.
          return Card(
            color: AppPalette.light.surface,
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: YearProgressChart(card, scale: 1.8),
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.showAppBar
          ? AppBar(title: Text(widget.title ?? 'Results'))
          : null,
      // Phase 7: what to work on next, from marks a teacher finalized.
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'marking-feedback-${widget.studentId}',
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => StudentFeedbackView(studentId: widget.studentId),
        )),
        icon: const Icon(Icons.fact_check_outlined),
        label: const Text('Marking feedback'),
      ),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snap.data;
          if (rows == null || rows.isEmpty) {
            return const Center(child: Text('No assessments found'));
          }
          return ListView.builder(
            // Room at the bottom so the last card clears the button.
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
            itemCount: rows.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Column(
                    children: [_meetingsCard(), _reportCards(), _yearCard()]);
              }
              final i = index - 1;
              final a = rows[i].assessment;
              final s = rows[i].submission;
              final total = a.totalMarks;
              final pct = total == 0
                  ? 0
                  : ((s?.earned ?? 0) / total * 100).round();
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 5),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: AppTheme.accent.withValues(alpha: .1),
                    child: Text(
                      s == null ? '—' : '$pct%',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: .w800,
                          color: s == null ? AppColors.muted : AppTheme.accent),
                    ),
                  ),
                  title: Text(a.title,
                      style: const TextStyle(fontWeight: .w600)),
                  subtitle: Text(
                      '${a.type.label} · ${subjectName(a.subjectId)}'
                      '${s == null ? '\nPending — not yet marked' : '\n${s.earned.toStringAsFixed(1)} / ${total.toStringAsFixed(1)} marks'}'),
                  trailing: s == null
                      ? Icon(Icons.schedule, color: AppColors.muted)
                      : Icon(Icons.emoji_events,
                          color: pct >= 50
                              ? AppTheme.gold
                              : AppColors.notAttempted),
                  onTap: s == null
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => FeedbackScreen(
                                studentId: widget.studentId,
                                assessmentId: a.id,
                              ),
                            ),
                          ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}