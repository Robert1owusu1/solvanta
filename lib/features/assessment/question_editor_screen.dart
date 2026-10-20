import 'package:flutter/material.dart';

import '../../core/models/question.dart';
import '../../core/models/subjects.dart';
import '../../core/theme/app_theme.dart';

class QuestionEditorScreen extends StatefulWidget {
  const QuestionEditorScreen({super.key, this.initial});

  final Question? initial;

  @override
  State<QuestionEditorScreen> createState() => _QuestionEditorScreenState();
}

class _QuestionEditorScreenState extends State<QuestionEditorScreen> {
  late final TextEditingController _stem;
  late final TextEditingController _topic;
  late final TextEditingController _explanation;
  late final TextEditingController _marks;
  late final TextEditingController _correct;
  late final TextEditingController _scheme;
  late final List<TextEditingController> _optionControllers =
      List.generate(4, (_) => TextEditingController());

  late QuestionType _type;
  late String _subjectId;
  late int _difficulty;
  late String _cognitive;
  int _optionCount = 4;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    _stem = TextEditingController(text: init?.stem ?? '');
    _topic = TextEditingController(text: init?.topic ?? '');
    _explanation = TextEditingController(text: init?.explanation ?? '');
    _marks = TextEditingController(
        text: (init?.marks ?? 2).toStringAsFixed(0));
    _correct = TextEditingController(text: init?.correctAnswer ?? '');
    _scheme = TextEditingController(text: init?.markingScheme ?? '');
    _type = init?.type ?? QuestionType.mcq;
    _subjectId = init?.subjectId ?? 'MATH';
    _difficulty = init?.difficulty ?? 1;
    _cognitive = init?.cognitiveLevel ?? 'Knowledge';
    if (init != null) {
      final opts = init.options;
      _optionCount = opts.length.clamp(2, 4);
      for (var i = 0; i < opts.length && i < 4; i++) {
        _optionControllers[i].text = opts[i];
      }
      if (_type != QuestionType.mcq) {
        _correct.text = init.correctAnswer;
      }
    }
  }

  @override
  void dispose() {
    _stem.dispose();
    _topic.dispose();
    _explanation.dispose();
    _marks.dispose();
    _correct.dispose();
    _scheme.dispose();
    for (final c in _optionControllers) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> _ruleTokens(String scheme) => scheme
      .split(RegExp(r'[;\n,·•]+'))
      .map((k) => k.trim().toLowerCase())
      .where((k) => k.isNotEmpty && k.length >= 3)
      .toList();

  Future<void> _save() async {
    if (_stem.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter the question text')));
      return;
    }
    String correct;
    if (_type == QuestionType.mcq) {
      final options = [
        for (var i = 0; i < _optionCount; i++)
          _optionControllers[i].text.trim(),
      ];
      if (_correct.text.startsWith('__CORRECT:')) {
        correct = _correct.text.substring(10);
      } else {
        correct = options.isNotEmpty ? options.first : '';
      }
    } else {
      correct = _correct.text.trim();
    }
    final q = Question(
      id: widget.initial?.id ??
          'Q-$_subjectId-${DateTime.now().millisecondsSinceEpoch}',
      type: _type,
      subjectId: _subjectId,
      classId: widget.initial?.classId ?? 'JHS2A',
      topic: _topic.text.trim(),
      difficulty: _difficulty,
      cognitiveLevel: _cognitive,
      marks: double.tryParse(_marks.text) ?? 2,
      stem: _stem.text.trim(),
      options: _type == QuestionType.mcq
          ? [for (var i = 0; i < _optionCount; i++) _optionControllers[i].text.trim()]
          : const [],
      correctAnswer: correct,
      explanation: _explanation.text.trim(),
      markingScheme: _type == QuestionType.mcq ||
              _type == QuestionType.trueFalse
          ? (widget.initial?.markingScheme ?? '')
          : _scheme.text.trim(),
    );
    Navigator.of(context).pop(q);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? 'New question' : 'Edit question'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<QuestionType>(
            isExpanded: true,
            initialValue: _type,
            decoration: const InputDecoration(labelText: 'Type'),
            items: [
              for (final t in QuestionType.values)
                DropdownMenuItem(value: t, child: Text(t.label)),
            ],
            onChanged: (v) => setState(() {
              _type = v ?? QuestionType.mcq;
              if (_type != QuestionType.mcq && _correct.text.isEmpty) {
                _correct.text = _type == QuestionType.trueFalse ? 'True' : '';
              }
            }),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _subjectId,
            decoration: const InputDecoration(labelText: 'Subject'),
            items: [
              for (final s in subjects)
                DropdownMenuItem(value: s.id, child: Text(s.name)),
            ],
            onChanged: (v) => setState(() => _subjectId = v ?? 'MATH'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _stem,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Question text'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _topic,
            decoration: const InputDecoration(labelText: 'Topic'),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _marks,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Marks'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _cognitive,
                  decoration: const InputDecoration(labelText: 'Cognitive level'),
                  items: [
                    for (final c in cognitiveLevels)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setState(() => _cognitive = v ?? 'Knowledge'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Difficulty',
            style: TextStyle(color: AppColors.body, fontSize: 13),
          ),
          const SizedBox(height: 6),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('Easy')),
              ButtonSegment(value: 2, label: Text('Medium')),
              ButtonSegment(value: 3, label: Text('Hard')),
            ],
            selected: {_difficulty},
            onSelectionChanged: (s) => setState(() => _difficulty = s.first),
          ),
          if (_type == QuestionType.mcq) ...[
            const SizedBox(height: 14),
            Text('Options',
                style:
                    TextStyle(color: AppColors.body, fontSize: 13)),
            for (var i = 0; i < _optionCount; i++) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _optionControllers[i],
                decoration: InputDecoration(
                  labelText: 'Option ${i + 1}',
                  suffixIcon: IconButton(
                    icon: Icon(
                        i == 0 ? Icons.check_circle : Icons.circle_outlined,
                        color: i == 0 ? AppTheme.brand : AppColors.muted),
                    tooltip: 'Correct option',
                    onPressed: () => setState(() {
                      final t = _optionControllers[i].text.trim();
                      if (t.isNotEmpty) _correct.text = '__CORRECT:$t';
                    }),
                  ),
                ),
              ),
            ],
          ] else if (_type == QuestionType.trueFalse) ...[
            const SizedBox(height: 14),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'True', label: Text('True')),
                ButtonSegment(value: 'False', label: Text('False')),
              ],
              selected: {_correct.text.isEmpty ? 'True' : _correct.text},
              onSelectionChanged: (s) =>
                  setState(() => _correct.text = s.first),
            ),
          ] else ...[
            const SizedBox(height: 14),
            TextField(
              controller: _correct,
              decoration: const InputDecoration(
                labelText: 'Expected answer / marking note',
              ),
            ),
          ],
          const SizedBox(height: 14),
          TextField(
            controller: _explanation,
            minLines: 2,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Explanation (optional)'),
          ),
          if (_type != QuestionType.mcq &&
              _type != QuestionType.trueFalse) ...[
            const SizedBox(height: 14),
            TextField(
              controller: _scheme,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Marking scheme (rule-based auto-marking)',
                helperText:
                    'Expected answer plus key points separated by ; or , — '
                    'the rule engine uses these to auto-suggest partial marks.',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _scheme.text.trim().isEmpty
                  ? 'Scheme is optional — answers will need teacher judgement.'
                  : 'Rule tokens: ${_ruleTokens(_scheme.text.trim()).join(' · ')}',
              style: TextStyle(
                  fontSize: 12,
                  color: _scheme.text.trim().isEmpty
                      ? AppColors.muted
                      : AppTheme.brand),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16)),
            child: const Text('Save question'),
          ),
        ],
      ),
    );
  }
}