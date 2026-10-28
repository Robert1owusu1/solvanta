import '../../core/api/api_client.dart';
import '../../core/models/marking_feedback.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';

/// A feedback report and where it came from.
class FeedbackResult<T> {
  const FeedbackResult({this.data, this.fetchedAt = '', this.fromCache = false, this.error = ''});

  final T? data;

  /// When the report was read from the server.
  final String fetchedAt;

  /// True when the server could not be reached and this is the last copy
  /// this device kept.
  final bool fromCache;

  /// Why there is no report, when [data] is null.
  final String error;
}

/// Reads the Phase 7 feedback reports. They are computed on the server from
/// finalized marks only, so there is nothing to write: what stays
/// local-first is the last copy of each report, kept per viewer so it can be
/// shown without a signal and never to another account on the same device.
class MarkingFeedbackRepository {
  MarkingFeedbackRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  Future<FeedbackResult<StudentFeedback>> student(String viewerId, String studentId) =>
      _read(viewerId, '/api/reports/marking/students/$studentId', StudentFeedback.fromJson);

  Future<FeedbackResult<ClassFeedback>> forClass(String viewerId, String classId) =>
      _read(viewerId, '/api/reports/marking/classes/$classId', ClassFeedback.fromJson);

  Future<FeedbackResult<T>> _read<T>(
    String viewerId,
    String path,
    T Function(Map<String, dynamic>) parse,
  ) async {
    final key = '$viewerId|$path';
    if (ApiClient.isConfigured && ServerSync.instance.enabled) {
      try {
        final res = await ApiClient().request('GET', path, offlineQueue: false);
        if (res is Map<String, dynamic>) {
          final fetchedAt = DateTime.now().toIso8601String();
          final all = await _store.loadMarkingFeedback();
          all[key] = {'fetchedAt': fetchedAt, 'body': res};
          await _store.saveMarkingFeedback(all);
          return FeedbackResult(data: parse(res), fetchedAt: fetchedAt);
        }
      } on ApiException catch (e) {
        // A refusal is an answer, not an outage: never show a cached copy
        // to someone the server just said may not see it.
        if (!e.isNetwork) {
          final all = await _store.loadMarkingFeedback();
          if (all.remove(key) != null) await _store.saveMarkingFeedback(all);
          return FeedbackResult(error: e.message);
        }
      } catch (_) {
        // Fall through to the last copy.
      }
    }
    final cached = (await _store.loadMarkingFeedback())[key];
    if (cached is Map) {
      return FeedbackResult(
        data: parse(Map<String, dynamic>.from(cached['body'] as Map)),
        fetchedAt: (cached['fetchedAt'] as String?) ?? '',
        fromCache: true,
      );
    }
    return const FeedbackResult(
      error: 'Feedback reports come from the server. Connect once to load them; '
          'they stay on this device after that.',
    );
  }
}
