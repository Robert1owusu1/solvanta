import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/question.dart';
import '../../core/models/submission.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../analytics/analytics_service.dart';
import '../assessment/assessment_repository.dart';

class MockTakeScreen extends StatefulWidget {
  final Assessment assessment;
  final String studentId;
  final int durationMinutes;

  const MockTakeScreen({
    super.key,
    required this.assessment,
    required this.studentId,
    this.durationMinutes = 10,
  });

  @override
  State<MockTakeScreen> createState() => _MockTakeScreenState();
}

class _MockTakeScreenState extends State<MockTakeScreen> {
  late final Duration _duration =
      Duration(minutes: widget.durationMinutes);

  var _index = 0;
  var _submitted = false;
  var _earned = 0.0;
  late var _secondsLeft = _duration.inSeconds;
  Timer? _timer;
  final _answers = <String, String>{};
  final _controllers = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    for (final q in widget.assessment.questions) {
      if (!q.isObjective) {
        _controllers[q.id] = TextEditingController();
      }
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_secondsLeft <= 0) {
        _timer?.cancel();
        _submit();
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _confirmAndSubmit() async {
    if (_submitted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Submit mock?'),
        content: const Text(
            'Your answers will be sent for marking. You won\'t be able to '
            'change them afterwards.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep working')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Submit')),
        ],
      ),
    );
    if (confirmed == true) await _submit();
  }

  Future<void> _submit() async {
    if (_submitted) return;
    final questions = widget.assessment.questions;
    if (questions.isEmpty) {
      if (mounted) {
        setState(() => _submitted = true);
        _timer?.cancel();
      }
      return;
    }
    setState(() => _submitted = true);
    final answers = <String, String>{
      ..._answers,
      for (final e in _controllers.entries) e.key: e.value.text.trim(),
    };
    final earned = computeEarned(widget.assessment.questions, answers, const {});
    try {
      await AssessmentRepository().submit(
        assessment: widget.assessment,
        studentId: widget.studentId,
        answers: answers,
        teacherMarks: const {},
      );
    } catch (_) {
      if (mounted) {
        setState(() => _submitted = false);
        svSnack(context, 'Could not submit your mock. Please try again.',
            error: true);
      }
      return;
    }
    if (mounted) {
      setState(() => _earned = earned);
      _timer?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final questions = widget.assessment.questions;
    if (questions.isEmpty) {
      _timer?.cancel();
      return Scaffold(
        appBar: AppBar(title: Text(widget.assessment.title)),
        body: const SvEmptyState(
          icon: Icons.edit_off,
          title: 'This mock has no questions yet',
          message: 'There\'s nothing to attempt right now. Let your teacher '
              'know so they can add questions.',
        ),
      );
    }
    final q = questions[_index];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.assessment.title),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(_mmss(),
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: _secondsLeft < 120
                          ? AppColors.warning
                          : AppTheme.brand)),
            ),
          ),
        ],
      ),
      body: _submitted
          ? _ResultView(
              assessment: widget.assessment,
              earned: _earned,
              answers: _answersEntries(),
            )
          : _buildQuiz(q),
    );
  }

  Map<String, String> _answersEntries() => {
        ..._answers,
        for (final e in _controllers.entries) e.key: e.value.text.trim(),
      };

  String _mmss() {
    final m = (_secondsLeft ~/ 60).toString().padLeft(2, '0');
    final s = (_secondsLeft % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _buildQuiz(Question q) {
    final questions = widget.assessment.questions;
    return Column(
      children: [
        LinearProgressIndicator(
          value: (_index + 1) / questions.length,
          minHeight: 4,
          color: AppColors.brand,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Text('Question ${_index + 1} of ${questions.length}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('${q.marks.toStringAsFixed(0)} marks',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: AppTheme.accent)),
                ],
              ),
              const SizedBox(height: 12),
              Text(q.stem,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(q.type.label,
                  style: TextStyle(color: AppColors.muted, fontSize: 12)),
              const SizedBox(height: 12),
              if (q.isObjective)
                RadioGroup<String>(
                  groupValue: _answers[q.id],
                  onChanged: (v) => setState(() {
                    if (v != null) _answers[q.id] = v;
                  }),
                  child: Column(
                    children: [
                      for (final o in q.options)
                        RadioListTile<String>(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(o),
                          value: o,
                        ),
                    ],
                  ),
                )
              else
                TextField(
                  controller: _controllers[q.id],
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Your answer',
                    hintText: 'Type your working / answer',
                  ),
                ),
              const SizedBox(height: 24),
              Row(
                children: [
                  if (_index > 0)
                    OutlinedButton.icon(
                      onPressed: _submitted
                          ? null
                          : () => setState(() => _index--),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Previous'),
                    ),
                  const Spacer(),
                  if (_index < questions.length - 1)
                    FilledButton.icon(
                      onPressed: () => setState(() => _index++),
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('Next'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _confirmAndSubmit,
                      icon: const Icon(Icons.check),
                      label: const Text('Submit mock'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _cleanJoin(List<String> texts) {
  final names = <String>[
    for (final t in texts)
      if (t.trim().isNotEmpty) t.trim(),
  ];
  return names.join(' · ');
}

class _ResultView extends StatelessWidget {
  final Assessment assessment;
  final double earned;
  final Map<String, String> answers;

  const _ResultView({
    required this.assessment,
    required this.earned,
    required this.answers,
  });

  @override
  Widget build(BuildContext context) {
    final pct = assessment.totalMarks > 0
        ? 100 * earned / assessment.totalMarks
        : 0.0;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Mock submitted', style: _t),
        const SizedBox(height: 4),
        Text(
          '${earned.toStringAsFixed(1)} / ${assessment.totalMarks.toStringAsFixed(1)} '
          '  ·  ${pct.toStringAsFixed(1)}%  ·  Grade ${gradeLetter(pct)}',
          style: TextStyle(
              fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.brand),
        ),
        const SizedBox(height: 8),
        Text(
          'Objective questions auto-marked. Written answers have been sent '
          'to your teacher for marking.',
          style: TextStyle(color: AppColors.muted, fontSize: 13),
        ),
        const Divider(height: 32),
        for (final q in assessment.questions) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(q.stem,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(_cleanJoin([
                      if (q.isObjective) 'You answered: ${answers[q.id]}',
                      if (!q.isObjective) 'You wrote: ${answers[q.id]}',
                      if (q.isObjective)
                        answers[q.id]?.trim().toLowerCase() ==
                                q.correctAnswer.trim().toLowerCase()
                            ? 'Correct ✔'
                            : 'Not correct',
                    ]),
                        style: TextStyle(
                            fontSize: 12, color: AppColors.body)),
                  ],
                ),
              ),
              Text('${q.marks.toStringAsFixed(0)} marks',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, color: AppTheme.accent)),
            ],
          ),
          const Divider(height: 16),
        ],
      ],
    );
  }
}

final _t = const TextStyle(fontSize: 15, fontWeight: FontWeight.w700);