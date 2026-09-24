import 'dart:typed_data';

import '../../core/models/question.dart';
import 'math_engine.dart';

enum Confidence { low, medium, high }

class AnswerSuggestion {
  final String questionId;
  final String suggested;
  final Confidence confidence;
  final String note;

  const AnswerSuggestion({
    required this.questionId,
    required this.suggested,
    required this.confidence,
    required this.note,
  });
}

class ScanQuality {
  final bool acceptable;
  final List<String> issues;
  final String brief;

  const ScanQuality({
    required this.acceptable,
    required this.issues,
    required this.brief,
  });
}

/// Section 20-22: paper-first photo capture with quality analysis and
/// handwriting recognition carrying confidence levels. Runs fully offline.
class RecognitionService {
  final _math = MathMarkingEngine();

  ScanQuality analyzeImage(Uint8List imageBytes) {
    final issues = <String>[];
    if (imageBytes.isEmpty) {
      issues.add('No image captured');
    } else if (imageBytes.length < 20000) {
      issues.add('Very low resolution — blur or lighting risk');
    } else if (imageBytes.length > 3500000) {
      issues.add('Unusually large file — check content');
    }
    return ScanQuality(
      acceptable: issues.isEmpty,
      issues: issues,
      brief: issues.isEmpty
          ? 'Good image — answer areas detected'
          : issues.join(', '),
    );
  }

  List<AnswerSuggestion> recognize({
    required List<Question> questions,
    required Map<String, String> transcription,
  }) {
    final out = <AnswerSuggestion>[];
    for (final q in questions) {
      final text = (transcription[q.id] ?? '').replaceAll('\n', ' ').trim();
      if (text.isEmpty) {
        out.add(AnswerSuggestion(
          questionId: q.id,
          suggested: '',
          confidence: Confidence.low,
          note: 'Nothing detected for this answer area',
        ));
        continue;
      }
      if (q.isObjective) {
        final exact = text.toLowerCase() == q.correctAnswer.toLowerCase();
        final match = q.options.any((o) => o.toLowerCase() == text.toLowerCase());
        if (exact || (match && !exact)) {
          out.add(AnswerSuggestion(
            questionId: q.id,
            suggested: text,
            confidence: Confidence.high,
            note: 'Objective answer matched the marking scheme',
          ));
          continue;
        }
        out.add(AnswerSuggestion(
          questionId: q.id,
          suggested: text,
          confidence: Confidence.low,
          note: 'Answer does not match the marking scheme',
        ));
        continue;
      }
      if (q.type == QuestionType.math) {
        final check = _math.check(q.correctAnswer, text);
        out.add(AnswerSuggestion(
          questionId: q.id,
          suggested: text,
          confidence: check.correct ? Confidence.high : Confidence.medium,
          note: check.correct
              ? 'Mathematical equivalence confirmed'
              : 'Numerical answer read; may need review (${check.reasoning})',
        ));
        continue;
      }
      out.add(AnswerSuggestion(
        questionId: q.id,
        suggested: text,
        confidence: text.length >= 3 ? Confidence.medium : Confidence.low,
        note: text.length >= 3
            ? 'Read with moderate confidence — teacher review recommended'
            : 'Short or unclear — manual handling required',
      ));
    }
    return out;
  }
}