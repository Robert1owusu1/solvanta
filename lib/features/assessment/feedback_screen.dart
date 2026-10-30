import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/correction.dart';
import '../../core/models/grading.dart';
import '../../core/models/question.dart';
import '../../core/models/submission.dart';
import '../../core/models/subjects.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../analytics/error_pattern_engine.dart';
import 'assessment_repository.dart';
import 'corrections_repository.dart';
import 'improvement.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({
    super.key,
    required this.studentId,
    required this.assessmentId,
    this.showAppBar = true,
  });

  final String studentId;
  final String assessmentId;
  final bool showAppBar;

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackData {
  final Assessment? assessment;
  final AssessmentSubmission? submission;
  final List<Correction> corrections;
  final List<ErrorPattern> patterns;
  final ({double? before, double? after}) trend;

  const _FeedbackData({
    required this.assessment,
    required this.submission,
    required this.corrections,
    required this.patterns,
    required this.trend,
  });
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  late Future<_FeedbackData> _data;
  final _controllers = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<_FeedbackData> _load() async {
    final repo = AssessmentRepository();
    final assessment =
        await repo.assessmentById(widget.assessmentId);
    final submission = await repo.submissionFor(
        widget.assessmentId, widget.studentId);
    final corrections = await CorrectionsRepository()
        .forAssessment(widget.studentId, widget.assessmentId);
    final all = await repo.assessments();
    final subsAll = await repo.submissions();

    var patterns = const <ErrorPattern>[];
    if (assessment != null && submission != null) {
      patterns = ErrorPatternAnalyzer()
          .analyze(questions: assessment.questions, sub: submission);
    }
    final trend = assessment == null
        ? (before: null, after: null)
        : subjectTrend(
            studentId: widget.studentId,
            subjectId: assessment.subjectId,
            assessmentId: assessment.id,
            assessmentDate: assessment.date,
            assessments: all,
            subs: subsAll,
          );

    for (final c in corrections) {
      _controllers[c.questionId] ??= TextEditingController(text: c.afterAnswer);
    }

    return _FeedbackData(
      assessment: assessment,
      submission: submission,
      corrections: corrections,
      patterns: patterns,
      trend: trend,
    );
  }

  void _refresh() => setState(() => _data = _load());

  Future<void> _saveCorrection(Question q, AssessmentSubmission sub) async {
    final text = _controllers[q.id]?.text.trim() ?? '';
    if (text.isEmpty) {
      svSnack(context, 'Write your corrected answer first.', error: true);
      return;
    }
    await CorrectionsRepository().save(Correction(
      id: 'CRCT-${DateTime.now().millisecondsSinceEpoch}',
      studentId: widget.studentId,
      assessmentId: widget.assessmentId,
      questionId: q.id,
      beforeAnswer: sub.answers[q.id] ?? '',
      afterAnswer: text,
      note: '',
      date: _today(),
      completed: true,
    ));
    if (mounted) {
      svSnack(context, 'Correction saved — well done');
      _refresh();
    }
  }

  String _today() {
    final d = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.showAppBar
          ? AppBar(title: const Text('Feedback & Corrections'))
          : null,
      body: FutureBuilder<_FeedbackData>(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SvLoading(message: 'Opening feedback…');
          }
          final data = snap.data;
          if (data == null || data.assessment == null) {
            return SvErrorState(
              message: 'Assessment not found',
              onRetry: _refresh,
            );
          }
          final a = data.assessment!;
          final sub = data.submission;
          if (sub == null) {
            return const SvEmptyState(
              icon: Icons.hourglass_empty,
              title: 'Not marked yet',
              message: 'Feedback for this student will appear once the '
                  'answer sheet has been marked.',
            );
          }
          return _buildList(a, sub, data);
        },
      ),
    );
  }

  Widget _buildList(Assessment a, AssessmentSubmission sub, _FeedbackData d) {
    final correctedIds = {for (final c in d.corrections) c.questionId};
    final incorrect =
        incorrectQuestions(a.questions, sub);
    final done = correctedIds.length;
    final total = incorrect.length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _headerCard(a, sub),
        const SizedBox(height: 14),
        Row(
          children: [
            Icon(Icons.edit_note, color: AppColors.brand, size: 18),
            const SizedBox(width: 6),
            Text(
              total == 0
                  ? 'All answers correct — no corrections needed'
                  : 'Corrections $done of $total complete',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (d.trend.before != null || d.trend.after != null)
          _trendCard(d.trend),
        if (d.patterns.isNotEmpty) ...[
          const SizedBox(height: 10),
          _patternsCard(d.patterns, a, sub),
        ],
        const SizedBox(height: 10),
        for (var i = 0; i < a.questions.length; i++)
          _questionCard(
            a.questions[i],
            sub,
            index: i,
            corrected: correctedIds.contains(a.questions[i].id),
            onSave: () => _saveCorrection(a.questions[i], sub),
          ),
        const SizedBox(height: 24),
        Text(
          'Write → Mark → Feedback → Correction → Practice → Reassess. '
          'Reassess after practice to see improvement.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: AppColors.muted),
        ),
      ],
    );
  }

  Widget _headerCard(Assessment a, AssessmentSubmission sub) {
    final total = a.totalMarks;
    final pct = total == 0 ? 0.0 : 100 * sub.earned / total;
    return Card(
      color: AppTheme.brand.withValues(alpha: .05),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(a.title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('${a.type.label} · ${subjectName(a.subjectId)} · ${a.classId}',
                style: TextStyle(fontSize: 12, color: AppColors.body)),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${sub.earned.toStringAsFixed(1)} / '
                    '${total.toStringAsFixed(1)}',
                    style: TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.brand)),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('${pct.toStringAsFixed(1)}% · '
                      'Grade ${schoolGrade(pct, a.classId)}',
                      style: TextStyle(
                          fontSize: 13, color: AppColors.body)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _trendCard(({double? before, double? after}) trend) {
    final before = trend.before;
    final after = trend.after;
    final delta =
        before != null && after != null ? after - before : null;
    final label = delta == null
        ? 'Subject trend'
        : delta <= -0.5
            ? 'Trending down — needs support'
            : delta >= 0.5
                ? 'Trending up — keep it going'
                : 'Steady — keep practising';
    final color = delta == null
        ? AppColors.notAttempted
        : delta >= 0
            ? AppColors.success
            : AppColors.danger;
    return Card(
      child: ListTile(
        leading: Icon(delta == null
            ? Icons.show_chart
            : delta >= 0
                ? Icons.trending_up
                : Icons.trending_down, color: color),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text([
          if (before != null) 'Before: ${before.toStringAsFixed(0)}%',
          if (after != null) 'After: ${after.toStringAsFixed(0)}%',
          if (delta != null && delta.abs() >= 0.5)
            '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(0)} pts',
        ].join('  ·  ')),
      ),
    );
  }

  Widget _patternsCard(
      List<ErrorPattern> patterns, Assessment a, AssessmentSubmission sub) {
    return Card(
      color: AppColors.infoBg,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.rule, color: AppColors.info, size: 18),
                SizedBox(width: 6),
                Text('Recurring error patterns',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              ],
            ),
            const SizedBox(height: 8),
            for (final p in patterns.take(4))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.circle,
                        size: 7, color: AppColors.primaryLight),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${p.label} (${p.count}x)'
                          '${p.detail.isEmpty ? '' : ' — ${p.detail}'}',
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _questionCard(Question q, AssessmentSubmission sub,
      {required int index, required bool corrected, required VoidCallback onSave}) {
    final answer = (sub.answers[q.id] ?? '').trim();
    final correct = isCorrect(q, sub);
    final controller = _controllers[q.id] ??=
        TextEditingController(text: corrected
            ? sub.answers[q.id] ?? ''
            : '');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: correct
              ? AppColors.success.withValues(alpha: .45)
              : corrected
                  ? AppColors.primaryLight.withValues(alpha: .45)
                  : AppColors.border,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  correct
                      ? Icons.check_circle
                      : corrected
                          ? Icons.task_alt
                          : Icons.cancel,
                  size: 18,
                  color: correct
                      ? AppColors.success
                      : corrected
                          ? AppColors.primaryLight
                          : AppColors.danger,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Q${index + 1} · ${q.topic} · ${q.cognitiveLevel}'
                    ' · ${q.marks.toStringAsFixed(0)} marks',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.ink),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(q.stem, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              answer.isEmpty
                  ? 'Not attempted'
                  : 'Your answer: $answer',
              style: TextStyle(
                fontSize: 13,
                color: answer.isEmpty
                    ? AppColors.notAttempted
                    : correct
                        ? AppColors.success
                        : AppColors.danger,
              ),
            ),
            if (q.isObjective) ...[
              Text('Expected: ${q.correctAnswer}',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.body)),
            ] else ...[
              Text('Awarded ${(sub.teacherMarks[q.id] ?? 0).toStringAsFixed(1)}'
                  ' of ${q.marks.toStringAsFixed(1)} marks',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.body)),
            ],
            if (q.explanation.isNotEmpty || q.markingScheme.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Guide: ${q.explanation.isNotEmpty ? q.explanation : q.markingScheme}',
                style: TextStyle(
                    fontSize: 12,
                    color: AppColors.muted,
                    fontStyle: FontStyle.italic),
              ),
            ],
            if (correct) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.successBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.emoji_events, size: 16, color: AppColors.success),
                    SizedBox(width: 6),
                    Text('Correct — keep practising this topic',
                        style: TextStyle(fontSize: 12.5)),
                  ],
                ),
              ),
            ] else ...[
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                enabled: !corrected,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: corrected
                      ? 'Correction recorded'
                      : 'Write your correction / what you learned',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: corrected
                      ? Icon(Icons.task_alt, color: AppColors.success)
                      : null,
                ),
              ),
              if (!corrected) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: onSave,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('Save correction'),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Same correctness rule used by the error-pattern engine and rewards.
bool isCorrect(Question q, AssessmentSubmission sub) {
  final answer = (sub.answers[q.id] ?? '').trim();
  if (q.isObjective) {
    return answer.isNotEmpty &&
        answer.toLowerCase() == q.correctAnswer.trim().toLowerCase();
  }
  return (sub.teacherMarks[q.id] ?? 0) >= q.marks * 0.8;
}

List<Question> incorrectQuestions(
        List<Question> questions, AssessmentSubmission sub) =>
    questions.where((q) => !isCorrect(q, sub)).toList();