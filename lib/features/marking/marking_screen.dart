import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/models/assessment.dart';
import '../../core/models/question.dart';
import '../../core/models/student.dart';
import '../../core/models/submission.dart';
import '../../core/theme/app_theme.dart';
import '../assessment/assessment_repository.dart';
import '../assessment/rule_marking_engine.dart';
import 'math_engine.dart';
import 'recognition_service.dart';

class MarkingScreen extends StatefulWidget {
  final Assessment assessment;
  final Student student;

  const MarkingScreen(
      {super.key, required this.assessment, required this.student});

  @override
  State<MarkingScreen> createState() => _MarkingScreenState();
}

class _MarkingScreenState extends State<MarkingScreen> {
  static final _svc = RecognitionService();

  final _picker = ImagePicker();
  final _aiControllers = <TextEditingController>[];
  final _markControllers = <TextEditingController>[];
  final _commentControllers = <TextEditingController>[];
  final _pages = <Uint8List>[];
  final _qualityIssues = <String>[];
  var _recognized = false;
  var _saving = false;
  List<AnswerSuggestion> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    for (final q in widget.assessment.questions) {
      _aiControllers.add(TextEditingController());
      _markControllers
          .add(TextEditingController(text: q.isObjective ? '' : '0'));
      _commentControllers.add(TextEditingController());
    }
  }

  @override
  void dispose() {
    for (final c
        in [..._aiControllers, ..._markControllers, ..._commentControllers]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _scan(ImageSource source) async {
    final file = await _picker.pickImage(
        source: source, maxWidth: 1600, imageQuality: 85);
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    final q = _svc.analyzeImage(bytes);
    if (!mounted) return;
    setState(() {
      _pages.add(bytes);
      if (!q.acceptable) _qualityIssues.addAll(q.issues);
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(q.acceptable
          ? 'Scan accepted — answer areas detected.'
          : 'Scan flagged: ${q.brief}. Consider a retake.'),
    ));
  }

  void _runRecognition() {
    final transcription = <String, String>{
      for (var i = 0; i < widget.assessment.questions.length; i++)
        widget.assessment.questions[i].id: _aiControllers[i].text,
    };
    final suggestions = _svc.recognize(
      questions: widget.assessment.questions,
      transcription: transcription,
    );
    setState(() {
      _recognized = true;
      _suggestions = suggestions;
    });
  }

  void _acceptHighConfidence() {
    for (var i = 0; i < widget.assessment.questions.length; i++) {
      final q = widget.assessment.questions[i];
      final s = _suggestions[i];
      if (s.confidence != Confidence.high) continue;
      if (!q.isObjective) {
        _aiControllers[i].text = s.suggested;
        _markControllers[i].text = q.marks.toStringAsFixed(0);
      }
    }
    setState(() {});
  }

  void _applyRuleMarks() {
    final engine = RuleMarkingEngine();
    var auto = 0;
    for (var i = 0; i < widget.assessment.questions.length; i++) {
      final q = widget.assessment.questions[i];
      if (q.isObjective) continue;
      final text = _aiControllers[i].text.trim();
      if (text.isEmpty) continue;
      final r = engine.suggest(q, text);
      if (r.confident) {
        _markControllers[i].text = r.mark.toStringAsFixed(1);
        auto++;
      }
    }
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(auto == 0
          ? 'No high-confidence rule matches — review manually'
          : 'Rule engine auto-marked $auto question(s)'),
    ));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final answers = <String, String>{
      for (var i = 0; i < widget.assessment.questions.length; i++)
        widget.assessment.questions[i].id: _aiControllers[i].text.trim(),
    };
    final teacherMarks = <String, double>{};
    for (var i = 0; i < widget.assessment.questions.length; i++) {
      final q = widget.assessment.questions[i];
      if (q.isObjective) continue;
      final m = double.tryParse(_markControllers[i].text.trim()) ?? 0;
      teacherMarks[q.id] = m.clamp(0, q.marks);
    }
    await AssessmentRepository().submit(
      assessment: widget.assessment,
      studentId: widget.student.id,
      answers: answers,
      teacherMarks: teacherMarks,
    );
    if (!mounted) return;
    Navigator.of(context).pop('saved');
  }

  Color _confColor(Confidence c) => switch (c) {
        Confidence.high => AppColors.success,
        Confidence.medium => AppColors.warning,
        Confidence.low => AppColors.danger,
      };

  @override
  Widget build(BuildContext context) {
    final questions = widget.assessment.questions;
    if (questions.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.student.fullName)),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'This assessment has no questions to mark yet. '
              'Add questions in the assessment builder first.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final autoEarned = questions.isNotEmpty
        ? computeEarned(questions, {
            for (var i = 0; i < questions.length; i++)
              if (questions[i].isObjective) questions[i].id: _aiControllers[i].text,
          }, {})
        : 0.0;
    final teacherTotal = questions.fold<double>(
        0,
        (sum, q) =>
            sum +
            (q.isObjective
                ? 0
                : double.tryParse(_markControllers[questions.indexOf(q)].text) ?? 0));
    final running = autoEarned + teacherTotal;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.student.fullName),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Running score\n'
                  '${running.toStringAsFixed(1)} / ${widget.assessment.totalMarks.toStringAsFixed(1)} marks',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: const Text('Save & submit'),
              ),
            ],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.brand.withValues(alpha: .06),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.verified_user_outlined,
                    size: 18, color: AppColors.brand),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'The AI reads the handwriting and suggests marks. You are '
                    'the final decision: review every suggestion, then save. '
                    'Nothing is applied to results until you confirm.',
                    style: TextStyle(fontSize: 12.5, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: '1 · Scan answer sheet',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _scan(ImageSource.camera),
                      icon: const Icon(Icons.photo_camera),
                      label: const Text('Camera'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => _scan(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Gallery'),
                    ),
                    const Spacer(),
                    if (_pages.isNotEmpty)
                      Text('${_pages.length} page(s)',
                          style: const TextStyle(fontWeight: .w600)),
                  ],
                ),
                if (_qualityIssues.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.warningBg,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber,
                            color: AppColors.warning),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Quality flags: ${_qualityIssues.join(', ')}. '
                            'Retake recommended for reliable recognition.',
                            style:
                                TextStyle(color: AppColors.warning),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: _runRecognition,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Run AI recognition'),
                ),
                const SizedBox(height: 4),
                Text(
                  'High-confidence suggestions can be applied in one tap. '
                  'Medium and low ones need your review before confirming.',
                  style: TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: '2 · Review suggestions & mark',
            trailing: Wrap(
              spacing: 8,
              children: [
                _ActionChip(
                  onPressed: _applyRuleMarks,
                  icon: Icons.rule,
                  label: 'Apply scheme rules',
                ),
                if (_recognized && _suggestions.isNotEmpty)
                  _ActionChip(
                    onPressed: _acceptHighConfidence,
                    icon: Icons.auto_awesome,
                    label: 'Accept all high-confidence',
                  ),
              ],
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(Icons.task_alt, size: 16, color: AppColors.brand),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _confirmedSummary(questions),
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.muted),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < questions.length; i++) ...[
                  _QuestionCard(
                    index: i + 1,
                    q: questions[i],
                    aiController: _aiControllers[i],
                    markController: _markControllers[i],
                    commentController: _commentControllers[i],
                    suggestion: _recognized ? _suggestions[i] : null,
                    confColor: _confColor,
                    onChanged: () => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _confirmedSummary(List<Question> questions) {
    var written = 0;
    var confirmed = 0;
    for (var i = 0; i < questions.length; i++) {
      final q = questions[i];
      if (q.isObjective) continue;
      written++;
      final m = double.tryParse(_markControllers[i].text.trim());
      if (m != null && m > 0) confirmed++;
    }
    if (written == 0) {
      return 'Objective questions will be auto-marked on save.';
    }
    return '$confirmed of $written written answers have a confirmed mark.';
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;

  const _Section({required this.title, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
            const Spacer(),
            ?trailing,
          ],
        ),
        const SizedBox(height: 10),
        child,
      ],
    );
  }
}

