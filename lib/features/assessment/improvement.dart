import '../../core/models/assessment.dart';
import '../../core/models/submission.dart';

/// Subject-level before/after trend used in the Feedback → Correction →
/// Reassessment cycle (doc §32: compare performance before and after).
///
/// [assessmentDate] uses the same `YYYY-MM-DD` format as `Assessment.date`.
({double? before, double? after}) subjectTrend({
  required String studentId,
  required String subjectId,
  required String assessmentId,
  required String assessmentDate,
  required List<Assessment> assessments,
  required List<AssessmentSubmission> subs,
}) {
  final assessmentById = <String, Assessment>{
    for (final a in assessments) a.id: a,
  };
  final before = <double>[];
  final after = <double>[];
  for (final sub in subs) {
    if (sub.studentId != studentId || sub.assessmentId == assessmentId) {
      continue;
    }
    final a = assessmentById[sub.assessmentId];
    if (a == null || a.subjectId != subjectId || a.totalMarks <= 0) continue;
    final pct = 100 * sub.earned / a.totalMarks;
    final isBefore = sub.date.compareTo(assessmentDate) <= 0;
    (isBefore ? before : after).add(pct);
  }
  double avg(List<double> xs) =>
      xs.isEmpty ? double.nan : xs.reduce((a, b) => a + b) / xs.length;

  return (
    before: before.isEmpty ? null : avg(before),
    after: after.isEmpty ? null : avg(after),
  );
}