import '../../core/models/intervention.dart';
import '../../core/models/student.dart';
import '../../core/models/submission.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';

class InterventionsRepository {
  InterventionsRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  Future<List<Intervention>> all() async {
    final list = await _store.loadInterventions();
    list.sort((a, b) => b.createdDate.compareTo(a.createdDate));
    return list;
  }

  Future<List<Intervention>> forStudent(String studentId) async {
    final all = await _store.loadInterventions();
    return all.where((i) => i.studentId == studentId).toList();
  }

  Future<void> create({
    required Student student,
    required String topic,
    required String action,
    required String assignedBy,
  }) async {
    final all = await _store.loadInterventions();
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    final intervention = Intervention(
      id: 'INTV-${DateTime.now().millisecondsSinceEpoch}',
      studentId: student.id,
      topic: topic,
      action: action,
      assignedBy: assignedBy,
      createdDate:
          '${n.year}-${p(n.month)}-${p(n.day)}',
    );
    await _store.saveInterventions([intervention, ...all]);
    final saved = await ServerSync.instance.sendFor('POST',
        '/api/interventions', intervention.toJson(), Intervention.fromJson);
    if (saved != null) await _replace(intervention.id, saved);
  }

  Future<void> _replace(String id, Intervention saved) async {
    final all = await _store.loadInterventions();
    await _store
        .saveInterventions([for (final i in all) i.id == id ? saved : i]);
  }

  Future<void> updateStatus(
      String id, InterventionStatus status) async {
    final all = await _store.loadInterventions();
    await _store.saveInterventions(all.map((i) {
      if (i.id == id) return i.copyWith(status: status);
      return i;
    }).toList());
    await ServerSync.instance.send('POST', '/api/interventions/$id/status',
        body: {'status': status.name});
  }

  Future<void> attachReassessment(
      String id, String assessmentId) async {
    final all = await _store.loadInterventions();
    await _store.saveInterventions(all.map((i) {
      if (i.id == id) {
        return i.copyWith(
          reassessmentAssessmentId: assessmentId,
          status: InterventionStatus.inProgress,
        );
      }
      return i;
    }).toList());
    await ServerSync.instance.send(
        'POST', '/api/interventions/$id/reassessment',
        body: {'assessmentId': assessmentId});
    await ServerSync.instance.send('POST', '/api/interventions/$id/status',
        body: {'status': InterventionStatus.inProgress.name});
  }

  Future<(double? before, double? after)> improvement({
    required String interventionId,
    required List<AssessmentSubmission> subs,
  }) async {
    final all = await _store.loadInterventions();
    final intervention = all.where((i) => i.id == interventionId).firstOrNull;
    if (intervention == null) return (null, null);
    final reassessment = intervention.reassessmentAssessmentId;
    if (reassessment == null) return (null, null);
    final targetAssessments =
        subs.where((s) => s.studentId == intervention.studentId);
    final before = targetAssessments
        .where((s) => s.assessmentId != reassessment)
        .isNotEmpty
        ? targetAssessments
            .where((s) => s.assessmentId != reassessment)
            .map((s) => s.earned)
            .reduce((a, b) => a + b)
        : null;
    final afterSub = targetAssessments
        .where((s) => s.assessmentId == reassessment)
        .firstOrNull;
    return (before, afterSub?.earned);
  }
}