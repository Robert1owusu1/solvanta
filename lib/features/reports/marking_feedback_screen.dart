import 'package:flutter/material.dart';

import '../../core/models/class_room.dart';
import '../../core/models/marking_feedback.dart';
import '../../core/models/role.dart';
import '../../core/models/subjects.dart';
import '../../core/models/user.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'marking_feedback_repository.dart';

// =============================================================================
// Feedback reports — Phase 7. Read-only views of finalized marks.
// =============================================================================

String _fmt(double v) =>
    v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');

String _date(String iso) => iso.length >= 10 ? iso.substring(0, 10) : iso;

/// A note under a report saying when it was read, and whether this is the
/// copy kept on the device because the server could not be reached.
class _Freshness extends StatelessWidget {
  const _Freshness(this.result);
  final FeedbackResult<Object?> result;

  @override
  Widget build(BuildContext context) {
    final when = result.fetchedAt.isEmpty ? '' : _date(result.fetchedAt);
    final text = result.fromCache
        ? 'Offline — showing the copy saved on this device${when.isEmpty ? '' : ' on $when'}.'
        : 'Only marks a teacher has reviewed and finalized are included.';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(result.fromCache ? Icons.cloud_off : Icons.verified_outlined,
              size: 16, color: result.fromCache ? AppColors.warning : AppColors.muted),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: AppColors.muted))),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Per student
// -----------------------------------------------------------------------------

/// A student's feedback: for each finalized paper, the questions that lost
/// marks, the likely misconception where the scheme knows it, and a next step.
class StudentFeedbackView extends StatefulWidget {
  const StudentFeedbackView({
    super.key,
    required this.studentId,
    this.title = 'Marking feedback',
    this.showAppBar = true,
  });

  final String studentId;
  final String title;
  final bool showAppBar;

  @override
  State<StudentFeedbackView> createState() => _StudentFeedbackViewState();
}

class _StudentFeedbackViewState extends State<StudentFeedbackView> {
  late Future<FeedbackResult<StudentFeedback>> _data = _load();

  Future<FeedbackResult<StudentFeedback>> _load() async {
    final me = await AuthRepository().currentUser();
    if (me == null) return const FeedbackResult(error: 'Not signed in');
    return MarkingFeedbackRepository().student(me.id, widget.studentId);
  }

  @override
  void didUpdateWidget(StudentFeedbackView old) {
    super.didUpdateWidget(old);
    if (old.studentId != widget.studentId) _data = _load();
  }

  @override
  Widget build(BuildContext context) {
    final body = FutureBuilder<FeedbackResult<StudentFeedback>>(
      future: _data,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SvListSkeleton(avatar: false);
        }
        final res = snap.data;
        final f = res?.data;
        if (res == null || f == null) {
          return SvErrorState(
            title: "Couldn't load feedback",
            message: res?.error ?? 'Please try again.',
            onRetry: () => setState(() => _data = _load()),
          );
        }
        if (f.papers.isEmpty) {
          return const SvEmptyState(
            icon: Icons.fact_check_outlined,
            title: 'No marked papers yet',
            message: 'Feedback appears here once a teacher has reviewed and finalized the marks.',
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            final next = _load();
            setState(() => _data = next);
            await next;
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _Freshness(res),
              if (f.studentName.isNotEmpty)
                Text(f.studentName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                '${f.papers.length} marked paper${f.papers.length == 1 ? '' : 's'} · '
                '${f.wrongQuestions} question${f.wrongQuestions == 1 ? '' : 's'} to work on',
                style: TextStyle(color: AppColors.muted),
              ),
              if (f.misconceptions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Misconceptions seen', style: TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        for (final c in f.misconceptions)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text('• ${c.cause}${c.count > 1 ? ' (×${c.count})' : ''}'),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              for (final p in f.papers) _PaperCard(p),
            ],
          ),
        );
      },
    );
    if (!widget.showAppBar) return body;
    return Scaffold(appBar: AppBar(title: Text(widget.title)), body: body);
  }
}

