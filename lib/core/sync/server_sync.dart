import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../features/assessment/scans_repository.dart';
import '../../features/fees/fees_repository.dart';
import '../../features/marking/marking_drafts_repository.dart';
import '../../features/ocr/ocr_repository.dart';
import '../api/api_client.dart';
import '../api/remote_data_source.dart';
import '../models/promotion.dart';
import '../models/correction.dart';
import '../models/message.dart';
import '../models/ocr_job.dart';
import '../models/scan_page.dart';
import '../models/user.dart';
import '../storage/local_store.dart';
import '../storage/phase6_store.dart';
import 'connectivity_monitor.dart';
import 'sync_queue.dart';

/// Keeps the offline store in step with the backend when one is configured
/// (`--dart-define=SOLVANTA_API=…`).
///
/// Every screen reads [LocalStore], so the client stays offline-first: a
/// **pull** replaces each collection with the server's copy (scoped to the
/// signed-in user by the API), and a **write** mirrors a local change to the
/// matching endpoint, queued in [SyncQueue] while offline. With no backend
/// configured both are no-ops and the seeded local data stays authoritative.
///
/// A pull never runs while the outbox still holds unsent writes: replacing a
/// collection then would drop the local edits waiting to go up.
class ServerSync extends ChangeNotifier {
  ServerSync._();

  static final ServerSync instance = ServerSync._();

  /// How often a foregrounded app refreshes from the server.
  static const refreshInterval = Duration(minutes: 2);

  /// Outbox items that have failed this often are treated as stuck: they no
  /// longer hold back pulls (they stay in the outbox with their error).
  static const stuckAfterAttempts = 5;

  final LocalStore _store = LocalStore();
  final Phase6Store _phase6 = Phase6Store();
  Timer? _timer;
  StreamSubscription<bool>? _online;
  Future<bool>? _pulling;
  final _rejections = StreamController<String>.broadcast();

  /// Bumped after every pull that changed the local store, so open screens
  /// can reload.
  int revision = 0;

  /// When the last successful pull finished, or null before the first.
  DateTime? lastPulled;

  /// Messages for writes the server refused (validation, permissions). The
  /// local change stays visible until the next pull replaces it.
  Stream<String> get rejections => _rejections.stream;

  /// Whether writes and pulls go to a backend at all.
  bool get enabled => ApiClient.isConfigured;

  bool get _signedIn => (ApiClient.sharedToken ?? '').isNotEmpty;

  /// Starts background refreshes: on reconnect (after the outbox flushes)
  /// and every [refreshInterval]. Safe to call more than once.
  void start() {
    if (!enabled) return;
    _online ??= ConnectivityMonitor.instance.online.listen((online) {
      if (online) unawaited(_flushThenPull());
    });
    _timer ??= Timer.periodic(refreshInterval, (_) => unawaited(pull()));
  }

  /// Stops background refreshes (sign-out).
  void stop() {
    _timer?.cancel();
    _timer = null;
    _online?.cancel();
    _online = null;
  }

  Future<void> _flushThenPull() async {
    try {
      await SyncQueue.instance.flush(ignoreBackoff: true);
    } catch (e) {
      debugPrint('[ServerSync] flush before pull failed: $e');
    }
    await pull();
  }

  /// Mirrors every collection from the server into the local store. Returns
  /// whether a pull ran. Concurrent calls share one pull.
  Future<bool> pull() {
    if (!enabled || !_signedIn) return Future.value(false);
    return _pulling ??= _pull().whenComplete(() => _pulling = null);
  }

