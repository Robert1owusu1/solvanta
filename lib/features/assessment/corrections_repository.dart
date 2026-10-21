import '../../core/models/correction.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';

class CorrectionsRepository {
  CorrectionsRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  Future<List<Correction>> all() => _store.loadCorrections();

  Future<List<Correction>> forAssessment(
      String studentId, String assessmentId) async {
    final all = await _store.loadCorrections();
    return all
        .where((c) =>
            c.studentId == studentId && c.assessmentId == assessmentId)
        .toList();
  }

  Future<List<Correction>> forStudent(String studentId) async {
    final all = await _store.loadCorrections();
    return all.where((c) => c.studentId == studentId).toList();
  }

  /// Records a correction for a question unless one already exists.
  Future<void> save(Correction correction) async {
    final all = await _store.loadCorrections();
    final list = <Correction>[];
    var replaced = false;
    for (final c in all) {
      if (c.studentId == correction.studentId &&
          c.assessmentId == correction.assessmentId &&
          c.questionId == correction.questionId) {
        // keep the first id so the server updates its row, not adds one
        correction = Correction.fromJson({...correction.toJson(), 'id': c.id});
        list.add(correction);
        replaced = true;
      } else {
        list.add(c);
      }
    }
    if (!replaced) list.add(correction);
    await _store.saveCorrections(list);
    await ServerSync.instance.send(
        'PUT', '/api/records/corrections/${correction.id}',
        body: correction.toJson());
  }

  Future<int> completedCount(String studentId, String assessmentId) async =>
      (await forAssessment(studentId, assessmentId))
          .where((c) => c.completed)
          .length;
}