class _ActionChip extends StatelessWidget {
  final VoidCallback onPressed;
  final IconData icon;
  final String label;

  const _ActionChip({
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      onPressed: onPressed,
      avatar: Icon(icon, size: 16),
      label: Text(label),
    );
  }
}

class _QuestionCard extends StatelessWidget {
  final int index;
  final Question q;
  final TextEditingController aiController;
  final TextEditingController markController;
  final TextEditingController commentController;
  final AnswerSuggestion? suggestion;
  final Color Function(Confidence) confColor;
  final VoidCallback onChanged;

  const _QuestionCard({
    required this.index,
    required this.q,
    required this.aiController,
    required this.markController,
    required this.commentController,
    required this.suggestion,
    required this.confColor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final conf = suggestion?.confidence;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: AppTheme.brand.withValues(alpha: .12),
                  child: Text('$index',
                      style: TextStyle(
                          fontSize: 12, fontWeight: .w700, color: AppColors.brand)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(q.stem,
                      style: const TextStyle(fontWeight: .w600)),
                ),
                Text('${q.marks.toStringAsFixed(0)} marks',
                    style: const TextStyle(
                        fontWeight: .w700, color: AppTheme.accent)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${q.type.label} · ${q.cognitiveLevel} · difficulty ${q.difficulty}'
              '${q.isObjective ? ' · ${q.options.join(' | ')}' : ''}',
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
            if (q.markingScheme.isNotEmpty) ...[
              const SizedBox(height: 4),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.accent.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Scheme: ${q.markingScheme}',
                  style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.accent,
                      fontWeight: FontWeight.w500),
                ),
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: aiController,
              onChanged: (_) => onChanged(),
              decoration: InputDecoration(
                isDense: true,
                labelText: q.isObjective
                    ? 'AI-detected selection'
                    : 'What the AI read (photos → handwriting)',
                border: const OutlineInputBorder(),
                suffixIcon: suggestion == null
                    ? null
                    : Icon(Icons.auto_awesome, color: confColor(conf!)),
              ),
            ),
            if (suggestion != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  _Chip(
                      label: 'AI confidence: ${suggestion!.confidence.name}',
                      color: confColor(conf!)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      suggestion!.confidence == Confidence.high
                          ? '${suggestion!.note} — safe to apply.'
                          : '${suggestion!.note} — review before confirming.',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.muted),
                    ),
                  ),
                ],
              ),
            ],
            if (!q.isObjective) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: markController,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      onChanged: (_) => onChanged(),
                      decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'Marks',
                          border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: commentController,
                      decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'Comment (optional)',
                          border: OutlineInputBorder()),
                    ),
                  ),
                ],
              ),
              if (q.type == QuestionType.math && suggestion != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Math engine: ${_mathEngineNote(q.correctAnswer, suggestion!.suggested)}',
                    style: TextStyle(fontSize: 12, color: AppColors.muted),
                  ),
                ),
            ] else ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  suggestion != null &&
                          suggestion!.suggested.trim().toLowerCase() ==
                              q.correctAnswer.trim().toLowerCase()
                      ? 'Auto-marked correct (+${q.marks.toStringAsFixed(0)} marks)'
                      : 'No marks yet — AI text must match the scheme',
                  style: TextStyle(
                      fontWeight: .w600,
                      color: AppColors.brand,
                      fontSize: 13),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _mathEngineNote(String expected, String studentAnswer) {
  final engine = MathMarkingEngine();
  final check = engine.check(expected, studentAnswer);
  return check.correct
      ? '$expected ≡ "$studentAnswer" ✔ (${check.reasoning})'
      : '$expected ≢ "$studentAnswer" — ${check.reasoning}';
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;

  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: .w700, color: color)),
    );
  }
}