  Future<bool> _pull() async {
    try {
      if (await _unsent() > 0) {
        await SyncQueue.instance.flush(ignoreBackoff: true);
      }
      final unsent = await _unsent();
      if (unsent > 0) {
        debugPrint('[ServerSync] pull skipped: $unsent unsent change(s)');
        return false;
      }
    } catch (e) {
      debugPrint('[ServerSync] outbox check failed, pulling anyway: $e');
    }

    final remote = RemoteDataSource();
    var changed = 0;
    var reached = false;

    // Each collection independently: a role that may not read one (403)
    // keeps its local copy of it and still gets everything else.
    Future<void> mirror<T>(
        String what, Future<T> Function() fetch, Future<void> Function(T) save) async {
      try {
        final data = await fetch();
        reached = true;
        await save(data);
        changed++;
      } on ApiException catch (e) {
        if (!e.isNetwork) reached = true;
        if (e.statusCode != 403) debugPrint('[ServerSync] $what: $e');
      } catch (e) {
        debugPrint('[ServerSync] $what failed: $e');
      }
    }

    await Future.wait([
      mirror('school', remote.school, _store.saveSchool),
      mirror('term', remote.term, _store.saveTerm),
      mirror('grading', remote.grading, _store.saveGradingConfig),
      mirror('finished terms', remote.finishedTerms, _store.saveTermHistory),
      mirror('classes', remote.classes, _store.saveClasses),
      mirror('users', remote.users, _mergeUsers),
      mirror('students', remote.students, _store.saveStudents),
      mirror('attendance', remote.attendance, _store.saveAttendance),
      mirror('gate', remote.gateEvents, _store.saveGateEvents),
      mirror('questions', remote.questions, _store.saveQuestionBank),
      mirror('assessments', remote.assessments, _store.saveAssessments),
      mirror('submissions', remote.submissions, _store.saveSubmissions),
      mirror('interventions', remote.interventions, _store.saveInterventions),
      mirror('announcements', remote.announcements, _store.saveAnnouncements),
      mirror('messages', remote.messages, _mergeMessages),
      mirror('notifications', remote.notifications, _store.saveNotifications),
      mirror('assignments', remote.assignments, _store.saveAssignments),
      mirror('ai requests', remote.aiRequests, _store.saveQuestionGenRequests),
      mirror('audit', remote.auditLogs, _store.saveAudit),
      mirror('fees', () async => (await remote.invoices(), await remote.payments()),
          (r) => FeesRepository(store: _store)
              .mirrorFromServer(invoices: r.$1, payments: r.$2)),
      mirror('timetable', () => remote.records('lessons'), _phase6.saveLessonsJson),
      mirror('resources', () => remote.records('resources'), _phase6.saveResourcesJson),
      mirror('safety training', () => remote.records('safety_completions'),
          _mergeCompletions),
      mirror('corrections', () => remote.records('corrections'),
          (r) => _store.saveCorrections(r.map(Correction.fromJson).toList())),
      mirror('targets', () => remote.records('targets'), _saveTargets),
      mirror('promotions', () => remote.records('promotions'),
          (r) => _store.savePromotions(r.map(PromotionRecord.fromJson).toList())),
      mirror('scans', () => remote.records('scans'), _mergeScans),
      mirror('ocr jobs', () => remote.records('ocr_jobs'), _mergeOcrJobs),
    ]);
    unawaited(ScansRepository(store: _store).retryUploads());
    // A page photographed offline is read the moment connection returns —
    // the same hook the scan and submission photo retries use, so "we're back
    // online" has one meaning across the app.
    unawaited(OcrRepository(store: _store).retryQueued());
    // Draft-mark requests made offline go out on the same hook.
    unawaited(MarkingDraftsRepository(store: _store).retryPending());

    if (!reached) return false;
    lastPulled = DateTime.now();
    if (changed > 0) {
      revision++;
      notifyListeners();
    }
    return true;
  }

  Future<int> _unsent() async => (await SyncQueue.instance.pending())
      .where((i) => i.attempts < stuckAfterAttempts)
      .length;

  /// The API never returns passwords: keep each account's local hash so an
  /// offline sign-in still works, and keep local accounts the server didn't
  /// list (e.g. the signed-in user when their role can't list users).
  Future<void> _mergeUsers(List<User> remote) async {
    final local = await _store.loadUsers();
    final byId = {for (final u in local) u.id: u};
    final merged = [
      for (final u in remote)
        User(
          id: u.id,
          name: u.name,
          email: u.email,
          phone: u.phone,
          password: byId[u.id]?.password ?? '',
          role: u.role,
          schoolId: u.schoolId,
          classId: u.classId,
          studentIds: u.studentIds,
        ),
      for (final u in local)
        if (!remote.any((r) => r.id == u.id)) u,
    ];
    await _store.saveUsers(merged);
  }

  /// Staff take the training for themselves (no student) and those stay on
  /// the device; pupils' completions come from the server.
  Future<void> _mergeCompletions(List<Map<String, dynamic>> remote) async {
    final own = (await _phase6.loadSafetyCompletionsJson())
        .where((c) => (c['studentId'] ?? '') == '');
    await _phase6.saveSafetyCompletionsJson([...remote, ...own]);
  }

