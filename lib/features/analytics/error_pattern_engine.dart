import '../../core/models/question.dart';
import '../../core/models/submission.dart';

/// Section 29 (rule-based, non-AI): surface repeated misconceptions rather
/// than treating every wrong answer as isolated.
class ErrorPattern {
  final String label;
  final int count;
  final String detail;

  const ErrorPattern({
    required this.label,
    required this.count,
    required this.detail,
  });
}

class ErrorPatternAnalyzer {
  List<ErrorPattern> analyze({
    required List<Question> questions,
    required AssessmentSubmission sub,
  }) {
    final buckets = <String, List<String>>{};
    void add(String label, String detail) =>
        buckets[label] = [...(buckets[label] ?? []), detail];

    for (final q in questions) {
      final answer = (sub.answers[q.id] ?? '').trim();
      if (answer.isEmpty) {
        add('Not attempted', '${q.topic}: "${q.stem}" was left blank');
        continue;
      }
      final isCorrect = q.isObjective
          ? answer.toLowerCase() == q.correctAnswer.trim().toLowerCase()
          : (sub.teacherMarks[q.id] ?? 0) >= q.marks * 0.8;
      if (isCorrect) continue;

      final norm = answer.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

      if (q.type == QuestionType.math) {
        final hasUnit = RegExp(r'(cm|mm|m|km|kg|g|l|ml|hr|h|min|pesewas|ghc)')
            .hasMatch(q.correctAnswer.toLowerCase());
        final signed = RegExp(r'[-+]').hasMatch(q.correctAnswer);
        final decimal = q.correctAnswer.contains('.');
        if (hasUnit && !RegExp(r'(cm|mm|m|km|kg|g|l|ml|hr|h|min|pesewas|ghc)')
            .hasMatch(norm)) {
          add('Missing unit', 'Expected a unit in "${q.topic}" but none given');
        } else if (signed &&
            RegExp(r'-').hasMatch(q.correctAnswer) != RegExp(r'-').hasMatch(norm)) {
          add('Sign error', 'Positive/negative sign mismatch on "${q.stem}"');
        } else if (decimal && !norm.contains('.')) {
          add('Decimal misplacement', 'Decimals not handled on "${q.stem}"');
        } else {
          add('Math operation error',
              'Incorrect working on "${q.topic}" — check operations');
        }
      } else if (q.type == QuestionType.fillBlank ||
          q.type == QuestionType.shortAnswer) {
        final scheme =
            (q.markingScheme.isNotEmpty ? q.markingScheme : q.explanation)
                .toLowerCase();
        final keys = scheme
            .split(RegExp(r'[;\n,·]'))
            .map((k) => k.trim())
            .where((k) => k.length >= 3);
        final hit = keys.any((k) => norm.contains(k));
        if (hit) {
          add('Partially correct',
              'Concept present but answer incomplete for "${q.topic}"');
        } else {
add('Off-topic answer',
            'Answer does not address the question: "${q.topic}"');
        }
      } else {
        add('Incomplete written answer',
            'Partial marks on "${q.topic}" — review to give feedback');
      }
    }

    final out = [
      for (final e in buckets.entries)
        ErrorPattern(label: e.key, count: e.value.length, detail: e.value.first),
    ]..sort((a, b) => b.count.compareTo(a.count));
    return out;
  }
}