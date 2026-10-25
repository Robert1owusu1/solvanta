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
  Future<MarkingDraftRequest> request({
    required String schemeId,
    required String submissionId,
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