class _PaperCard extends StatelessWidget {
  const _PaperCard(this.p);
  final FeedbackPaper p;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                      Text(
                        [
                          if (p.subjectId.isNotEmpty) subjectName(p.subjectId),
                          p.targetKind == 'assignment' ? 'Assignment' : 'Assessment',
                          if (p.finalizedAt.isNotEmpty) 'marked ${_date(p.finalizedAt)}',
                        ].join(' · '),
                        style: TextStyle(fontSize: 12, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text('${_fmt(p.marks)}/${_fmt(p.total)}',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: AppColors.brand)),
                const SizedBox(width: 6),
                Text(p.grade, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              ],
            ),
            const SizedBox(height: 6),
            Text('Full marks on ${p.fullMarks} of ${p.questionCount} questions',
                style: const TextStyle(fontSize: 13)),
            if (p.wrong.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Every question got full marks.',
                    style: TextStyle(color: AppColors.success, fontWeight: FontWeight.w600)),
              ),
            for (final q in p.wrong) _WrongQuestion(q),
          ],
        ),
      ),
    );
  }
}

class _WrongQuestion extends StatelessWidget {
  const _WrongQuestion(this.q);
  final FeedbackQuestion q;

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(fontSize: 12, color: AppColors.muted);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: q.marks == 0 ? AppColors.incorrect : AppColors.warning, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Question ${q.questionNumber}${q.topic.isEmpty ? '' : ' · ${q.topic}'}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text('${_fmt(q.marks)}/${_fmt(q.totalMarks)}', style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          Text(q.blank ? 'Left blank' : 'Answer: ${q.studentAnswer}', style: muted),
          if (q.likelyMisconception.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text.rich(TextSpan(children: [
              const TextSpan(text: 'Likely misconception: ', style: TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: q.likelyMisconception),
            ])),
          ],
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.arrow_forward, size: 16, color: AppColors.brand),
              const SizedBox(width: 4),
              Expanded(child: Text(q.nextStep, style: TextStyle(color: AppColors.brand))),
            ],
          ),
          if (q.teacherNote.isNotEmpty) Text("Marker's note: ${q.teacherNote}", style: muted),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Per class
// -----------------------------------------------------------------------------

/// The staff entry point: the class aggregate, with each student's own
/// report one tap away. A teacher sees their own class; leaders pick one.
class MarkingFeedbackScreen extends StatefulWidget {
  const MarkingFeedbackScreen({super.key});

  @override
  State<MarkingFeedbackScreen> createState() => _MarkingFeedbackScreenState();
}

class _MarkingFeedbackScreenState extends State<MarkingFeedbackScreen> {
  late final Future<(User?, List<ClassRoom>)> _setup = _loadSetup();
  Future<FeedbackResult<ClassFeedback>>? _report;
  String? _classId;
  User? _me;

  Future<(User?, List<ClassRoom>)> _loadSetup() async {
    final me = await AuthRepository().currentUser();
    final classes = await StudentsRepository().classes();
    _me = me;
    if (me != null) {
      _classId = me.role == AppRole.teacher ? me.classId : (classes.isEmpty ? null : classes.first.id);
      if (_classId != null) _report = _loadReport();
    }
    return (me, classes);
  }

