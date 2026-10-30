import 'dart:convert';
import 'dart:typed_data';


import '../../core/api/api_client.dart';
import '../../core/models/assignment_submission.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';
import '../../core/storage/data_store.dart';

/// Offline-first store for assignment submissions.
///
/// Follows [ScansRepository] deliberately: local write first, then mirror to
/// the API, with photos parked as base64 when the upload cannot go through
/// (the sync outbox only carries JSON, so the bytes wait here instead).
///
/// The one structural difference is that a submission carries several pages.
/// Each page's photo is uploaded under its own key so a five-page booklet
/// survives a partial failure: four pages that uploaded are not lost because
/// the fifth was still offline.
class AssignmentSubmissionsRepository {
  AssignmentSubmissionsRepository({LocalStore? store})
      : _store = store ?? LocalStore();

  final LocalStore _store;

  static const _pendingKey = 'solvanta.assignment_submission_uploads_v1';

  Future<List<AssignmentSubmission>> all() =>
      _store.loadAssignmentSubmissions();

  Future<List<AssignmentSubmission>> forAssignment(String assignmentId) async {
    final all = await _store.loadAssignmentSubmissions();
    return all.where((s) => s.assignmentId == assignmentId).toList();
  }

  Future<List<AssignmentSubmission>> forStudent(String studentId) async {
    final all = await _store.loadAssignmentSubmissions();
    return all.where((s) => s.studentId == studentId).toList();
  }

  /// The existing submission for this student and assignment, if one is still
  /// open. Pages are added to it rather than starting a second submission, so
  /// photographing a booklet across two sittings still produces one record.
  Future<AssignmentSubmission?> openFor(
      String assignmentId, String studentId) async {
    final all = await _store.loadAssignmentSubmissions();
    for (final s in all) {
      if (s.assignmentId == assignmentId && s.studentId == studentId) {
        return s;
      }
    }
    return null;
  }

  /// Saves [sub] locally and mirrors it, then uploads any page photos in
  /// [images] that have not gone up yet.
  ///
  /// The bytes are passed in rather than re-read from disk, matching
  /// [ScansRepository.save]: the capture screen already holds them, and on the
  /// browser there is no file to read back from at all.
  ///
  /// [images] is keyed by page id. A page with no entry (a manual-only
  /// submission, or one whose photo this device no longer holds) simply has
  /// nothing to upload — that is not an error.
  Future<void> save(
    AssignmentSubmission sub, {
    Map<String, Uint8List>? images,
  }) async {
    final all = await _store.loadAssignmentSubmissions();
    final list = <AssignmentSubmission>[];
    var replaced = false;
    for (final s in all) {
      if (s.id == sub.id) {
        list.add(sub);
        replaced = true;
      } else {
        list.add(s);
      }
    }
    if (!replaced) list.add(sub);
    await _store.saveAssignmentSubmissions(list);

    final sync = ServerSync.instance;
    if (!sync.enabled) return;
    await sync.send('PUT', '/api/records/assignment_submissions/${sub.id}',
        body: sub.toJson());
    for (final page in sub.pages) {
      final bytes = images?[page.id];
      if (bytes == null || bytes.isEmpty) continue;
      if (!await _upload(sub.id, page, bytes)) {
        await _park(sub.id, page, bytes);
      }
    }
  }

  Future<void> delete(String id) async {
    final all = await _store.loadAssignmentSubmissions();
    await _store
        .saveAssignmentSubmissions(all.where((s) => s.id != id).toList());
    await ServerSync.instance
        .send('DELETE', '/api/records/assignment_submissions/$id');
  }

  /// Uploads photos parked while offline. Called after each server pull.
  ///
  /// Grouped by submission before retrying so a booklet whose first page
  /// uploads and whose last page does not leaves the rest untouched — each
  /// page is retried on its own key.
  Future<void> retryUploads() async {
    final pending = await _pending();
    if (pending.isEmpty) return;
    for (final key in pending.keys.toList()) {
      final ref = _PendingPageRef.parse(key);
      if (ref == null) {
        // A key we did not write. Drop it rather than retry it forever —
        // nothing can ever make it succeed.
        pending.remove(key);
        continue;
      }
      if (await _upload(ref.submissionId, ref.page,
          base64Decode(pending[key]!))) {
        pending.remove(key);
      }
    }
    await _savePending(pending);
  }

  Future<bool> _upload(
      String submissionId, AssignmentPage page, Uint8List image) async {
    try {
      await ApiClient().putBytes(
          '/api/assignment-submissions/$submissionId/pages/${page.pageNumber}'
          '/image',
          image,
          _mime(image));
      return true;
    } on ApiException catch (e) {
      // 404: the submission has not reached the server yet; keep it for later.
      // Other refusals (too large, not your student) cannot succeed.
      return !(e.isNetwork ||
          e.statusCode == 401 ||
          e.statusCode == 404 ||
          e.statusCode >= 500);
    } catch (_) {
      return false;
    }
  }

  static String _mime(Uint8List b) {
    if (b.length > 3 && b[0] == 0x89 && b[1] == 0x50) return 'image/png';
    if (b.length > 3 && b[0] == 0x52 && b[1] == 0x49) return 'image/webp';
    return 'image/jpeg';
  }

  Future<void> _park(
      String submissionId, AssignmentPage page, Uint8List image) async {
    final pending = await _pending();
    pending[_PendingPageRef.key(submissionId, page)] = base64Encode(image);
    await _savePending(pending);
  }

  Future<Map<String, String>> _pending() async {
    final raw = (await DataStore.instance()).getString(_pendingKey);
    if (raw == null) return {};
    return (jsonDecode(raw) as Map).cast<String, String>();
  }

  Future<void> _savePending(Map<String, String> pending) async {
    final prefs = await DataStore.instance();
    if (pending.isEmpty) {
      await prefs.remove(_pendingKey);
    } else {
      await prefs.setString(_pendingKey, jsonEncode(pending));
    }
  }
}

/// One parked photo, identified by which submission it belongs to and which
/// page it is.
///
/// Encoded into the parked map's key as `<submissionId>#<pageNumber>` so the
/// set can be replayed later without keeping a second structure alongside it.
class _PendingPageRef {
  const _PendingPageRef(this.submissionId, this.page);

  final String submissionId;
  final AssignmentPage page;

  static String key(String submissionId, AssignmentPage page) =>
      '$submissionId#${page.pageNumber}';

  /// Parses a key back into its parts, or null if the key is not one of ours.
  ///
  /// A malformed key is dropped rather than retried forever: nothing can ever
  /// make it succeed, and leaving it there would mean every sync attempt
  /// retries a guaranteed failure.
  static _PendingPageRef? parse(String raw) {
    final i = raw.lastIndexOf('#');
    if (i <= 0 || i == raw.length - 1) return null;
    final submissionId = raw.substring(0, i);
    final n = int.tryParse(raw.substring(i + 1));
    if (n == null || n < 1) return null;
    return _PendingPageRef(
      submissionId,
      AssignmentPage(
        id: raw,
        pageNumber: n,
        imagePath: '',
        capturedAt: '',
      ),
    );
  }
}
