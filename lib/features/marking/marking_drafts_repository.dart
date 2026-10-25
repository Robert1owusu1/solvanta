import '../../core/api/api_client.dart';
import '../../core/models/marking_draft.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';
import '../ocr/ocr_repository.dart';

/// Local-first queue for draft marks (Phase 5).
///
/// The matching engine and the schemes live on the server, so a draft is
/// always made there. What stays local-first is the request: it is written to
/// this device before any network call, sent now if possible, and retried on
/// the next sync otherwise — the OCR queue's shape, with its own retry rather
/// than the shared outbox so a request is never sent twice by two owners.
///
/// The drafts that come back are kept on the device for the review screen.
/// They are never marks: nothing here writes a grade.
class MarkingDraftsRepository {
  MarkingDraftsRepository({LocalStore? store, OcrRepository? ocr})
      : _store = store ?? LocalStore(),
        _ocr = ocr ?? OcrRepository(store: store);

  final LocalStore _store;
  final OcrRepository _ocr;

  Future<List<MarkingDraftRequest>> pending() => _store.loadDraftRequests();

  /// Drafts for one paper, newest last.
  Future<List<MarkingDraft>> draftsFor(String submissionId) async =>
      (await _store.loadMarkingDrafts())
          .where((d) => d.submissionId == submissionId)
          .toList();

  /// The draft to review for a paper: the latest that is not discarded.
  Future<MarkingDraft?> currentDraft(String submissionId) async {
    final live = (await draftsFor(submissionId))
        .where((d) => d.status != 'discarded')
        .toList();
    return live.isEmpty ? null : live.last;
  }

  /// Asks for a draft from teacher-confirmed OCR readings ([ocrJobIds]) or
  /// from answers the teacher typed ([answers]: questionNumber, text,
  /// working) — exactly one of the two.
  ///
  /// [submissionId] names the paper; it may be left empty for an assessment,
  /// whose one paper per student the server finds itself.
  Future<MarkingDraftRequest> request({
    required String schemeId,
    String submissionId = '',
    required String studentId,
    List<String> ocrJobIds = const [],
    List<Map<String, dynamic>> answers = const [],
  }) async {
    if (ocrJobIds.isEmpty == answers.isEmpty) {
      throw ArgumentError('Give either confirmed OCR readings or typed answers');
    }
    final req = MarkingDraftRequest(
      id: 'MDR-${DateTime.now().microsecondsSinceEpoch}',
      schemeId: schemeId,
      submissionId: submissionId,
      studentId: studentId,
      ocrJobIds: ocrJobIds,
      answers: answers,
      createdAt: DateTime.now().toIso8601String(),
    );
    await _saveRequest(req);
    await push(req);
    return req;
  }

  /// Re-sends every request still waiting. Called after each server pull.
  Future<void> retryPending() async {
    for (final req in await _store.loadDraftRequests()) {
      if (!req.failed) await push(req);
    }
  }

  /// Sends one request. Offline or a server error leaves it waiting; a
  /// refusal the next attempt cannot fix is kept with its reason, so the
  /// teacher sees why rather than the request vanishing.
  Future<void> push(MarkingDraftRequest req) async {
    if (!ApiClient.isConfigured || !ServerSync.instance.enabled) return;
    if (req.ocrJobIds.isNotEmpty && !await _ocr.sendConfirmed(req.ocrJobIds)) {
      return; // the readings are not on the server yet: try again next sync
    }
    try {
      final res = await ApiClient().request(
        'POST',
        '/api/marking-drafts',
        body: req.body(),
        offlineQueue: false,
      );
      if (res is! Map<String, dynamic>) return;
      final draft = MarkingDraft.fromJson(res);
      await _keepDraft(draft);
      await _removeRequest(req.id);
    } on ApiException catch (e) {
      if (e.isNetwork || e.statusCode == 401 || e.statusCode >= 500) return;
      await _saveRequest(req.withError(e.message));
    } catch (_) {
      // Unknown failure: leave it waiting for the next sync.
    }
  }

