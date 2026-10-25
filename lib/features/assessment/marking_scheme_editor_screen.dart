import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/assessment.dart';
import '../../core/models/assignment.dart';
import '../../core/models/marking_scheme.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';

/// Create or edit the marking scheme attached to an assessment or an
/// assignment.
///
/// Editing never silently rewrites history: the backend decides whether the
/// save bumps to a NEW version (submissions already marked against the scheme)
/// or updates in place (none yet). The screen reports which happened.
class MarkingSchemeEditorScreen extends StatefulWidget {
  const MarkingSchemeEditorScreen({
    super.key,
    this.assessment,
    this.assignment,
    this.initialScheme,
  }) : assert(assessment != null || assignment != null);

  final Assessment? assessment;
  final Assignment? assignment;
  final MarkingScheme? initialScheme;

  @override
  State<MarkingSchemeEditorScreen> createState() =>
      _MarkingSchemeEditorScreenState();
}

class _MarkingSchemeEditorScreenState extends State<MarkingSchemeEditorScreen> {
  final List<_EditableQuestion> _questions = [];

  MarkingScheme? _existingScheme;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _existingScheme = widget.initialScheme;
    final seed = widget.initialScheme;
    if (seed != null) {
      _hydrate(seed);
      _loading = false;
    } else {
      _loadExisting();
    }
  }

  @override
  void dispose() {
    for (final q in _questions) {
      q.dispose();
    }
    super.dispose();
  }

  bool get _isAssessment => widget.assessment != null;

  String get _targetLabel =>
      widget.assessment?.title ?? widget.assignment?.title ?? 'Untitled';

  String get _targetId =>
      widget.assessment?.id ?? widget.assignment?.id ?? '';

  void _hydrate(MarkingScheme scheme) {
    _questions
      ..clear()
      ..addAll(scheme.questions.map(_EditableQuestion.fromSchemeQuestion));
  }

  Future<void> _loadExisting() async {
    final id = _targetId;
    if (id.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    final kind = _isAssessment ? 'assessments' : 'assignments';
    try {
      final raw = await ApiClient().get('/api/$kind/$id/marking-scheme');
      if (!mounted) return;
      final list = (raw as List?)?.cast<Map<String, dynamic>>() ?? const [];
      // Endpoint returns newest version first.
      if (list.isNotEmpty) {
        final scheme = MarkingScheme.fromJson(list.first);
        setState(() {
          _existingScheme = scheme;
          _hydrate(scheme);
        });
      }
    } on ApiException {
      // No scheme yet, or offline — start from an empty editor.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? _validate() {
    if (_questions.isEmpty) return 'Add at least one question';
    for (var i = 0; i < _questions.length; i++) {
      final q = _questions[i];
      final label = 'Question ${i + 1}';
      if (q.totalMarks <= 0) return '$label: total marks must be positive';
      if (!q.breakdownOk) {
        return '$label: breakdown sums to ${q.breakdownSum.toStringAsFixed(1)} '
            'but total is ${q.totalMarks.toStringAsFixed(1)}';
      }
      if (q.answers.every((a) => a.text.text.trim().isEmpty)) {
        return '$label: add at least one accepted answer';
      }
      if (q.primaryCount != 1) {
        return '$label: exactly one accepted answer must be marked primary';
      }
    }
    return null;
  }

  Future<void> _save() async {
    final problem = _validate();
    if (problem != null) {
      _toast(problem, danger: true);
      return;
    }
    final id = _targetId;
    if (id.isEmpty) return;

    setState(() => _saving = true);
    svHaptic(SvHaptic.medium);

    final questionsJson = [
      for (var i = 0; i < _questions.length; i++) _questions[i].toJson(i + 1),
    ];

    try {
      final api = ApiClient();
      final Object? raw;
      if (_existingScheme == null) {
        raw = await api.post(
          '/api/${_isAssessment ? 'assessments' : 'assignments'}/$id/marking-scheme',
          {
            if (_isAssessment) 'assessmentId': id else 'assignmentId': id,
            'questions': questionsJson,
          },
        );
      } else {
        raw = await api.put('/api/marking-schemes/${_existingScheme!.id}', {
          'questions': questionsJson,
        });
      }

      if (!mounted) return;
      final saved = MarkingScheme.fromJson(raw as Map<String, dynamic>);
      final newVersionCreated = _existingScheme != null &&
          saved.id != _existingScheme!.id;
      setState(() => _existingScheme = saved);
      _toast(newVersionCreated
          ? 'Saved as v${saved.version} — a new version, submissions already existed'
          : 'Saved v${saved.version}');
      Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      _toast(e.message, danger: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String message, {bool danger = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: danger ? AppColors.dangerSolid : null,
      ),
    );
  }

  void _addQuestion() {
    setState(() {
      final q = _EditableQuestion(number: _questions.length + 1);
      // Seed one step so the mark-breakdown sum always equals the total,
      // matching the backend's `chk_mark_breakdown_sum` constraint.
      q.steps.add(_StepRow(
        type: 'final_answer',
        criteria: TextEditingController(),
        marks: TextEditingController(text: q.totalMarks.toStringAsFixed(1)),
      ));
      _questions.add(q);
    });
  }

  void _removeQuestion(int index) {
    setState(() {
      _questions.removeAt(index).dispose();
      for (var i = 0; i < _questions.length; i++) {
        _questions[i].number = i + 1;
      }
    });
  }

  void _moveQuestion(int from, int to) {
    setState(() {
      final moved = _questions.removeAt(from);
      _questions.insert(to, moved);
      for (var i = 0; i < _questions.length; i++) {
        _questions[i].number = i + 1;
      }
    });
  }

  void _markPrimary(int questionIndex, int answerIndex) {
    setState(() {
      final answers = _questions[questionIndex].answers;
      for (var i = 0; i < answers.length; i++) {
        answers[i].isPrimary = i == answerIndex;
      }
    });
  }

  void _showPreview() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Preview'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (var i = 0; i < _questions.length; i++)
                _PreviewTile(question: _questions[i], index: i + 1),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_existingScheme == null
            ? 'Create marking scheme'
            : 'Edit marking scheme (v${_existingScheme!.version})'),
        actions: [
          IconButton(
            tooltip: 'Preview',
            onPressed: _questions.isEmpty ? null : _showPreview,
            icon: const Icon(Icons.preview_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildTargetCard(),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text(
                      'Questions (${_questions.length})',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _addQuestion,
                      icon: const Icon(Icons.add),
                      label: const Text('Add question'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (_questions.isEmpty)
                  _buildEmptyState()
                else
                  for (var i = 0; i < _questions.length; i++)
                    _QuestionCard(
                      key: ObjectKey(_questions[i]),
                      question: _questions[i],
                      index: i,
                      isFirst: i == 0,
                      isLast: i == _questions.length - 1,
                      onChanged: () => setState(() {}),
                      onPrimary: (a) => _markPrimary(i, a),
                      onMoveUp: () => _moveQuestion(i, i - 1),
                      onMoveDown: () => _moveQuestion(i, i + 1),
                      onDelete: () => _removeQuestion(i),
                    ),
                const SizedBox(height: 8),
                _ValidationSummary(questions: _questions),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_existingScheme == null
                          ? 'Save marking scheme'
                          : 'Save changes'),
                ),
              ],
            ),
    );
  }

  Widget _buildTargetCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              _isAssessment ? Icons.assignment : Icons.assignment_turned_in,
              color: AppTheme.brand,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Target',
                      style:
                          TextStyle(fontSize: 12, color: AppColors.muted)),
                  Text(_targetLabel,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16)),
                ],
              ),
            ),
            Chip(
              label: Text(_isAssessment ? 'Assessment' : 'Assignment'),
              backgroundColor: AppTheme.brand.withValues(alpha: .12),
              labelStyle: TextStyle(
                color: AppTheme.brand,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Card(
      color: AppTheme.brand.withValues(alpha: .05),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.assignment_add,
                size: 48, color: AppTheme.brand.withValues(alpha: .5)),
            const SizedBox(height: 12),
            Text('No questions yet',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.brand)),
            const SizedBox(height: 4),
            Text(
              'Tap "Add question" to start building the marking scheme',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lowercases and strips every separator/punctuation so two spellings of the
/// same answer compare equal. Used for [AcceptedAnswer.normalizedForm].
String normalizeAnswer(String text) {
  return text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

const List<String> kBreakdownTypes = [
  'method',
  'final_answer',
  'working',
  'other',
];

/// One editable mark-breakdown step.
class _StepRow {
  _StepRow({required this.type, required this.criteria, required this.marks});

  factory _StepRow.blank(int index, double marks) => _StepRow(
        type: 'method',
        criteria: TextEditingController(),
        marks: TextEditingController(text: marks.toStringAsFixed(1)),
      );

  String type;
  final TextEditingController criteria;
  final TextEditingController marks;

  double get marksValue => double.tryParse(marks.text) ?? 0;

  void dispose() {
    criteria.dispose();
    marks.dispose();
  }
}

/// One editable accepted-answer variant.
class _AnswerRow {
  _AnswerRow({
    this.id,
    required this.text,
    required this.marks,
    this.isPrimary = false,
  });

  factory _AnswerRow.blank({int? id, required double marks}) => _AnswerRow(
        id: id,
        text: TextEditingController(),
        marks: TextEditingController(text: marks.toStringAsFixed(1)),
      );

  int? id;
  final TextEditingController text;
  final TextEditingController marks;
  bool isPrimary;

  double get marksValue => double.tryParse(marks.text) ?? 0;

  void dispose() {
    text.dispose();
    marks.dispose();
  }
}

/// One editable common-misconception entry.
class _MisconceptionRow {
  _MisconceptionRow({
    this.id,
    required this.pattern,
    required this.cause,
    required this.marks,
  });

  factory _MisconceptionRow.blank({int? id}) => _MisconceptionRow(
        id: id,
        pattern: TextEditingController(),
        cause: TextEditingController(),
        marks: TextEditingController(text: '0'),
      );

  int? id;
  final TextEditingController pattern;
  final TextEditingController cause;
  final TextEditingController marks;

  double get marksValue => double.tryParse(marks.text) ?? 0;

  void dispose() {
    pattern.dispose();
    cause.dispose();
    marks.dispose();
  }
}

/// One editable scheme question: owns its rows and their controllers.
class _EditableQuestion {
  _EditableQuestion({required this.number, this.id, this.totalMarks = 5});

  factory _EditableQuestion.fromSchemeQuestion(SchemeQuestion q) {
    final eq = _EditableQuestion(
      number: q.questionNumber,
      id: q.id,
      totalMarks: q.totalMarks,
    );
    eq.steps.addAll(q.markBreakdown.map(
      (s) => _StepRow(
        type: s.type,
        criteria: TextEditingController(text: s.criteria),
        marks: TextEditingController(text: s.marks.toStringAsFixed(1)),
      ),
    ));
    eq.answers.addAll(q.acceptedAnswers.map(
      (a) => _AnswerRow(
        id: a.id,
        text: TextEditingController(text: a.answerText),
        marks: TextEditingController(text: a.marksAwarded.toStringAsFixed(1)),
        isPrimary: a.isPrimary,
      ),
    ));
    eq.misconceptions.addAll(q.misconceptions.map(
      (m) => _MisconceptionRow(
        id: m.id,
        pattern: TextEditingController(text: m.wrongAnswerPattern),
        cause: TextEditingController(text: m.likelyCause),
        marks: TextEditingController(text: m.marksAwarded.toStringAsFixed(1)),
      ),
    ));
    return eq;
  }

  int number;
  String? id;
  double totalMarks;

  final TextEditingController totalMarksController = TextEditingController();
  final List<_StepRow> steps = [];
  final List<_AnswerRow> answers = [];
  final List<_MisconceptionRow> misconceptions = [];

  bool _seededTotal = false;

  /// The controller starts empty; seed it once from [totalMarks].
  void ensureTotalSeeded() {
    if (_seededTotal) return;
    _seededTotal = true;
    totalMarksController.text = totalMarks.toStringAsFixed(1);
  }

  double get breakdownSum =>
      steps.fold(0.0, (sum, s) => sum + s.marksValue);

  bool get breakdownOk => (breakdownSum - totalMarks).abs() < 0.01;

  int get primaryCount => answers.where((a) => a.isPrimary).length;

  void dispose() {
    totalMarksController.dispose();
    for (final s in steps) {
      s.dispose();
    }
    for (final a in answers) {
      a.dispose();
    }
    for (final m in misconceptions) {
      m.dispose();
    }
  }

  /// Serialises to the backend's [SchemeQuestion] JSON shape.
  Map<String, dynamic> toJson(int questionNumber) {
    final now = DateTime.now().toIso8601String();
    final qid = id ?? 'SQ-${DateTime.now().millisecondsSinceEpoch}-$number';
    return {
      'id': qid,
      'schemeId': '',
      'questionNumber': questionNumber,
      'totalMarks': totalMarks,
      'markBreakdown': [
        for (var i = 0; i < steps.length; i++)
          {
            'id': 'step-${i + 1}',
            'type': steps[i].type,
            'criteria': steps[i].criteria.text.trim(),
            'marks': steps[i].marksValue,
          },
      ],
      'acceptedAnswers': [
        for (var i = 0; i < answers.length; i++)
          {
            'id': answers[i].id ?? (number * 1000 + i + 1),
            'schemeQuestionId': qid,
            'answerText': answers[i].text.text,
            'normalizedForm': normalizeAnswer(answers[i].text.text),
            'marksAwarded': answers[i].marksValue,
            'isPrimary': answers[i].isPrimary,
            'createdAt': now,
          },
      ],
      'misconceptions': [
        for (var i = 0; i < misconceptions.length; i++)
          {
            'id': misconceptions[i].id ?? (number * 1000 + 500 + i + 1),
            'schemeQuestionId': qid,
            'wrongAnswerPattern':
                normalizeAnswer(misconceptions[i].pattern.text),
            'likelyCause': misconceptions[i].cause.text,
            'marksAwarded': misconceptions[i].marksValue,
            'createdAt': now,
          },
      ],
      'createdAt': now,
    };
  }
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    super.key,
    required this.question,
    required this.index,
    required this.isFirst,
    required this.isLast,
    required this.onChanged,
    required this.onPrimary,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDelete,
  });

  final _EditableQuestion question;
  final int index;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onChanged;
  final ValueChanged<int> onPrimary;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    question.ensureTotalSeeded();
    final sum = question.breakdownSum;
    final okSum = question.breakdownOk;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: ExpansionTile(
        initiallyExpanded: index == 0,
        leading: CircleAvatar(
          backgroundColor: AppTheme.brand.withValues(alpha: .12),
          child: Text('Q${question.number}',
              style: TextStyle(
                  color: AppTheme.brand, fontWeight: FontWeight.w800)),
        ),
        title: Text('Question ${question.number}',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Row(
          children: [
            Text('${question.totalMarks.toStringAsFixed(1)} marks',
                style: TextStyle(color: AppColors.muted, fontSize: 12)),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: (okSum ? AppColors.success : AppColors.danger)
                    .withValues(alpha: .12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Breakdown ${sum.toStringAsFixed(1)} / ${question.totalMarks.toStringAsFixed(1)}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: okSum ? AppColors.success : AppColors.danger,
                ),
              ),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Move up',
              onPressed: isFirst ? null : onMoveUp,
              icon: const Icon(Icons.keyboard_arrow_up, size: 20),
            ),
            IconButton(
              tooltip: 'Move down',
              onPressed: isLast ? null : onMoveDown,
              icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            ),
            IconButton(
              tooltip: 'Delete question',
              onPressed: onDelete,
              icon: Icon(Icons.delete_outline, color: AppColors.danger),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: question.totalMarksController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Total marks',
                    prefixIcon: Icon(Icons.grade_outlined),
                    isDense: true,
                  ),
                  onChanged: (v) {
                    question.totalMarks = double.tryParse(v) ?? 0;
                    onChanged();
                  },
                ),
                const SizedBox(height: 16),
                _SectionHeader(
                  title: 'Mark breakdown',
                  subtitle:
                      'Steps must sum to ${question.totalMarks.toStringAsFixed(1)}',
                ),
                for (var i = 0; i < question.steps.length; i++)
                  _BreakdownRow(
                    key: ObjectKey(question.steps[i]),
                    step: question.steps[i],
                    index: i + 1,
                    onChanged: onChanged,
                    onDelete: () {
                      question.steps.removeAt(i).dispose();
                      onChanged();
                    },
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      final remaining = question.totalMarks -
                          question.breakdownSum;
                      question.steps.add(
                        _StepRow.blank(
                          question.steps.length + 1,
                          remaining <= 0 ? 0 : remaining,
                        ),
                      );
                      onChanged();
                    },
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add step'),
                  ),
                ),
                const SizedBox(height: 8),
                _SectionHeader(
                  title: 'Accepted answers',
                  subtitle: 'Exactly one must be primary',
                ),
                for (var i = 0; i < question.answers.length; i++)
                  _AnswerRowCard(
                    key: ObjectKey(question.answers[i]),
                    answer: question.answers[i],
                    index: i + 1,
                    onChanged: onChanged,
                    onPrimary: () => onPrimary(i),
                    onDelete: () {
                      question.answers.removeAt(i).dispose();
                      onChanged();
                    },
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      question.answers.add(
                        _AnswerRow.blank(
                          id: question.answers.isEmpty
                              ? null
                              : question.answers.last.id == null
                                  ? null
                                  : question.answers.length + 1,
                          marks: question.totalMarks,
                        ),
                      );
                      if (question.answers.length == 1) {
                        question.answers.first.isPrimary = true;
                      }
                      onChanged();
                    },
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add answer'),
                  ),
                ),
                const SizedBox(height: 8),
                _SectionHeader(
                  title: 'Common misconceptions',
                  subtitle: 'Optional — drives targeted feedback',
                ),
                if (question.misconceptions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text('None added',
                        style:
                            TextStyle(fontSize: 12, color: AppColors.muted)),
                  ),
                for (var i = 0; i < question.misconceptions.length; i++)
                  _MisconceptionRowCard(
                    key: ObjectKey(question.misconceptions[i]),
                    entry: question.misconceptions[i],
                    index: i + 1,
                    onChanged: onChanged,
                    onDelete: () {
                      question.misconceptions.removeAt(i).dispose();
                      onChanged();
                    },
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      question.misconceptions
                          .add(_MisconceptionRow.blank());
                      onChanged();
                    },
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add misconception'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Row(
        children: [
          Text(title,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(subtitle!,
                  style: TextStyle(fontSize: 11, color: AppColors.muted)),
            ),
          ],
        ],
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    super.key,
    required this.step,
    required this.index,
    required this.onChanged,
    required this.onDelete,
  });

  final _StepRow step;
  final int index;
  final VoidCallback onChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text('$index',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.muted)),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<String>(
              initialValue: step.type,
              isDense: true,
              items: [
                for (final t in kBreakdownTypes)
                  DropdownMenuItem(value: t, child: Text(t, style: const TextStyle(fontSize: 12))),
              ],
              onChanged: (v) {
                step.type = v ?? 'method';
                onChanged();
              },
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 4,
            child: TextFormField(
              controller: step.criteria,
              decoration: const InputDecoration(
                  labelText: 'Criteria', isDense: true),
              onChanged: (_) => onChanged(),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 64,
            child: TextFormField(
              controller: step.marks,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: 'Marks', isDense: true),
              onChanged: (_) => onChanged(),
            ),
          ),
          IconButton(
            tooltip: 'Remove step',
            onPressed: onDelete,
            icon: Icon(Icons.close, size: 18, color: AppColors.danger),
          ),
        ],
      ),
    );
  }
}

