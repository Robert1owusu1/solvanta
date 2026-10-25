import '../../core/api/api_client.dart';
import '../../core/models/ocr_job.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';

/// Local-first OCR queue.
///
/// Follows the same shape as [SafetyRepository]'s outbox pattern and
/// [AssignmentSubmissionsRepository]'s parked photos: the job is written to
/// this device first, so a page photographed in a classroom with no signal
/// still exists afterwards, and the push happens either now or on the pull
/// after connectivity returns.
///
/// One deliberate difference: the network calls here use `offlineQueue: false`
/// and drive their own retry, exactly as the photo uploads in
/// [AssignmentSubmissionsRepository] do. Letting the shared outbox replay a
/// generate call as well would run OCR twice for one job, and the second run
/// is refused by the server — leaving a reading nobody can retrieve. One owner
/// of retry, not two.
class OcrRepository {
  OcrRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  static const _recordsPath = '/api/records/ocr_jobs';

  Future<List<OcrJob>> all() => _store.loadOcrJobs();

  /// Writes [job] to this device. Local write first, always.
  Future<void> save(OcrJob job) async {
    final jobs = await _store.loadOcrJobs();
    final out = <OcrJob>[];
    var replaced = false;
    for (final j in jobs) {
      if (j.id == job.id) {
        out.add(job);
        replaced = true;
      } else {
        out.add(j);
      }
    }
    if (!replaced) out.add(job);
    await _store.saveOcrJobs(out);
  }

  /// Queues a page for recognition and pushes it if the device is online.
  ///
  /// The local write happens even when the push cannot: that is the whole
  /// point of the queue.
  Future<void> enqueue(OcrJob job) async {
    await save(job);
    await push(job);
  }

  /// Re-attempts every job still waiting to be read.
  ///
  /// Called after each server pull — the same hook [ScansRepository] and
  /// [AssignmentSubmissionsRepository] retry from, so "connectivity returned"
  /// has exactly one meaning across the app.
  Future<void> retryQueued() async {
    if (!ApiClient.isConfigured) return;
    final jobs = await _store.loadOcrJobs();
    for (final job in jobs) {
      if (job.status != OcrJobStatus.queued) continue;
      await push(job);
    }
  }

  /// Drives one job from queued to read.
  ///
  /// Returns without changing anything when the device is offline: the job
  /// stays `queued` and the next pull tries again.
  Future<void> push(OcrJob job) async {
    if (!ApiClient.isConfigured) return;

    var current = job;
    final image = current.imageBase64;
    if (image == null || image.isEmpty) {
      await _fail(current, 'There is no photo attached to this page.');
      return;
    }

    if (current.requestId == null) {
      final requestId = await _createRequest(current);
      if (requestId == null) return; // offline or refused: stays queued
      current = current.copyWith(requestId: requestId);
      await save(current);
    }

    await save(current.copyWith(status: OcrJobStatus.reading, clearError: true));

    try {
      final res = await ApiClient().request(
        'POST',
        '/api/questions/ai/requests/${current.requestId}/generate',
        body: {
          'imageBase64': image,
          'contentType': current.contentType,
        },
        offlineQueue: false,
      );

      final ocr = res is Map<String, dynamic> ? res['ocr'] : null;
      if (ocr is! Map<String, dynamic>) {
        await _fail(current, 'The server returned no reading for this page.');
        return;
      }
      await _keepReading(current, ocr);
    } on ApiException catch (e) {
      if (e.statusCode == 409) {
        // The earlier attempt DID reach the server, but its response never
        // arrived here. The server keeps the reading, so fetch it rather than
        // reading (and paying for) the page twice.
        await _recover(current);
        return;
      }
      if (_isRetryable(e)) {
        await _park(current, e);
      } else {
        await _fail(current, e.message);
      }
    } catch (_) {
      await _park(current, null);
    }
  }

  /// Keeps a reading the server returned. Stored before it is mirrored, so a
  /// connection lost while sending cannot cost this device the reading.
  Future<void> _keepReading(OcrJob job, Map<String, dynamic> ocr) async {
    final read = job.copyWith(
      status: OcrJobStatus.read,
      text: (ocr['text'] ?? '') as String,
      math: (ocr['math'] ?? '') as String,
      provider: (ocr['provider'] ?? '') as String,
      costTier: (ocr['costTier'] ?? '') as String,
      lines: (ocr['lines'] ?? 0) as int,
      confidence: ((ocr['confidence'] ?? 0) as num).toDouble(),
      warnings: ((ocr['warnings'] ?? const []) as List)
          .map((e) => e as String)
          .toList(),
      clearError: true,
    );
    await save(read);
    await _mirror(read);
  }

