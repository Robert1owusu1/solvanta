import 'package:flutter/material.dart';

import '../../core/models/marking_draft.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../students/students_repository.dart';
import 'marking_drafts_repository.dart';
import 'new_draft_screen.dart';

String _marks(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(2).replaceAll(RegExp(r'0$'), '');
}

/// What each matching method means, in a teacher's words.
String methodLabel(String method) => switch (method) {
      'exact' => 'Exact match',
      'normalized' => 'Match (spacing/case ignored)',
      'numeric' => 'Same number',
      'equivalent_form' => 'Same value, different form',
      'unit_mismatch' => 'Unit missing or different',
      'rounded' => 'Rounded answer',
      'misconception' => 'Known wrong answer',
      'none' => 'Not in the scheme',
      'blank' => 'No answer found',
      _ => method,
    };

/// Drafts waiting for a teacher (Phase 6): the entry point to reviewing what
/// the matching engine proposed.
class DraftReviewQueueScreen extends StatefulWidget {
  const DraftReviewQueueScreen({super.key});

  @override
  State<DraftReviewQueueScreen> createState() => _DraftReviewQueueScreenState();
}

class _DraftReviewQueueScreenState extends State<DraftReviewQueueScreen> {
  late Future<(List<MarkingDraft>, Map<String, String>)> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(List<MarkingDraft>, Map<String, String>)> _load() async {
    final drafts = await MarkingDraftsRepository().reviewQueue();
    final names = {
      for (final s in await StudentsRepository().all()) s.id: s.fullName,
    };
    return (drafts, names);
  }

  void _reload() => setState(() { _data = _load(); });

