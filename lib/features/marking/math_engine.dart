class MathCheck {
  final bool correct;
  final String reasoning;

  const MathCheck(this.correct, this.reasoning);
}

/// Section 24: mathematics is validated mathematically, not by string
/// comparison. Supports equivalent fractions, decimals, units and simple
/// algebraic solutions.
class MathMarkingEngine {
  static const _tolerance = 1e-6;

  MathCheck check(String expected, String student) {
    final e = _normalize(expected);
    final s = _normalize(student);
    if (e.isEmpty || s.isEmpty) {
      return MathCheck(false, 'No answer given');
    }
    final eVal = _asValue(e);
    final sVal = _asValue(s);
    if (eVal != null && sVal != null) {
      final pass = (eVal - sVal).abs() <= _tolerance;
      if (pass) {
        return MathCheck(true, 'Correct — value equivalent');
      }
      return MathCheck(
          false, 'Expected $e, got $s (values differ)');
    }
    final eRoot = _parseEquationValue(e);
    final sRoot = _parseEquationValue(s);
    if (eRoot != null && eRoot.isNotEmpty && sRoot != null && sRoot.isNotEmpty) {
      final pass = eRoot == sRoot;
      return MathCheck(
          pass, pass ? 'Correct — equivalent solution' : 'Expected $eRoot, got $sRoot');
    }
    if (e == s) {
      return MathCheck(true, 'Correct');
    }
    return MathCheck(false, 'Expected $e, got $s');
  }

  String _normalize(String raw) =>
      raw.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  double? _asValue(String s) {
    final frac = _fractionValue(s);
    if (frac != null) return frac;
    return _parseNumber(s);
  }

  double? _parseNumber(String s) {
    final withoutUnit = s
        .replaceAll(RegExp(r'\b(cm|mm|m|km|kg|g|l|ml|min|hr|h|sec|s|pesewas|ghc)\b'), '')
        .trim();
    final cleaned = withoutUnit
        .replaceAll('x', '*')
        .replaceAll('×', '*')
        .replaceAll('÷', '/')
        .replaceAll(',', '');
    try {
      return double.parse(cleaned);
    } catch (_) {
      return null;
    }
  }

  (double, double)? _parseFractionPair(String s) {
    final m = RegExp(r'^(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)$').firstMatch(s);
    if (m == null) return null;
    final num = double.tryParse(m.group(1)!);
    final den = double.tryParse(m.group(2)!);
    if (num == null || den == null || den == 0) return null;
    return (num, den);
  }

  double? _fractionValue(String s) {
    final pair = _parseFractionPair(s);
    return pair == null ? null : pair.$1 / pair.$2;
  }

  String? _parseEquationValue(String s) {
    final m =
        RegExp(r'(?:^|\s)(x|y)\s*=\s*([+-]?\d+(?:\.\d+)?)').firstMatch(s);
    if (m == null) return null;
    return m.group(2);
  }
}