  /// Fetches the reading the server saved for an earlier generate whose
  /// response was lost. A request from before readings were saved has none;
  /// that is said plainly rather than shown as an empty reading.
  Future<void> _recover(OcrJob job) async {
    try {
      final res = await ApiClient().request(
        'GET',
        '/api/questions/ai/requests/${job.requestId}/ocr',
        offlineQueue: false,
      );
      if (res is Map<String, dynamic>) {
        await _keepReading(job, res);
        return;
      }
      await _fail(job, _lostReading);
    } on ApiException catch (e) {
      if (_isRetryable(e)) {
        await _park(job, e);
      } else {
        await _fail(job, _lostReading);
      }
    } catch (_) {
      await _park(job, null);
    }
  }

  static const _lostReading =
      'This page was already read on the server but the result did not reach this device. Submit it again for a fresh reading.';

  /// Records a teacher's confirmation of a reading.
  ///
  /// The engine's own [OcrJob.text] is never overwritten — a correction has to
  /// sit beside what was actually read, or the next person looking cannot tell
  /// the two apart. The photo is dropped only now, when review is over; while
  /// the reading awaits confirmation the teacher needs it to check against.
  Future<void> confirm(String id, String reviewedText) async {
    final jobs = await _store.loadOcrJobs();
    OcrJob? updated;
    final out = <OcrJob>[];
    for (final j in jobs) {
      if (j.id == id) {
        updated = j.copyWith(
          reviewedText: reviewedText,
          confirmedAt: DateTime.now().toIso8601String(),
          status: OcrJobStatus.confirmed,
          clearImage: true,
          clearError: true,
        );
        out.add(updated);
      } else {
        out.add(j);
      }
    }
    if (updated == null) return;
    await _store.saveOcrJobs(out);
    await _mirror(updated);
  }

  /// Creates the server-side generation request, reusing this job's id.
  ///
  /// The id is derived from the job rather than left to the server so a
  /// retried create is recognised as the same request and does not become a
  /// second one — the server answers 409 for an id it already has, which here
  /// means "already done", not "failed".
  Future<String?> _createRequest(OcrJob job) async {
    try {
      final res = await ApiClient().request(
        'POST',
        '/api/questions/ai/requests',
        body: {
          'id': job.id,
          'subjectId': job.subjectId,
          'topic': job.topic,
          'type': job.type.name,
          'count': 1,
          'classId': job.classId,
        },
        offlineQueue: false,
      );
      if (res is Map<String, dynamic> && res['id'] is String) {
        return res['id'] as String;
      }
      return null;
    } on ApiException catch (e) {
      if (e.statusCode == 409) return job.id;
      if (_isRetryable(e)) return null;
      // A refusal the next attempt cannot fix — fail it rather than retrying
      // the same body on every pull forever.
      await _fail(job, e.message);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Sends the job (minus its photo) to the records store so the reading and
  /// the confirmation follow the teacher across devices.
  ///
  /// The photo is deliberately stripped: the records list endpoint returns
  /// every row in one response, and megabyte images in it would make that
  /// endpoint unusable. The bytes stay on the device that has them.
  Future<void> _mirror(OcrJob job) async {
    if (!ServerSync.instance.enabled) return;
    try {
      await ApiClient().request(
        'PUT',
        '$_recordsPath/${job.id}',
        body: job.copyWith(clearImage: true).toJson(),
        offlineQueue: false,
      );
    } catch (_) {
      // Best effort: the local copy stands. Mirroring is not what makes the
      // reading true, and a failed mirror must never lose the local record.
    }
  }

  Future<void> _park(OcrJob job, ApiException? e) async {
    // Back to queued so the next pull retries it. A non-network reason is
    // kept on the job so the teacher can see why it has not moved, while an
    // offline one is cleared — "waiting for connection" is not an error
    // worth showing as one.
    final message = (e != null && !e.isNetwork) ? e.message : '';
    await save(job.copyWith(
      status: OcrJobStatus.queued,
      error: message,
      clearError: message.isEmpty,
    ));
  }

  Future<void> _fail(OcrJob job, String message) async {
    await save(job.copyWith(status: OcrJobStatus.failed, error: message));
  }

  /// A 401 means the session ended, not that the page is wrong; 5xx and
  /// network failures are transient. Other 4xx cannot be fixed by trying
  /// again with the same body.
  /// Makes sure the server holds these confirmed readings before a draft is
  /// asked for: the server marks only readings it can see were confirmed,
  /// and [_mirror] is best effort. False when any could not be sent or is
  /// not confirmed on this device.
  Future<bool> sendConfirmed(List<String> ids) async {
    if (!ServerSync.instance.enabled) return false;
    final jobs = {for (final j in await _store.loadOcrJobs()) j.id: j};
    for (final id in ids) {
      final job = jobs[id];
      if (job == null || job.status != OcrJobStatus.confirmed) return false;
      try {
        await ApiClient().request(
          'PUT',
          '$_recordsPath/${job.id}',
          body: job.copyWith(clearImage: true).toJson(),
          offlineQueue: false,
        );
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  static bool _isRetryable(ApiException e) =>
      e.isNetwork || e.statusCode == 401 || e.statusCode >= 500;
}
