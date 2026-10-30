import 'grading.dart';

/// The end-of-year decision applied to one student for one academic year
/// (mirrors the server's `promotions` records). Keyed by year and student,
/// so a year can never be applied twice.
class PromotionRecord {
  final String studentId;

  /// The class the year was sat in, and where the student goes (the same
  /// class when they repeat; empty when they complete school).
  final String classId;
  final String toClassId;
  final String year;
  final YearOutcome outcome;
  final double? average;
  final String appliedAt;
  final String appliedBy;

  const PromotionRecord({
    required this.studentId,
    required this.classId,
    required this.toClassId,
    required this.year,
    required this.outcome,
    this.average,
    this.appliedAt = '',
    this.appliedBy = '',
  });

  /// `2026-2027-STU-001` — safe in a URL path.
  static String idFor(String year, String studentId) =>
      '${year.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-')}-$studentId';

  String get id => idFor(year, studentId);

  factory PromotionRecord.fromJson(Map<String, dynamic> json) =>
      PromotionRecord(
        studentId: (json['studentId'] ?? '') as String,
        classId: (json['classId'] ?? '') as String,
        toClassId: (json['toClassId'] ?? '') as String,
        year: (json['year'] ?? '') as String,
        outcome: YearOutcome.values.firstWhere(
          (o) => o.name == json['outcome'],
          orElse: () => YearOutcome.review,
        ),
        average: (json['average'] as num?)?.toDouble(),
        appliedAt: (json['appliedAt'] ?? '') as String,
        appliedBy: (json['appliedBy'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'studentId': studentId,
    'classId': classId,
    'toClassId': toClassId,
    'year': year,
    'outcome': outcome.name,
    if (average != null) 'average': average,
    'appliedAt': appliedAt,
    'appliedBy': appliedBy,
  };
}
