import '../../core/models/question.dart';
import '../marking/math_engine.dart';

/// Section 24 / 51 (non-AI): deterministic, rule-based marking suggestions so
/// teachers only review the borderline cases.
class RuleMarkingEngine {
  final MathMarkingEngine _math = MathMarkingEngine();

  String _norm(String s) =>
      s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Splits a marking scheme (expected answer + key points) into tokens.
  List<String> keywords(String scheme) {
    return scheme
        .split(RegExp(r'[;\n,·•]+'))
        .map((k) => k.trim().toLowerCase())
        .where((k) => k.isNotEmpty && k.length >= 3)
        .toList();
  }

  /// Returns a suggested mark + short note. [confident] means it can be
  /// applied without teacher review under normal quality assurance.
  ({double mark, String note, bool confident}) suggest(
      Question q, String answer) {
    final text = _norm(answer);
    if (text.isEmpty) {
      return (mark: 0, note: 'No answer given', confident: true);
    }

    // Objecectives are exact-match.
    if (q.isObjective) {
      final correct = text == _norm(q.correctAnswer);
      return (
        mark: correct ? q.marks : 0,
        note: correct
            ? 'Matches marking scheme'
            : 'Does not match the scheme',
        confident: true,
      );
    }

    if (q.type == QuestionType.math) {
      final check = _math.check(q.correctAnswer, answer);
      if (check.correct) {
        return (mark: q.marks, note: 'Mathematically correct', confident: true);
      }
      // Partial credit: fraction/decimal correspondence or plausible numeric.
      final numeric = double.tryParse(text.replaceAll(RegExp(r'[^0-9.\-]'), ''));
      if (numeric != null) {
        final expected = double.tryParse(
            q.correctAnswer.replaceAll(RegExp(r'[^0-9.\-]'), ''));
        if (expected != null && (numeric - expected).abs() <= 1e-6) {
          return (
            mark: q.marks,
            note: 'Correct value with extra text',
            confident: true,
          );
        }
        return (
          mark: q.marks * 0.5,
          note: 'Numerical answer given — partial credit',
          confident: false,
        );
      }
      return (mark: 0, note: check.reasoning, confident: false);
    }

    // Written answers: exact or keyword based.
    final expected = _norm(q.correctAnswer);
    if (expected.isNotEmpty && text == expected) {
      return (mark: q.marks, note: 'Matches expected answer', confident: true);
    }

    final schemeText = q.markingScheme.isNotEmpty
        ? q.markingScheme
        : '${q.correctAnswer}; ${q.explanation}';
    final keys = keywords(schemeText);
    if (keys.isEmpty) {
      return (
        mark: 0,
        note: 'No markable scheme keywords — teacher judgement',
        confident: false,
      );
    }
    final present = keys.where((k) => text.contains(k)).toList();
    if (present.isEmpty) {
      return (
        mark: 0,
        note: 'Answer given but no scheme keywords found',
        confident: false,
      );
    }
    final allPresent = present.length >= keys.length;
    if (allPresent) {
      return (mark: q.marks, note: 'All key points present', confident: true);
    }
    // Partial credit is proportional to the key points covered. No fixed
    // floor, so one keyword out of five earns 20% — a genuine, reviewable
    // suggestion rather than a lenient default.
    final fraction = present.length / keys.length;
    return (
      mark: q.marks * fraction,
      note: '${present.length}/${keys.length} key points: '
          '${present.join(', ')}',
      confident: false,
    );
  }
}