  /// Drafts waiting for a teacher's review in the classes this user marks.
  /// Online, from the server; offline, the drafts this device already holds.
  Future<List<MarkingDraft>> reviewQueue() async {
    if (ApiClient.isConfigured && ServerSync.instance.enabled) {
      try {
        final res = await ApiClient().request(
          'GET',
          '/api/marking-drafts?status=draft',
          offlineQueue: false,
        );
        if (res is List) {
          return res
              .map((e) => MarkingDraft.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      } catch (_) {
        // Fall through to what this device holds.
      }
    }
    return (await _store.loadMarkingDrafts())
        .where((d) => d.status == 'draft')
        .toList();
  }

  /// One draft with all its questions: the server's copy when reachable
  /// (kept on the device), otherwise this device's.
  Future<MarkingDraft?> load(String id) async {
    if (ApiClient.isConfigured && ServerSync.instance.enabled) {
      try {
        final res = await ApiClient().request(
          'GET',
          '/api/marking-drafts/$id',
          offlineQueue: false,
        );
        if (res is Map<String, dynamic>) {
          final draft = MarkingDraft.fromJson(res);
          await _keepDraft(draft);
          return draft;
        }
      } catch (_) {
        // Fall through to what this device holds.
      }
    }
    for (final d in await _store.loadMarkingDrafts()) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// The teacher's in-progress decisions for a draft, kept on this device.
  Future<Map<String, DraftDecision>> decisionsFor(String draftId) async {
    final all = await _store.loadDraftReviews();
    final raw = all[draftId];
    if (raw is! Map) return {};
    return raw.map((k, v) =>
        MapEntry(k as String, DraftDecision.fromJson(Map<String, dynamic>.from(v as Map))));
  }

  /// Saves the decisions locally, on every change: local first.
  Future<void> saveDecisions(String draftId, Map<String, DraftDecision> decisions) async {
    final all = await _store.loadDraftReviews();
    all[draftId] = decisions.map((k, v) => MapEntry(k, v.toJson()));
    await _store.saveDraftReviews(all);
  }

  /// Records the teacher's marks. Only an explicit call from the review
  /// screen's confirmed Finalize reaches here, and it needs the server: the
  /// marks are recorded there. Throws [FinalizeException] with a message to
  /// show; the decisions stay on the device either way.
  Future<MarkingDraft> finalize(MarkingDraft draft, Map<String, DraftDecision> decisions) async {
    final blocker = reviewBlocker(draft, decisions);
    if (blocker != null) throw FinalizeException(blocker);
    if (!ApiClient.isConfigured || !ServerSync.instance.enabled) {
      throw const FinalizeException(
          'No connection to the server. Your marks are saved on this device; finalize again when you are online.');
    }
    try {
      final res = await ApiClient().request(
        'POST',
        '/api/marking-drafts/${draft.id}/finalize',
        body: {
          'marks': [
            for (final a in draft.answers)
              {
                'schemeQuestionId': a.schemeQuestionId,
                'marks': decisions[a.schemeQuestionId]!.marks,
                'note': decisions[a.schemeQuestionId]!.note,
              },
          ],
        },
        offlineQueue: false,
      );
      final done = MarkingDraft.fromJson(res as Map<String, dynamic>);
      await _keepDraft(done);
      final all = await _store.loadDraftReviews();
      all.remove(draft.id);
      await _store.saveDraftReviews(all);
      return done;
    } on ApiException catch (e) {
      if (e.isNetwork) {
        throw const FinalizeException(
            'Could not reach the server. Your marks are saved on this device; finalize again when you are online.');
      }
      throw FinalizeException(e.message);
    }
  }

  /// Dismisses a refused request once the teacher has seen why.
  Future<void> dismiss(String requestId) => _removeRequest(requestId);

  /// Stores [draft] and marks this device's older drafts for the same paper
  /// as discarded, as the server has done.
  Future<void> _keepDraft(MarkingDraft draft) async {
    final out = <MarkingDraft>[];
    for (final d in await _store.loadMarkingDrafts()) {
      if (d.id == draft.id) continue;
      if (d.submissionId == draft.submissionId && d.status == 'draft') {
        out.add(MarkingDraft.fromJson({...d.toJson(), 'status': 'discarded'}));
      } else {
        out.add(d);
      }
    }
    out.add(draft);
    await _store.saveMarkingDrafts(out);
  }

  Future<void> _saveRequest(MarkingDraftRequest req) async {
    final all = await _store.loadDraftRequests();
    final i = all.indexWhere((r) => r.id == req.id);
    if (i >= 0) {
      all[i] = req;
    } else {
      all.add(req);
    }
    await _store.saveDraftRequests(all);
  }

  Future<void> _removeRequest(String id) async {
    final all = await _store.loadDraftRequests();
    all.removeWhere((r) => r.id == id);
    await _store.saveDraftRequests(all);
  }
}

/// Why a finalize did not happen, worded for the teacher.
class FinalizeException implements Exception {
  const FinalizeException(this.message);
  final String message;

  @override
  String toString() => message;
}
