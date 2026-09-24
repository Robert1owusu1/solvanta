import 'package:flutter_test/flutter_test.dart';
import 'package:solvanta/features/marking/math_engine.dart';

void main() {
  final engine = MathMarkingEngine();

  test('equivalent fractions match', () {
    expect(engine.check('8/10', '4/5').correct, isTrue);
    expect(engine.check('8/10', '0.8').correct, isTrue);
  });

  test('different values do not match', () {
    expect(engine.check('8/10', '3/4').correct, isFalse);
    expect(engine.check('8/10', '0.75').correct, isFalse);
  });

  test('units are tolerated and compared', () {
    expect(engine.check('8', '8 m').correct, isTrue);
    expect(engine.check('2 kg', '2').correct, isTrue);
  });

  test('blank answers are rejected', () {
    expect(engine.check('8/10', '').correct, isFalse);
  });
}