class _AnswerRowCard extends StatelessWidget {
  const _AnswerRowCard({
    super.key,
    required this.answer,
    required this.index,
    required this.onChanged,
    required this.onPrimary,
    required this.onDelete,
  });

  final _AnswerRow answer;
  final int index;
  final VoidCallback onChanged;
  final VoidCallback onPrimary;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final normalized = normalizeAnswer(answer.text.text);
    return Card(
      elevation: 0,
      color: AppColors.brand.withValues(alpha: .04),
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 22,
                  child: Text('$index',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.muted)),
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message: answer.isPrimary
                      ? 'Primary answer (full marks)'
                      : 'Mark as primary',
                  child: InkWell(
                    onTap: onPrimary,
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        answer.isPrimary ? Icons.star : Icons.star_border,
                        size: 20,
                        color: answer.isPrimary
                            ? AppTheme.gold
                            : AppColors.muted,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 4,
                  child: TextFormField(
                    controller: answer.text,
                    decoration: const InputDecoration(
                        labelText: 'Answer text', isDense: true),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 64,
                  child: TextFormField(
                    controller: answer.marks,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Marks', isDense: true),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove answer',
                  onPressed: onDelete,
                  icon: Icon(Icons.close, size: 18, color: AppColors.danger),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 2),
              child: Text(
                normalized.isEmpty
                    ? 'normalized form appears as you type'
                    : 'normalized: $normalized',
                style: TextStyle(fontSize: 11, color: AppColors.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MisconceptionRowCard extends StatelessWidget {
  const _MisconceptionRowCard({
    super.key,
    required this.entry,
    required this.index,
    required this.onChanged,
    required this.onDelete,
  });

  final _MisconceptionRow entry;
  final int index;
  final VoidCallback onChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: AppColors.danger.withValues(alpha: .04),
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: Text('$index',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.muted)),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: entry.pattern,
                decoration: const InputDecoration(
                  labelText: 'Wrong answer pattern',
                  hintText: 'e.g. 1/4',
                  isDense: true,
                ),
                onChanged: (_) => onChanged(),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: entry.cause,
                decoration: const InputDecoration(
                  labelText: 'Likely cause',
                  hintText: 'e.g. inverted the fraction',
                  isDense: true,
                ),
                onChanged: (_) => onChanged(),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 64,
              child: TextFormField(
                controller: entry.marks,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Marks', isDense: true),
                onChanged: (_) => onChanged(),
              ),
            ),
            IconButton(
              tooltip: 'Remove misconception',
              onPressed: onDelete,
              icon: Icon(Icons.close, size: 18, color: AppColors.danger),
            ),
          ],
        ),
      ),
    );
  }
}

