import 'package:flutter_test/flutter_test.dart';
import 'package:solvanta/core/models/question.dart';
import 'package:solvanta/features/questions/question_gen_repository.dart';

void main() {
  final repo = QuestionGenRepository();

  List<Question> gen(QuestionType type, int count) => repo.draftFor(
        subjectId: 'SCI',
        topic: 'Photosynthesis',
        type: type,
        count: count,
        classId: 'JHS2A',
      );

  group('AI question generator', () {
    test('generates exactly the requested count, including 10 at once', () {
      expect(gen(QuestionType.mcq, 10).length, 10);
      expect(gen(QuestionType.shortAnswer, 20).length, 20);
    });

    test('every generated question carries a non-empty marking scheme', () {
      for (final type in [
        QuestionType.mcq,
        QuestionType.trueFalse,
        QuestionType.fillBlank,
        QuestionType.shortAnswer,
      ]) {
        for (final q in gen(type, 6)) {
          expect(q.markingScheme.trim(), isNotEmpty,
              reason: '${type.name} draft must have a marking scheme');
          expect(q.marks, greaterThan(0));
        }
      }
    });

    test('questions are not one-liners (stems carry a context + task)', () {
      for (final q in gen(QuestionType.mcq, 5)) {
        expect(q.stem.length, greaterThan(40),
            reason: 'stem should be more than a bare one-line prompt');
      }
    });

    test('a set of 10 is varied, not ten copies of one question', () {
      final stems = gen(QuestionType.mcq, 10).map((q) => q.stem).toSet();
      expect(stems.length, greaterThan(1),
          reason: 'generating 10 should not return identical stems');
    });

    test('MCQ drafts have options and a correct answer among them', () {
      for (final q in gen(QuestionType.mcq, 4)) {
        expect(q.options.length, greaterThanOrEqualTo(2));
        expect(q.options, contains(q.correctAnswer));
      }
    });

    test('true/false drafts resolve to True or False', () {
      for (final q in gen(QuestionType.trueFalse, 6)) {
        expect(['True', 'False'], contains(q.correctAnswer));
      }
    });
  });
}
