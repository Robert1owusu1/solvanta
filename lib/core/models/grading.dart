import 'class_room.dart';
import 'school_term.dart';

/// One row of a grading scale: a total of [min] or more (up to the next
/// band's [min]) earns [grade], described by [remark].
class GradeBand {
  final double min;
  final String grade;
  final String remark;

  const GradeBand(this.min, this.grade, this.remark);

  factory GradeBand.fromJson(Map<String, dynamic> json) => GradeBand(
        ((json['min'] ?? 0) as num).toDouble(),
        (json['grade'] ?? '') as String,
        (json['remark'] ?? '') as String,
      );

  Map<String, dynamic> toJson() =>
      {'min': min, 'grade': grade, 'remark': remark};
}

/// How one range of classes is scored and graded (mirrors the server's
/// `domain.GradingScheme`, which re-checks every rule on save).
class GradingScheme {
  final String id;
  final String name;

  /// Class levels without the stream (`JHS1`, `B4`, `KG2`). Empty on the
  /// default scheme, which covers every class no other scheme names.
  final List<String> classNames;
  final bool isDefault;

  /// Continuous assessment and end-of-term exam, adding up to 100.
  final double classWeight;
  final double examWeight;

  /// Highest first; the last starts at 0.
  final List<GradeBand> bands;

  /// Sum of the [coreSubjects] grades plus the best [bestOthers] others
  /// (lower is better). Needs whole-number grades.
  final bool showAggregate;
  final List<String> coreSubjects;
  final int bestOthers;

  /// End of year, on the full-year average (the mean of the year's term
  /// averages, each out of 100 — Terms 1–3 make a total out of 300).
  /// `null` leaves that decision to the school.
  ///
  /// [promoteAt] or more is promoted; under [repeatBelow] repeats the class;
  /// in between is referred to the headteacher. Under [interventionBelow]
  /// the parents are asked in, on any report from Term 2 on.
  final double? promoteAt;
  final double? repeatBelow;
  final double? interventionBelow;

  const GradingScheme({
    required this.id,
    required this.name,
    this.classNames = const [],
    this.isDefault = false,
    required this.classWeight,
    required this.examWeight,
    required this.bands,
    this.showAggregate = false,
    this.coreSubjects = const [],
    this.bestOthers = 0,
    this.promoteAt,
    this.repeatBelow,
    this.interventionBelow,
  });

