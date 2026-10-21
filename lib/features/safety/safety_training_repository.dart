import '../../core/models/safety_training.dart';
import '../../core/storage/phase6_store.dart';
import '../../core/sync/server_sync.dart';

class SafetyTrainingRepository {
  final Phase6Store _store = Phase6Store();

  Future<List<SafetyPack>> all() async {
    final raw = await _store.loadSafetyPacksJson();
    return raw.map(SafetyPack.fromJson).toList();
  }

  Future<List<SafetyPack>> forAudience(String audience) async {
    final raw = await _store.loadSafetyPacksJson();
    return raw
        .map(SafetyPack.fromJson)
        .where((p) => p.audience == audience)
        .toList();
  }

  Future<List<TrainingCompletion>> completionsFor(String studentId) async {
    final raw = await _store.loadSafetyCompletionsJson();
    return raw
        .map(TrainingCompletion.fromJson)
        .where((c) => c.studentId == studentId)
        .toList();
  }

  Future<void> recordCompletion({
    required String packId,
    required String studentId,
    required int score,
    required int total,
  }) async {
    final raw = await _store.loadSafetyCompletionsJson();
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    final kept = raw.where((c) =>
        c['packId'] != packId || c['studentId'] != studentId).toList();
    final completion = TrainingCompletion(
      packId: packId,
      studentId: studentId,
      completedOn: '${n.year}-${p(n.month)}-${p(n.day)}',
      score: score,
      total: total,
    ).toJson();
    kept.add(completion);
    await _store.saveSafetyCompletionsJson(kept);
    // Staff take the training for themselves (no student): nothing to share.
    if (studentId.isNotEmpty) {
      await ServerSync.instance.send(
          'PUT', '/api/records/safety_completions/${recordId(packId, studentId)}',
          body: completion);
    }
  }

  /// The server's id for one pupil's completion of one pack.
  static String recordId(String packId, String studentId) =>
      '${packId}_$studentId';
}