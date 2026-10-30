import '../../core/models/grading.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';

/// The school's grading and scoring set-up: read by report cards on every
/// device, changed only by the school admin (the server enforces both).
class GradingRepository {
  GradingRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  Future<GradingConfig> config() => _store.loadGradingConfig();

  /// Saves [config] locally and sends it to the server (queued when
  /// offline). Returns why it can't be saved, or `null` once saved.
  Future<String?> save(GradingConfig config) async {
    final problem = config.problem();
    if (problem != null) return problem;
    await _store.saveGradingConfig(config);
    await ServerSync.instance
        .send('PUT', '/api/school/grading', body: config.toJson());
    return null;
  }
}