  Future<FeedbackResult<ClassFeedback>> _loadReport() =>
      MarkingFeedbackRepository().forClass(_me!.id, _classId!);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Marking feedback')),
      body: FutureBuilder(
        future: _setup,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SvListSkeleton(avatar: false);
          }
          final (me, classes) = snap.data ?? (null, const <ClassRoom>[]);
          if (me == null) return const Center(child: Text('Not signed in'));
          if (_classId == null) {
            return const SvEmptyState(
              icon: Icons.class_outlined,
              title: 'No class',
              message: 'Class feedback needs a class to report on.',
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (me.role != AppRole.teacher && classes.length > 1) ...[
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _classId,
                  decoration: const InputDecoration(labelText: 'Class', border: OutlineInputBorder()),
                  items: [
                    for (final c in classes)
                      DropdownMenuItem(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() {
                    _classId = v;
                    _report = _loadReport();
                  }),
                ),
                const SizedBox(height: 12),
              ],
              FutureBuilder<FeedbackResult<ClassFeedback>>(
                future: _report,
                builder: (context, rs) {
                  if (rs.connectionState != ConnectionState.done) {
                    return const Padding(padding: EdgeInsets.all(24), child: SvLoading());
                  }
                  final res = rs.data;
                  final f = res?.data;
                  if (res == null || f == null) {
                    return SvErrorState(
                      title: "Couldn't load class feedback",
                      message: res?.error ?? 'Please try again.',
                      onRetry: () => setState(() => _report = _loadReport()),
                    );
                  }
                  return _ClassReport(res, f);
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ClassReport extends StatelessWidget {
  const _ClassReport(this.res, this.f);
  final FeedbackResult<ClassFeedback> res;
  final ClassFeedback f;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Freshness(res),
        if (f.awaitingReview > 0)
          Card(
            color: AppColors.warning.withValues(alpha: .08),
            child: ListTile(
              leading: Icon(Icons.pending_actions, color: AppColors.warning),
              title: Text('${f.awaitingReview} paper${f.awaitingReview == 1 ? '' : 's'} still awaiting review'),
              subtitle: const Text('They are left out until a teacher finalizes the marks.'),
            ),
          ),
        if (f.reports.isEmpty)
          const SvEmptyState(
            icon: Icons.fact_check_outlined,
            title: 'No finalized marking yet',
            message: 'Class feedback appears once papers have been reviewed and finalized.',
          ),
        for (final r in f.reports) _SchemeReport(r, f.struggleThreshold),
      ],
    );
  }
}

class _SchemeReport extends StatelessWidget {
  const _SchemeReport(this.r, this.threshold);
  final ClassPaperReport r;
  final double threshold;

  @override
  Widget build(BuildContext context) {
    final hardest = [for (final n in r.hardest) r.question(n)].whereType<ClassQuestionStat>().toList();
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            Text(
              [
                if (r.subjectId.isNotEmpty) subjectName(r.subjectId),
                '${r.papers} paper${r.papers == 1 ? '' : 's'}',
                'average ${r.averagePercent.toStringAsFixed(0)}%',
                'scheme v${r.schemeVersion}',
                if (r.awaitingReview > 0) '${r.awaitingReview} awaiting review',
              ].join(' · '),
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
            const SizedBox(height: 10),
            if (hardest.isEmpty)
              Text('No question averaged below ${threshold.toStringAsFixed(0)}%.',
                  style: TextStyle(color: AppColors.success, fontWeight: FontWeight.w600))
            else
              Text(
                'Struggled with: ${hardest.map((q) => 'Q${q.questionNumber} (${q.averagePercent.toStringAsFixed(0)}%)').join(', ')}',
                style: TextStyle(color: AppColors.incorrect, fontWeight: FontWeight.w700),
              ),
            const SizedBox(height: 6),
            for (final q in r.questions) _QuestionRow(q),
          ],
        ),
      ),
    );
  }
}

class _QuestionRow extends StatelessWidget {
  const _QuestionRow(this.q);
  final ClassQuestionStat q;

  @override
  Widget build(BuildContext context) {
    final colour = q.struggled ? AppColors.incorrect : AppColors.success;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Row(
          children: [
            Expanded(
              child: Text('Q${q.questionNumber}${q.topic.isEmpty ? '' : ' · ${q.topic}'}',
                  overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            Text('${_fmt(q.averageMarks)}/${_fmt(q.totalMarks)}',
                style: TextStyle(fontWeight: FontWeight.w700, color: colour)),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: LinearProgressIndicator(
            value: (q.averagePercent / 100).clamp(0, 1),
            color: colour,
            backgroundColor: colour.withValues(alpha: .15),
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${q.fullMarks} of ${q.papers} got full marks · ${q.zero} scored 0'
              '${q.blank > 0 ? ' · ${q.blank} left it blank' : ''}'),
          for (final c in q.misconceptions)
            Text('• ${c.cause} (${c.count})', style: const TextStyle(fontSize: 13)),
          if (q.belowFull.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in q.belowFull)
                  ActionChip(
                    label: Text('${s.name} ${_fmt(s.marks)}'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => StudentFeedbackView(studentId: s.studentId, title: s.name),
                    )),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
