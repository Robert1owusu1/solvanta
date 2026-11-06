import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/question.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';

/// Editable review of AI-generated drafts (doc §43). The teacher can rewrite
/// any question, change its marks, set the correct answer and — for every
/// question — edit the marking scheme before approving the set into the bank.
///
/// Returns the edited list of [Question]s on approve, or `null` if the teacher
/// backs out. A separate [onReject] signals an explicit rejection.
class QuestionDraftReviewScreen extends StatefulWidget {
  const QuestionDraftReviewScreen({
    super.key,
    required this.topic,
    required this.drafts,
  });

  final String topic;
  final List<Question> drafts;

  @override
  State<QuestionDraftReviewScreen> createState() =>
      _QuestionDraftReviewScreenState();
}

class _QuestionDraftReviewScreenState
    extends State<QuestionDraftReviewScreen> {
  late final List<_DraftEditor> _editors;

  @override
  void initState() {
    super.initState();
    _editors = [for (final q in widget.drafts) _DraftEditor(q)];
  }

  @override
  void dispose() {
    for (final e in _editors) {
      e.dispose();
    }
    super.dispose();
  }

  String? _validate() {
    for (final (i, e) in _editors.indexed) {
      final n = i + 1;
      if (e.stemCtrl.text.trim().isEmpty) {
        return 'Question $n needs a stem.';
      }
      final marks = double.tryParse(e.marksCtrl.text.trim());
      if (marks == null || marks <= 0) {
        return 'Question $n needs marks greater than zero.';
      }
      if (e.markingCtrl.text.trim().isEmpty) {
        return 'Question $n needs a marking scheme.';
      }
      if (e.source.type == QuestionType.mcq) {
        final opts = e.optionCtrls
            .map((c) => c.text.trim())
            .where((t) => t.isNotEmpty)
            .toList();
        if (opts.length < 2) {
          return 'Question $n needs at least two options.';
        }
        if (e.correct == null || e.correct!.trim().isEmpty) {
          return 'Question $n needs a correct option selected.';
        }
      }
    }
    return null;
  }

  void _approve() {
    final err = _validate();
    if (err != null) {
      svSnack(context, err, error: true);
      return;
    }
    final edited = [for (final e in _editors) e.build()];
    Navigator.pop(context, edited);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Review drafts — ${widget.topic}'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          Card(
            color: AppTheme.brand.withValues(alpha: .05),
            child: ListTile(
              leading: Icon(Icons.edit_note, color: AppColors.brand),
              title: const Text('Edit before you approve',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                  'These are drafts. Edit the wording, marks, correct answer '
                  'and marking scheme of any question. Nothing reaches the '
                  'question bank until you approve.',
                  style: TextStyle(color: AppColors.body)),
              isThreeLine: true,
            ),
          ),
          const SizedBox(height: 8),
          for (final (i, e) in _editors.indexed)
            _DraftCard(index: i + 1, editor: e, onChanged: () => setState(() {})),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context, const <Question>[]),
                  icon: const Icon(Icons.close),
                  label: const Text('Reject all'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _approve,
                  icon: const Icon(Icons.check),
                  label: Text('Approve ${_editors.length} question(s)'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Holds the live controllers for one draft while it is being edited.
class _DraftEditor {
  _DraftEditor(this.source)
      : stemCtrl = TextEditingController(text: source.stem),
        marksCtrl =
            TextEditingController(text: source.marks.toStringAsFixed(
                source.marks == source.marks.roundToDouble() ? 0 : 1)),
        answerCtrl = TextEditingController(text: source.correctAnswer),
        markingCtrl = TextEditingController(text: source.markingScheme),
        optionCtrls = [
          for (final o in (source.options.isEmpty &&
                  source.type == QuestionType.mcq
              ? const ['', '', '', '']
              : source.options))
            TextEditingController(text: o),
        ],
        correct = source.type == QuestionType.trueFalse
            ? (source.correctAnswer.isEmpty ? 'True' : source.correctAnswer)
            : source.correctAnswer;

  final Question source;
  final TextEditingController stemCtrl;
  final TextEditingController marksCtrl;
  final TextEditingController answerCtrl;
  final TextEditingController markingCtrl;
  final List<TextEditingController> optionCtrls;

  /// Selected correct answer for MCQ (one of the option texts) / True-False.
  String? correct;

  Question build() {
    final marks = double.tryParse(marksCtrl.text.trim()) ?? source.marks;
    final opts = source.type == QuestionType.mcq
        ? optionCtrls
            .map((c) => c.text.trim())
            .where((t) => t.isNotEmpty)
            .toList()
        : source.options;
    final answer = switch (source.type) {
      QuestionType.mcq => correct ?? '',
      QuestionType.trueFalse => correct ?? 'True',
      _ => answerCtrl.text.trim(),
    };
    return source.copyWith(
      stem: stemCtrl.text.trim(),
      marks: marks,
      options: opts,
      correctAnswer: answer,
      markingScheme: markingCtrl.text.trim(),
    );
  }

  void dispose() {
    stemCtrl.dispose();
    marksCtrl.dispose();
    answerCtrl.dispose();
    markingCtrl.dispose();
    for (final c in optionCtrls) {
      c.dispose();
    }
  }
}

class _DraftCard extends StatelessWidget {
  const _DraftCard({
    required this.index,
    required this.editor,
    required this.onChanged,
  });

  final int index;
  final _DraftEditor editor;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final type = editor.source.type;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: AppColors.brand.withValues(alpha: .15),
                  child: Text('$index',
                      style: TextStyle(
                          color: AppColors.brand,
                          fontWeight: FontWeight.w700,
                          fontSize: 13)),
                ),
                const SizedBox(width: 8),
                Text(type.label,
                    style: TextStyle(
                        color: AppColors.body,
                        fontWeight: FontWeight.w600,
                        fontSize: 12)),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: editor.stemCtrl,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Question',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 10),
            if (type == QuestionType.mcq) ...[
              Text('Options (tap the circle to mark the correct one)',
                  style: TextStyle(fontSize: 12, color: AppColors.body)),
              const SizedBox(height: 4),
              for (final c in editor.optionCtrls)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          editor.correct == c.text && c.text.isNotEmpty
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color: editor.correct == c.text && c.text.isNotEmpty
                              ? AppColors.correct
                              : AppColors.body,
                        ),
                        onPressed: () {
                          editor.correct = c.text;
                          onChanged();
                        },
                      ),
                      Expanded(
                        child: TextField(
                          controller: c,
                          onChanged: (_) => onChanged(),
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: 'Option text',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ] else if (type == QuestionType.trueFalse) ...[
              Text('Correct answer',
                  style: TextStyle(fontSize: 12, color: AppColors.body)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  for (final v in const ['True', 'False'])
                    ChoiceChip(
                      label: Text(v),
                      selected: editor.correct == v,
                      onSelected: (_) {
                        editor.correct = v;
                        onChanged();
                      },
                    ),
                ],
              ),
            ] else ...[
              TextField(
                controller: editor.answerCtrl,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Model / accepted answer (optional)',
                ),
              ),
            ],
            const SizedBox(height: 10),
            SizedBox(
              width: 120,
              child: TextField(
                controller: editor.marksCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(labelText: 'Marks'),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: editor.markingCtrl,
              minLines: 2,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Marking scheme',
                alignLabelWithHint: true,
                helperText: 'How a marker should award the marks above.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