class _ValidationSummary extends StatelessWidget {
  const _ValidationSummary({required this.questions});

  final List<_EditableQuestion> questions;

  @override
  Widget build(BuildContext context) {
    final total = questions.length;
    final validBreakdowns =
        questions.where((q) => q.breakdownOk).length;
    final validPrimaries =
        questions.where((q) => q.primaryCount == 1).length;
    final allValid = total > 0 &&
        validBreakdowns == total &&
        validPrimaries == total;

    return Card(
      color: (allValid ? AppColors.success : AppColors.warning)
          .withValues(alpha: .08),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  allValid
                      ? Icons.check_circle
                      : Icons.warning_amber_rounded,
                  color:
                      allValid ? AppColors.success : AppColors.warning,
                ),
                const SizedBox(width: 8),
                Text(
                  allValid
                      ? 'Scheme ready to save'
                      : 'Fix issues before saving',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color:
                        allValid ? AppColors.success : AppColors.warning,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _ValidationRow(
              label: 'Questions',
              value: '$total',
              ok: total > 0,
            ),
            _ValidationRow(
              label: 'Breakdown sums match totals',
              value: '$validBreakdowns / $total',
              ok: total > 0 && validBreakdowns == total,
            ),
            _ValidationRow(
              label: 'Exactly one primary answer per question',
              value: '$validPrimaries / $total',
              ok: total > 0 && validPrimaries == total,
            ),
          ],
        ),
      ),
    );
  }
}