  factory GradingScheme.fromJson(Map<String, dynamic> json) => GradingScheme(
        id: (json['id'] ?? '') as String,
        name: (json['name'] ?? '') as String,
        classNames: [
          for (final n in (json['classNames'] ?? const []) as List) n as String
        ],
        isDefault: (json['isDefault'] ?? false) as bool,
        classWeight: ((json['classWeight'] ?? 30) as num).toDouble(),
        examWeight: ((json['examWeight'] ?? 70) as num).toDouble(),
        bands: [
          for (final b in (json['bands'] ?? const []) as List)
            GradeBand.fromJson(b as Map<String, dynamic>)
        ]..sort((a, b) => b.min.compareTo(a.min)),
        showAggregate: (json['showAggregate'] ?? false) as bool,
        coreSubjects: [
          for (final s in (json['coreSubjects'] ?? const []) as List)
            s as String
        ],
        bestOthers: ((json['bestOthers'] ?? 0) as num).toInt(),
        promoteAt: (json['promoteAt'] as num?)?.toDouble(),
        repeatBelow: (json['repeatBelow'] as num?)?.toDouble(),
        interventionBelow: (json['interventionBelow'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'classNames': classNames,
        'isDefault': isDefault,
        'classWeight': classWeight,
        'examWeight': examWeight,
        'bands': bands.map((b) => b.toJson()).toList(),
        'showAggregate': showAggregate,
        'coreSubjects': coreSubjects,
        'bestOthers': bestOthers,
        if (promoteAt != null) 'promoteAt': promoteAt,
        if (repeatBelow != null) 'repeatBelow': repeatBelow,
        if (interventionBelow != null) 'interventionBelow': interventionBelow,
      };

  GradingScheme copyWith({
    String? name,
    List<String>? classNames,
    bool? isDefault,
    double? classWeight,
    double? examWeight,
    List<GradeBand>? bands,
    bool? showAggregate,
    List<String>? coreSubjects,
    int? bestOthers,
  }) =>
      GradingScheme(
        id: id,
        name: name ?? this.name,
        classNames: classNames ?? this.classNames,
        isDefault: isDefault ?? this.isDefault,
        classWeight: classWeight ?? this.classWeight,
        examWeight: examWeight ?? this.examWeight,
        bands: bands ?? this.bands,
        showAggregate: showAggregate ?? this.showAggregate,
        coreSubjects: coreSubjects ?? this.coreSubjects,
        bestOthers: bestOthers ?? this.bestOthers,
        promoteAt: promoteAt,
        repeatBelow: repeatBelow,
        interventionBelow: interventionBelow,
      );

  /// This scheme with its end-of-year thresholds set exactly as given
  /// (`null` turns one off) — [copyWith] can't clear a field.
  GradingScheme withYearRules({
    double? promoteAt,
    double? repeatBelow,
    double? interventionBelow,
  }) =>
      GradingScheme.fromJson({
        ...toJson()
          ..remove('promoteAt')
          ..remove('repeatBelow')
          ..remove('interventionBelow'),
        'promoteAt': ?promoteAt,
        'repeatBelow': ?repeatBelow,
        'interventionBelow': ?interventionBelow,
      });

  /// The year rules as one line (`Promoted at 50 or above · Repeats below
  /// 40 · Parent meeting below 45`), or `''` when none are set.
  String get yearRulesLine => [
        if (promoteAt != null) 'Promoted at ${_fmt(promoteAt!)} or above',
        if (repeatBelow != null) 'Repeats below ${_fmt(repeatBelow!)}',
        if (interventionBelow != null)
          'Parent meeting below ${_fmt(interventionBelow!)}',
      ].join(' · ');

  /// True when the school has set an automatic promotion rule.
  bool get decidesPromotion => promoteAt != null || repeatBelow != null;

  /// The end-of-year outcome for a full-year [average], or `null` when the
  /// school leaves it to the headteacher. With only one threshold set, it
  /// splits the year in two; with both, the gap between is [YearOutcome.review].
  YearOutcome? outcomeFor(double average, {required bool finalClass}) {
    final a = (average * 10).round() / 10; // as printed
    final promote = promoteAt ?? repeatBelow;
    final repeat = repeatBelow ?? promoteAt;
    if (promote == null || repeat == null) return null;
    if (a >= promote) {
      return finalClass ? YearOutcome.completed : YearOutcome.promoted;
    }
    if (a < repeat) return YearOutcome.repeated;
    return YearOutcome.review;
  }

  /// True when a running year [average] calls for a parent conference.
  bool needsIntervention(double average) =>
      interventionBelow != null && (average * 10).round() / 10 < interventionBelow!;

  /// The band a 0–100 [total] falls in (rounded, as printed).
  GradeBand bandFor(double total) {
    final t = total.round();
    return bands.firstWhere((b) => t >= b.min, orElse: () => bands.last);
  }

  /// `min–max` for the band at [i], e.g. `80–100`, `70–79`.
  String rangeOf(int i) {
    final lo = _fmt(bands[i].min);
    final hi = i == 0 ? '100' : _fmt(bands[i - 1].min - 1);
    return '$lo-$hi';
  }

  /// True when every grade is a whole number, so grades can be summed.
  bool get numericGrades =>
      bands.every((b) => int.tryParse(b.grade.trim()) != null);

  /// `Class 40% · Exam 60% · 1–9`, for list tiles.
  String get summary =>
      'Class ${_fmt(classWeight)}% · Exam ${_fmt(examWeight)}% · '
      '${bands.first.grade}–${bands.last.grade}';

  /// The first rule this scheme breaks, or `null` when it is valid. The
  /// server applies the same rules (see `domain.GradingConfig.Normalize`).
  String? problem() {
    if (name.trim().isEmpty) return 'Give the scheme a name.';
    if (!isDefault && classNames.isEmpty) {
      return '$name: choose the classes it applies to.';
    }
    if (classWeight < 0 || examWeight < 0 || classWeight + examWeight != 100) {
      return '$name: class score and exam must add up to 100%.';
    }
    if (bands.isEmpty) return '$name: add at least one grade band.';
    if (bands.length > 15) return '$name: at most 15 grade bands.';
    final mins = <double>{};
    for (final b in bands) {
      if (b.min < 0 || b.min > 100) {
        return '$name: band minimums must be between 0 and 100.';
      }
      if (!mins.add(b.min)) return '$name: two bands start at ${_fmt(b.min)}.';
      if (b.grade.trim().isEmpty || b.grade.trim().length > 4) {
        return '$name: every band needs a grade (up to 4 characters).';
      }
      if (b.remark.trim().length > 24) {
        return '$name: remark "${b.remark}" is too long (24 max).';
      }
    }
    if (!mins.contains(0)) return '$name: the lowest band must start at 0.';
    if (showAggregate && !numericGrades) {
      return '$name: an aggregate needs whole-number grades (1, 2, 3…).';
    }
    for (final t in [promoteAt, repeatBelow, interventionBelow]) {
      if (t != null && (t < 0 || t > 100)) {
        return '$name: year-average thresholds must be between 0 and 100.';
      }
    }
    if (promoteAt != null && repeatBelow != null && repeatBelow! > promoteAt!) {
      return "$name: the repeat mark can't be above the promotion mark.";
    }
    return null;
  }
}

/// What the end of the year decides for a student.
enum YearOutcome {
  promoted('Promoted'),
  repeated('Repeated'),
  review('Referred to the headteacher'),
  completed('Completed');

  const YearOutcome(this.label);

  final String label;
}

/// One school's grading set-up (mirrors `domain.GradingConfig`).
class GradingConfig {
  final String schoolId;
  final List<GradingScheme> schemes;
  final String updatedAt;
  final String updatedBy;

  const GradingConfig({
    this.schoolId = '',
    required this.schemes,
    this.updatedAt = '',
    this.updatedBy = '',
  });

  factory GradingConfig.fromJson(Map<String, dynamic> json) => GradingConfig(
        schoolId: (json['schoolId'] ?? '') as String,
        schemes: [
          for (final s in (json['schemes'] ?? const []) as List)
            GradingScheme.fromJson(s as Map<String, dynamic>)
        ],
        updatedAt: (json['updatedAt'] ?? '') as String,
        updatedBy: (json['updatedBy'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'schoolId': schoolId,
        'schemes': schemes.map((s) => s.toJson()).toList(),
        if (updatedAt.isNotEmpty) 'updatedAt': updatedAt,
        if (updatedBy.isNotEmpty) 'updatedBy': updatedBy,
      };

  /// What every school grades with until its admin saves its own — the
  /// server's `DefaultGradingConfig`.
  static final GradingConfig fallback = GradingConfig(
    schemes: [
      gesBasicPreset.copyWith(name: 'GES basic school', isDefault: true),
    ],
  );

  GradingScheme get defaultScheme =>
      schemes.firstWhere((s) => s.isDefault, orElse: () => schemes.first);

  /// The scheme for class [classId] (`JHS2A`). The class's level comes from
  /// [classes] when it is listed there, otherwise from the longest scheme
  /// class name [classId] starts with (`JHS2A` → `JHS2`).
  GradingScheme schemeFor(String classId,
      [List<ClassRoom> classes = const []]) {
    final id = classId.toUpperCase();
    final level = classes
        .where((c) => c.id.toUpperCase() == id)
        .map((c) => c.name.toUpperCase())
        .firstOrNull;
    if (level != null) {
      for (final s in schemes) {
        if (s.classNames.contains(level)) return s;
      }
    }
    GradingScheme? best;
    var bestLen = 0;
    for (final s in schemes) {
      for (final n in s.classNames) {
        if (id.startsWith(n) && n.length > bestLen) {
          best = s;
          bestLen = n.length;
        }
      }
    }
    return best ?? defaultScheme;
  }

  /// The first rule the config breaks, or `null` when it can be saved.
  String? problem() {
    if (schemes.isEmpty) return 'Add at least one grading scheme.';
    if (schemes.length > 20) return 'At most 20 grading schemes.';
    if (schemes.where((s) => s.isDefault).length != 1) {
      return 'Exactly one scheme must be the default for unlisted classes.';
    }
    final owner = <String, String>{};
    for (final s in schemes) {
      for (final n in s.classNames) {
        final other = owner[n];
        if (other != null) {
          return '$n is in both "$other" and "${s.name}"; a class can follow '
              'only one scheme.';
        }
        owner[n] = s.name;
      }
      final p = s.problem();
      if (p != null) return p;
    }
    return null;
  }
}

/// The school's grading set-up as last loaded, saved or synced on this
/// device. Charts, exports and results grade marks synchronously through
/// [schoolGrade]; `LocalStore` keeps this current.
abstract final class SchoolGrading {
  static GradingConfig current = GradingConfig.fallback;
}

/// [percent]'s grade under the school's scheme for [classId] (`2`, `B`, `C6`).
String schoolGrade(double percent, String classId) =>
    SchoolGrading.current.schemeFor(classId).bandFor(percent).grade;

String _fmt(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

// ---------------------------------------------------------------------------
// Presets the editor offers as starting points
// ---------------------------------------------------------------------------

/// GES basic school / BECE: 30/70, grades 1–9, aggregate of 4 cores + best 2.
const gesBasicPreset = GradingScheme(
  id: 'ges-basic',
  name: 'GES basic (1–9)',
  classWeight: 30,
  examWeight: 70,
  bands: [
    GradeBand(80, '1', 'Highest'),
    GradeBand(70, '2', 'Higher'),
    GradeBand(60, '3', 'High'),
    GradeBand(55, '4', 'High Average'),
    GradeBand(50, '5', 'Average'),
    GradeBand(45, '6', 'Low Average'),
    GradeBand(40, '7', 'Low'),
    GradeBand(35, '8', 'Lower'),
    GradeBand(0, '9', 'Lowest'),
  ],
  showAggregate: true,
  coreSubjects: ['ENG', 'MATH', 'SCI', 'SOC'],
  bestOthers: 2,
);

/// WAEC / WASSCE style: A1–F9.
const waecPreset = GradingScheme(
  id: 'waec',
  name: 'WAEC (A1–F9)',
  classWeight: 30,
  examWeight: 70,
  bands: [
    GradeBand(75, 'A1', 'Excellent'),
    GradeBand(70, 'B2', 'Very Good'),
    GradeBand(65, 'B3', 'Good'),
    GradeBand(60, 'C4', 'Credit'),
    GradeBand(55, 'C5', 'Credit'),
    GradeBand(50, 'C6', 'Credit'),
    GradeBand(45, 'D7', 'Pass'),
    GradeBand(40, 'E8', 'Pass'),
    GradeBand(0, 'F9', 'Fail'),
  ],
);

/// Simple letters, common in pre-school and primary.
const letterPreset = GradingScheme(
  id: 'letters',
  name: 'Letters (A–F)',
  classWeight: 50,
  examWeight: 50,
  bands: [
    GradeBand(80, 'A', 'Excellent'),
    GradeBand(70, 'B', 'Very Good'),
    GradeBand(60, 'C', 'Good'),
    GradeBand(50, 'D', 'Credit'),
    GradeBand(40, 'E', 'Pass'),
    GradeBand(0, 'F', 'Fail'),
  ],
);

const gradingPresets = [gesBasicPreset, waecPreset, letterPreset];

/// A term the school has moved on from, with the grading set-up in force
/// when it ended (mirrors `domain.FinishedTerm`), so its results are always
/// read the way they were awarded.
class FinishedTerm {
  final SchoolTerm term;
  final GradingConfig grading;

  const FinishedTerm(this.term, this.grading);

  factory FinishedTerm.fromJson(Map<String, dynamic> json) => FinishedTerm(
        SchoolTerm.fromJson(json),
        json['grading'] is Map<String, dynamic>
            ? GradingConfig.fromJson(json['grading'] as Map<String, dynamic>)
            : GradingConfig.fallback,
      );

  Map<String, dynamic> toJson() =>
      {...term.toJson(), 'grading': grading.toJson()};
}
