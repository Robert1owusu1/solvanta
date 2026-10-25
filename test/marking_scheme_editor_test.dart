import 'package:flutter_test/flutter_test.dart';
import 'package:solvanta/features/assessment/marking_scheme_editor_screen.dart';

void main() {
  group('misconception patterns', () {
    test('are saved as typed, symbols intact', () {
      // The matching engine tells "4/10" from "410"; the stored pattern must
      // too, or every misconception match is ambiguous.
      expect(storedMisconceptionPattern('4/10'), '4/10');
      expect(storedMisconceptionPattern(' -3.5 cm '), '-3.5 cm');
      expect(storedMisconceptionPattern('4/10'),
          isNot(storedMisconceptionPattern('410')));
    });

    test('normalizeAnswer is still the lossy display key', () {
      // Unchanged for accepted answers' normalizedForm, which the engine
      // does not use for matching.
      expect(normalizeAnswer('4/10'), '410');
    });
  });
}