  Future<void> _newDraft() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const NewDraftScreen()),
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'AI Marking Review'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newDraft,
        icon: const Icon(Icons.auto_fix_high),
        label: const Text('Draft marks'),
      ),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SvLoading(message: 'Loading drafts…');
          }
          if (snap.hasError) {
            return SvErrorState(message: "Couldn't load drafts", onRetry: _reload);
          }
          final (drafts, names) = snap.data!;
          if (drafts.isEmpty) {
            return SvEmptyState(
              icon: Icons.fact_check_outlined,
              title: 'Nothing to review',
              message: 'Drafted papers wait here until you finalize their marks.',
              actionLabel: 'Draft marks',
              onAction: _newDraft,
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: drafts.length,
              itemBuilder: (context, i) {
                final d = drafts[i];
                final flagged = d.needsReview;
                return SvAvatarTile(
                  title: names[d.studentId] ?? d.studentId,
                  meta: '${d.targetKind == 'assignment' ? 'Assignment' : 'Assessment'} · '
                      'draft ${_marks(d.draftTotal)}/${_marks(d.maxTotal)}',
                  icon: Icons.assignment_ind,
                  trailing: flagged > 0
                      ? SvStatusBadge(
                          label: '$flagged to check',
                          icon: Icons.flag,
                          color: AppColors.needsReview,
                        )
                      : SvStatusBadge(
                          label: 'Ready',
                          icon: Icons.check_circle,
                          color: AppColors.correct,
                        ),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => DraftReviewScreen(
                        draftId: d.id,
                        studentName: names[d.studentId] ?? d.studentId,
                      ),
                    ));
                    _reload();
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// One paper's draft: what the system read, the mark it proposes and why,
/// and the teacher's decision for each question. Finalizing is an explicit,
/// confirmed action; until then nothing is recorded.
class DraftReviewScreen extends StatefulWidget {
  const DraftReviewScreen({super.key, required this.draftId, required this.studentName});

  final String draftId;
  final String studentName;

  @override
  State<DraftReviewScreen> createState() => _DraftReviewScreenState();
}

class _DraftReviewScreenState extends State<DraftReviewScreen> {
  final _repo = MarkingDraftsRepository();
  MarkingDraft? _draft;
  Map<String, DraftDecision> _decisions = {};
  final Map<String, TextEditingController> _markFields = {};
  final Map<String, TextEditingController> _noteFields = {};
  bool _loading = true;
  bool _working = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [..._markFields.values, ..._noteFields.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final draft = await _repo.load(widget.draftId);
    final decisions = draft == null ? <String, DraftDecision>{} : await _repo.decisionsFor(draft.id);
    if (!mounted) return;
    setState(() {
      _draft = draft;
      _decisions = decisions;
      _loading = false;
      if (draft != null) {
        for (final a in draft.answers) {
          final shown = draft.isFinal ? a.finalMarks : decisions[a.schemeQuestionId]?.marks;
          _markFields[a.schemeQuestionId] =
              TextEditingController(text: shown == null ? '' : _marks(shown));
          _noteFields[a.schemeQuestionId] = TextEditingController(
              text: draft.isFinal ? a.teacherNote : (decisions[a.schemeQuestionId]?.note ?? ''));
        }
      }
    });
  }

  Future<void> _update(String id, DraftDecision Function(DraftDecision) change) async {
    final next = Map<String, DraftDecision>.from(_decisions);
    next[id] = change(next[id] ?? const DraftDecision());
    setState(() => _decisions = next);
    await _repo.saveDecisions(_draft!.id, next); // local first, on every change
  }

  Future<void> _acceptConfident() async {
    final next = acceptConfident(_draft!, _decisions);
    for (final a in _draft!.answers) {
      final m = next[a.schemeQuestionId]?.marks;
      if (m != null) _markFields[a.schemeQuestionId]!.text = _marks(m);
    }
    setState(() => _decisions = next);
    await _repo.saveDecisions(_draft!.id, next);
  }

  Future<void> _finalize() async {
    final draft = _draft!;
    final total = draft.answers.fold<double>(
        0, (sum, a) => sum + (_decisions[a.schemeQuestionId]?.marks ?? 0));
    final changed = draft.answers
        .where((a) => _decisions[a.schemeQuestionId]?.marks != a.draftMarks)
        .length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Finalize these marks?'),
        content: Text(
          '${widget.studentName}: ${_marks(total)} / ${_marks(draft.maxTotal)}.\n'
          '$changed of ${draft.answers.length} marks differ from the draft.\n\n'
          'This records the marks for this paper and tells the parent.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Finalize')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _working = true;
      _error = '';
    });
    try {
      final done = await _repo.finalize(draft, _decisions);
      if (!mounted) return;
      setState(() => _draft = done);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Marks recorded: ${_marks(done.finalTotal)} / ${_marks(done.maxTotal)}')),
      );
    } on FinalizeException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    return Scaffold(
      appBar: AppBar(title: Text(widget.studentName)),
      body: _loading
          ? const SvLoading(message: 'Loading draft…')
          : draft == null
              ? SvErrorState(message: 'This draft is not on this device and the server could not be reached.', onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
                  children: [
                    _summary(draft),
                    if (draft.unassigned.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _unassigned(draft),
                    ],
                    const SizedBox(height: 12),
                    for (final a in draft.answers) ...[
                      _questionCard(draft, a),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
      bottomNavigationBar: draft == null || draft.isFinal ? null : _actions(draft),
    );
  }

  Widget _summary(MarkingDraft draft) {
    final total = draft.isFinal
        ? draft.finalTotal
        : draft.answers.fold<double>(0, (s, a) => s + (_decisions[a.schemeQuestionId]?.marks ?? 0));
    return _notice(
      draft.isFinal ? Icons.verified : Icons.edit_note,
      draft.isFinal ? AppColors.success : AppColors.info,
      draft.isFinal
          ? 'Finalized: ${_marks(draft.finalTotal)} / ${_marks(draft.maxTotal)}'
          : 'Draft — not recorded until you finalize',
      draft.isFinal
          ? 'These marks are recorded. The system proposed ${_marks(draft.draftTotal)}.'
          : 'The system proposes ${_marks(draft.draftTotal)} / ${_marks(draft.maxTotal)}. '
              'Your marks so far: ${_marks(total)}. '
              '${draft.needsReview} question(s) flagged for you to check.',
    );
  }

  Widget _unassigned(MarkingDraft draft) => _notice(
        Icons.help_outline,
        AppColors.warning,
        'Text not matched to any question',
        draft.unassigned.join('\n'),
      );

  Widget _questionCard(MarkingDraft draft, MarkingDraftAnswer a) {
    final id = a.schemeQuestionId;
    final d = _decisions[id] ?? const DraftDecision();
    final flagged = a.needsReview;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Question ${a.questionNumber}',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                flagged
                    ? SvStatusBadge(label: 'Check this', icon: Icons.flag, color: AppColors.needsReview)
                    : SvStatusBadge(label: methodLabel(a.method), icon: Icons.check_circle, color: AppColors.correct),
                Text('Proposed ${_marks(a.draftMarks)} / ${_marks(a.totalMarks)}',
                    style: TextStyle(color: AppColors.muted, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 10),
            Text('What was read', style: TextStyle(fontSize: 11, color: AppColors.muted)),
            Text(a.studentAnswer.isEmpty ? '(no answer found)' : a.studentAnswer,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            if (a.working.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Working', style: TextStyle(fontSize: 11, color: AppColors.muted)),
              for (final w in a.working) Text(w, style: const TextStyle(fontSize: 13)),
            ],
            const SizedBox(height: 10),
            Text('Why', style: TextStyle(fontSize: 11, color: AppColors.muted)),
            if (flagged) Text(methodLabel(a.method), style: const TextStyle(fontWeight: FontWeight.w600)),
            for (final r in a.reasons)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('• $r', style: const TextStyle(fontSize: 13)),
              ),
            if (a.likelyCause.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Likely cause: ${a.likelyCause}',
                    style: TextStyle(fontSize: 13, color: AppColors.warning, fontWeight: FontWeight.w600)),
              ),
            if (a.steps.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Mark breakdown', style: TextStyle(fontSize: 11, color: AppColors.muted)),
              for (final s in a.steps)
                Text(
                  '${s.criteria.isEmpty ? s.type : s.criteria}: '
                  '${s.status == 'awarded' ? _marks(s.awarded) : '–'} / ${_marks(s.marks)}'
                  '${s.status == 'needs_review' ? ' (your judgement)' : s.status == 'set_by_answer' ? ' (set by the answer)' : ''}',
                  style: const TextStyle(fontSize: 13),
                ),
            ],
            const Divider(height: 22),
            if (draft.isFinal)
              Text(
                'Recorded: ${_marks(a.finalMarks ?? 0)} / ${_marks(a.totalMarks)}'
                '${a.overridden ? ' (changed from ${_marks(a.draftMarks)})' : ''}'
                '${a.teacherNote.isEmpty ? '' : '\n${a.teacherNote}'}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              )
            else ...[
              TextField(
                controller: _markFields[id],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Your mark',
                  suffixText: '/ ${_marks(a.totalMarks)}',
                  helperText: 'Proposed: ${_marks(a.draftMarks)}',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) {
                  final m = double.tryParse(v.trim());
                  _update(id, (d) => m == null ? d.copyWith(clearMarks: true) : d.copyWith(marks: m));
                },
              ),
              if (d.marks != null && d.marks != a.draftMarks) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _noteFields[id],
                  decoration: const InputDecoration(
                    labelText: 'Why you changed it (optional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => _update(id, (d) => d.copyWith(note: v)),
                ),
              ],
              if (flagged)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: d.checked,
                  title: const Text("I've checked this question"),
                  onChanged: (v) => _update(id, (d) => d.copyWith(checked: v ?? false)),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _actions(MarkingDraft draft) {
    final blocker = reviewBlocker(draft, _decisions);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(_error, style: TextStyle(color: AppColors.danger, fontSize: 12.5)),
              )
            else if (blocker != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(blocker, style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _working ? null : _acceptConfident,
                    child: const Text('Accept confident', overflow: TextOverflow.ellipsis),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _working || blocker != null ? null : _finalize,
                    child: Text(_working ? 'Recording…' : 'Finalize', overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _notice(IconData icon, Color color, String title, String body) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: color)),
              ),
            ],
          ),
          if (body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 26),
              child: Text(body, style: const TextStyle(fontSize: 12.5)),
            ),
        ],
      ),
    );
  }
}