class _ValidationRow extends StatelessWidget {
  const _ValidationRow({
    required this.label,
    required this.value,
    required this.ok,
  });

  final String label;
  final String value;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check : Icons.close,
            size: 16,
            color: ok ? AppColors.success : AppColors.danger,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: ok ? AppColors.success : AppColors.danger,
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewTile extends StatelessWidget {
  const _PreviewTile({required this.question, required this.index});

  final _EditableQuestion question;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Q$index — ${question.totalMarks.toStringAsFixed(1)} marks',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < question.steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: Text(
                  '${i + 1}. [${question.steps[i].type}] '
                  '${question.steps[i].criteria.text} '
                  '(${question.steps[i].marks.text})',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            const SizedBox(height: 8),
            for (var i = 0; i < question.answers.length; i++)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: Row(
                  children: [
                    Icon(
                      question.answers[i].isPrimary
                          ? Icons.star
                          : Icons.star_border,
                      size: 14,
                      color: question.answers[i].isPrimary
                          ? AppTheme.gold
                          : AppColors.muted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '"${question.answers[i].text.text}" '
                        '→ ${question.answers[i].marks.text}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            if (question.misconceptions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Misconceptions',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.danger)),
              for (var i = 0; i < question.misconceptions.length; i++)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Text(
                    '"${question.misconceptions[i].pattern.text}" '
                    '→ ${question.misconceptions[i].cause.text}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
