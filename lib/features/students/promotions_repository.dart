import '../../core/models/class_ladder.dart';
import '../../core/models/class_room.dart';
import '../../core/models/grading.dart';
import '../../core/models/promotion.dart';
import '../../core/models/student.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';
import '../audit/audit_repository.dart';
import 'students_repository.dart';

/// One student's end-of-year decision, ready to apply.
class YearEndDecision {
  const YearEndDecision({
    required this.student,
    required this.classId,
    required this.outcome,
    this.average,
  });

  final Student student;

  /// The class the year was sat in (from their marks, not their current
  /// class), so applying twice lands on the same class both times.
  final String classId;
  final YearOutcome outcome;
  final double? average;
}

/// Applies end-of-year decisions: moves promoted students up a class, marks
/// students who finished the final class as graduated, keeps repeaters where
/// they are — once per student per academic year.
class PromotionsRepository {
  PromotionsRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  /// Decisions already applied for [year], by student id.
  Future<Map<String, PromotionRecord>> appliedFor(String year) async => {
    for (final p in await _store.loadPromotions())
      if (p.year == year) p.studentId: p,
  };

  /// Applies [decisions] for [year] and returns how many were applied. A
  /// student already decided for [year] is skipped, and a
  /// [YearOutcome.review] is never applied — the headteacher chooses first.
  Future<int> apply(
    List<YearEndDecision> decisions, {
    required String year,
    required List<ClassRoom> classes,
    required String actor,
  }) async {
    final done = await appliedFor(year);
    final students = StudentsRepository(store: _store);
    final audit = AuditRepository();
    final stamp = DateTime.now().toIso8601String().substring(0, 16);
    var applied = 0;
    for (final d in decisions) {
      if (done.containsKey(d.student.id) || d.outcome == YearOutcome.review) {
        continue;
      }
      final to = switch (d.outcome) {
        YearOutcome.promoted => nextClassId(d.classId, classes),
        YearOutcome.repeated => d.classId,
        _ => null,
      };
      // The final class has nowhere to be promoted to: that is completion.
      final outcome = d.outcome == YearOutcome.promoted && to == null
          ? YearOutcome.completed
          : d.outcome;
      await students.saveStudent(switch (outcome) {
        YearOutcome.completed => d.student.copyWith(status: 'Graduated'),
        _ => d.student.copyWith(classId: to),
      });
      final record = PromotionRecord(
        studentId: d.student.id,
        classId: d.classId,
        toClassId: to ?? '',
        year: year,
        outcome: outcome,
        average: d.average,
        appliedAt: stamp,
        appliedBy: actor,
      );
      await _store.savePromotions([...await _store.loadPromotions(), record]);
      await ServerSync.instance.send(
        'PUT',
        '/api/records/promotions/${record.id}',
        body: record.toJson(),
      );
      await audit.log(
        action: 'student.year_end',
        actor: actor,
        target: d.student.id,
        detail:
            '${d.student.fullName}: ${outcome.label}'
            '${to == null || to == d.classId ? '' : ' to $to'}'
            '${d.average == null ? '' : ' (year average ${d.average!.toStringAsFixed(1)})'}',
        reason: 'End of year $year',
      );
      applied++;
    }
    return applied;
  }
}