  /// The server returns only the signed-in user's targets, keyed by their id.
  Future<void> _saveTargets(List<Map<String, dynamic>> remote) async {
    for (final r in remote) {
      final targets = r['targets'];
      if (r['id'] is String && targets is Map) {
        await _store.saveTargets(
            targets.map((k, v) => MapEntry(k as String, v as String)),
            userId: r['id'] as String);
      }
    }
  }

  /// A scan's imagePath points into the capturing device's storage, so a
  /// page this device captured keeps its own path.
  Future<void> _mergeScans(List<Map<String, dynamic>> remote) async {
    final local = {for (final s in await _store.loadScans()) s.id: s};
    await _store.saveScans([
      for (final r in remote)
        if (local[r['id']] case final mine?)
          ScanPage.fromJson({...r, 'imagePath': mine.imagePath})
        else
          ScanPage.fromJson({...r, 'imagePath': ''}),
    ]);
  }

  /// Merges the teacher's OCR jobs from the server without losing local work.
  ///
  /// The photo lives only on the device that captured it and a job still
  /// waiting to be read has not been mirrored yet, so a local job is never
  /// dropped just because the server has not heard of it. Where both sides
  /// hold the same job the one further along wins; at level, the local copy is
  /// kept because it is the one that still carries the photo.
  Future<void> _mergeOcrJobs(List<Map<String, dynamic>> remote) async {
    final local = {for (final j in await _store.loadOcrJobs()) j.id: j};
    final out = <OcrJob>[];
    for (final r in remote) {
      final id = r['id'] as String?;
      if (id == null) continue;
      final theirs = OcrJob.fromJson(r);
      final mine = local.remove(id);
      if (mine == null) {
        out.add(theirs);
      } else {
        out.add(mine.mergeRank >= theirs.mergeRank ? mine : theirs);
      }
    }
    out.addAll(local.values);
    await _store.saveOcrJobs(out);
  }

  /// The server carries receipts the other side reported; the device may
  /// be ahead of it (a receipt still on its way up), so each message keeps
  /// whichever state is further along.
  Future<void> _mergeMessages(List<Message> remote) async {
    final local = {for (final m in await _store.loadMessages()) m.id: m};
    await _store.saveMessages([
      for (final m in remote)
        if (local[m.id] case final mine? when mine.state.index > m.state.index)
          mine
        else
          m,
    ]);
  }

  /// Sends one write to the backend. Returns the decoded response, or null
  /// when there is no backend, the device is offline or signed out (the
  /// write is queued and replayed later) or the server refused it (reported
  /// on [rejections], not queued: retrying a 4xx can't succeed). Never
  /// throws: the local change is already committed.
  ///
  /// [report] false keeps a refusal out of [rejections], for writes the user
  /// didn't ask for explicitly (e.g. marking a device-only item read).
  Future<dynamic> send(String method, String path,
      {Object? body, bool report = true}) async {
    if (!enabled) return null;
    try {
      return await ApiClient().request(method, path,
          body: body, offlineQueue: false);
    } on ApiException catch (e) {
      if (e.isNetwork || e.statusCode == 401 || e.statusCode >= 500) {
        await _queue(method, path, body);
        return null;
      }
      debugPrint('[ServerSync] $method $path rejected: $e');
      if (report) _rejections.add(e.message);
      return null;
    } catch (e) {
      debugPrint('[ServerSync] $method $path failed: $e');
      await _queue(method, path, body);
      return null;
    }
  }

  /// Sends a write whose response is the stored record and decodes it with
  /// [decode] — the server's copy (with its id) to keep locally in place of
  /// the draft. Null whenever [send] would return null.
  Future<T?> sendFor<T>(String method, String path, Object? body,
      T Function(Map<String, dynamic>) decode) async {
    final res = await send(method, path, body: body);
    if (res is! Map<String, dynamic>) return null;
    try {
      return decode(res);
    } catch (e) {
      debugPrint('[ServerSync] $method $path: unexpected response ($e)');
      return null;
    }
  }

  /// Parks a write in the outbox in the shape `ApiClient` replays verbatim.
  Future<void> _queue(String method, String path, Object? body) async {
    try {
      await SyncQueue.instance.enqueue(
        'api.${method.toLowerCase()} $path',
        {'method': method, 'path': path, 'body': body},
      );
    } catch (e) {
      debugPrint('[ServerSync] could not queue $method $path: $e');
    }
  }
}
