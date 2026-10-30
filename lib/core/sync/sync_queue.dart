import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import '../storage/data_store.dart';

/// Lifecycle of one outbox entry.
///
/// * [pending] — waiting for its first attempt, or waiting out a backoff.
/// * [inFlight] — currently being replayed by `SyncQueue.flush()`.
/// * [failed] — the last replay attempt failed; `SyncItem.lastError` says why.
/// * [done] — replayed successfully. Successful items are removed rather than
///   persisted as done, so this state is only ever transient.
enum SyncStatus { pending, inFlight, failed, done }

/// One durable outbox entry: a mutating operation that failed (typically
/// while offline) and will be replayed when connectivity returns.
class SyncItem {
  SyncItem({
    required this.id,
    required this.kind,
    required this.payload,
    required this.createdAt,
    this.attempts = 0,
    this.lastError,
    this.status = SyncStatus.pending,
    this.nextAttemptAt = 0,
  });

  /// Unique id. Supply your own when enqueuing the same logical operation
  /// more than once — a queued id is never duplicated (idempotent enqueue).
  final String id;

  /// Operation category, e.g. `message.send`, `attendance.mark`,
  /// `payment.record`, or the built-in `api.post /api/messages` produced by
  /// `ApiClient` when a request fails with a network error.
  final String kind;

  /// JSON-serialisable operation data. `ApiClient` writes `method`, `path`
  /// and `body` so the request can be re-issued verbatim during replay.
  final Map<String, dynamic> payload;

  /// When the item was captured, as milliseconds since the epoch.
  final int createdAt;

  /// How many replay attempts have failed so far. Drives the backoff.
  int attempts;

  /// Why the last attempt failed, or null if it hasn't failed yet.
  String? lastError;

  /// Current lifecycle state — see [SyncStatus].
  SyncStatus status;

  /// Epoch milliseconds before which `flush()` should not retry this item
  /// (unless it was asked to ignore backoff, e.g. on a connectivity change).
  int nextAttemptAt;

  /// [createdAt] as a [DateTime].
  DateTime get created => DateTime.fromMillisecondsSinceEpoch(createdAt);

  factory SyncItem.fromJson(Map<String, dynamic> json) => SyncItem(
        id: json['id'] as String,
        kind: json['kind'] as String? ?? 'unknown',
        payload: (json['payload'] as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{},
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        attempts: (json['attempts'] as num?)?.toInt() ?? 0,
        lastError: json['lastError'] as String?,
        status: _statusFromName(json['status'] as String?),
        nextAttemptAt: (json['nextAttemptAt'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'payload': payload,
        'createdAt': createdAt,
        'attempts': attempts,
        'lastError': lastError,
        'status': status.name,
        'nextAttemptAt': nextAttemptAt,
      };

  @override
  String toString() =>
      'SyncItem($id, $kind, ${status.name}, attempts=$attempts'
      '${lastError == null ? '' : ', error: $lastError'})';
}

SyncStatus _statusFromName(String? name) => switch (name) {
      'inFlight' => SyncStatus.inFlight,
      'failed' => SyncStatus.failed,
      'done' => SyncStatus.done,
      _ => SyncStatus.pending,
    };

/// Replays one queued item. Return `true` when the operation is finished
/// (the item is removed), or `false` / throw to keep it queued with the
/// error recorded and an exponential backoff applied.
typedef SyncHandler = Future<bool> Function(SyncItem item);

/// Durable offline outbox.
///
/// Mutating operations that fail (usually because the device is offline) are
/// captured with [enqueue] and persisted to SharedPreferences under
/// [storageKey], so they survive app restarts. [flush] replays them through
/// an injected handler — oldest first — removing successes and keeping
/// failures queued with `lastError` plus an exponential backoff.
///
/// Typical wiring (done for you by `ApiClient` + `ConnectivityMonitor`, so
/// the lead only needs the badge/banner):
///
/// ```dart
/// SyncQueue.instance.registerHandler(replay);   // first client wins
/// SyncQueue.instance.registerObserver(local);   // bookkeeping after replay
/// ConnectivityMonitor.instance.start();          // flushes offline → online
/// SyncQueue.instance.sizeStream.listen(renderBadge);
/// ```
///
/// Re-entrancy: overlapping [flush] calls share a single replay pass, items
/// enqueued *during* a pass are picked up by the next one, and a failed
/// SharedPreferences write degrades to in-memory operation rather than
/// throwing.
class SyncQueue extends ChangeNotifier {
  SyncQueue._();

  /// App-wide instance.
  static final SyncQueue instance = SyncQueue._();

  /// SharedPreferences key holding the queue as a JSON list.
  static const String storageKey = 'solvanta.sync_queue_v1';

  final _items = <SyncItem>[];
  final _sizeEvents = StreamController<int>.broadcast();
  Future<void>? _loading;
  Future<void>? _flushing;
  SyncHandler? _handler;
  SyncHandler? _observer;
  var _seq = 0;

  // ---------------------------------------------------------------------
  // Handler
  // ---------------------------------------------------------------------

  /// Installs the replay [handler] if none is set yet and immediately flushes
  /// anything a previous session left behind. `ApiClient` calls this from its
  /// constructor, so a normal app run needs no manual wiring.
  ///
  /// Returns whether this call installed the handler.
  bool registerHandler(SyncHandler handler) {
    if (_handler != null) return false;
    _handler = handler;
    unawaited(flush(ignoreBackoff: true));
    return true;
  }

  /// Installs a local *observer* alongside the delivery handler
  /// ([registerHandler]) — for bookkeeping that must also happen once an item
  /// has been replayed, e.g. promoting a `queued` message to `sent`.
  ///
  /// Independent first-wins slot, so the order the two callers register in
  /// does not matter: [MessagesRepository] registering its observer can never
  /// lock `ApiClient` out of the delivery slot.
  ///
  /// Semantics:
  ///
  /// * a delivery handler exists → the observer runs only *after* a
  ///   successful replay, and its result/exception is ignored (a delivered
  ///   item is never turned back into a failure);
  /// * no delivery handler (pure offline / local-only mode) → the observer
  ///   *is* the deciding handler, so its `true`/`false` removes or keeps the
  ///   item exactly like [registerHandler] would.
  ///
  /// Returns whether this call installed the observer.
  bool registerObserver(SyncHandler observer) {
    if (_observer != null) return false;
    _observer = observer;
    if (_handler == null) unawaited(flush(ignoreBackoff: true));
    return true;
  }

  /// Replaces the replay handler unconditionally. Use this when the lead
  /// wants a custom replayer (or in tests) — it does not trigger a flush.
  void setHandler(SyncHandler handler) => _handler = handler;

  /// Whether a replay handler or observer is installed.
  bool get hasHandler => _handler != null || _observer != null;

  // ---------------------------------------------------------------------
  // Queue operations
  // ---------------------------------------------------------------------

  /// Captures [payload] under [kind] so it can be replayed later.
  ///
  /// Pass [id] to make the call idempotent: if an item with that id is
  /// already queued it is returned instead of being duplicated. Failures to
  /// persist are logged and tolerated — the item still lives in memory.
  Future<SyncItem> enqueue(
    String kind,
    Map<String, dynamic> payload, {
    String? id,
  }) async {
    await ensureLoaded();
    if (id != null) {
      for (final existing in _items) {
        if (existing.id == id) return existing;
      }
    }
    final item = SyncItem(
      id: id ?? 'SYNC-${DateTime.now().millisecondsSinceEpoch}-${_seq++}',
      kind: kind,
      payload: payload,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    _items.add(item);
    _emit();
    await _persist();
    return item;
  }

  /// A snapshot of everything still waiting to be replayed.
  Future<List<SyncItem>> pending() async {
    await ensureLoaded();
    return List<SyncItem>.unmodifiable(
      _items.where((i) => i.status != SyncStatus.done),
    );
  }

  /// Number of queued items, for badges (async because it loads the store).
  Future<int> get size async => (await pending()).length;

  /// Synchronous view of [pending] length for widgets. 0 until
  /// [ensureLoaded] completes; listen to [sizeStream] or this object (a
  /// [ChangeNotifier]) to learn when that happens.
  int get pendingCount =>
      _items.where((i) => i.status != SyncStatus.done).length;

  /// Emits the current [pendingCount] once the store is loaded, then again
  /// on every change — feed it straight into a badge.
  Stream<int> get sizeStream async* {
    await ensureLoaded();
    yield pendingCount;
    yield* _sizeEvents.stream;
  }

  /// Replays queued items through the registered handler, oldest first.
  ///
  /// Success removes the item; failure keeps it queued with an updated
  /// `lastError` and an exponential backoff (5 s doubling to a 5-minute cap).
  /// Pass `ignoreBackoff: true` when the retry is justified — e.g.
  /// `ConnectivityMonitor` does exactly that on an offline → online
  /// transition — so items are tried immediately instead of waiting.
  ///
  /// Safe to call concurrently: overlapping calls share one replay pass.
  Future<void> flush({bool ignoreBackoff = false}) => _flushing ??=
      _replay(ignoreBackoff).whenComplete(() => _flushing = null);

  /// Removes every queued item and resets the badge to 0.
  Future<void> clear() async {
    await ensureLoaded();
    _items.clear();
    await _persist();
    _emit();
  }

  /// Loads the persisted queue exactly once. Called automatically by every
  /// operation above; expose it only so widgets can warm it up in
  /// `initState`.
  Future<void> ensureLoaded() => _loading ??= _load();

  // ---------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------

  Future<void> _load() async {
    try {
      final prefs = await DataStore.instance();
      final raw = prefs.getString(storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        _items
          ..clear()
          ..addAll(
            decoded
                .whereType<Map<dynamic, dynamic>>()
                .map((e) => SyncItem.fromJson(e.cast<String, dynamic>())),
          );
      }
      // Crash recovery: an item caught mid-replay goes back to pending.
      for (final item in _items) {
        if (item.status == SyncStatus.inFlight) {
          item.status = SyncStatus.pending;
        }
      }
    } catch (e) {
      // Never let a corrupt/absent store take the app down — run in-memory.
      debugPrint('[SyncQueue] load failed (continuing empty): $e');
    }
    _emit();
  }

  Future<void> _persist() async {
    try {
      final prefs = await DataStore.instance();
      await prefs.setString(
        storageKey,
        jsonEncode(_items.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      // Payloads are JSON-checked at the wire, but be defensive: a queue
      // that cannot be written stays in memory for this session.
      debugPrint('[SyncQueue] persist failed (kept in memory): $e');
    }
  }

  void _emit() {
    _sizeEvents.add(pendingCount);
    notifyListeners();
  }

  Future<void> _replay(bool ignoreBackoff) async {
    await ensureLoaded();
    final handler = _handler;
    final observer = _observer;
    if (handler == null && observer == null) {
      if (_items.isNotEmpty) {
        debugPrint('[SyncQueue] no handler registered — '
            '${_items.length} item(s) held back');
      }
      return;
    }
    // Snapshot the queue: anything enqueued while replaying is picked up
    // by the next pass instead of mutating the list mid-iteration.
    for (final item in List<SyncItem>.of(_items)) {
      if (item.status == SyncStatus.done) continue;
      if (!ignoreBackoff &&
          DateTime.now().millisecondsSinceEpoch < item.nextAttemptAt) {
        continue;
      }

      item.status = SyncStatus.inFlight;
      var succeeded = false;
      String? failure;
      try {
        if (handler != null) {
          succeeded = await handler(item);
          if (!succeeded) {
            failure = 'handler reported failure';
          } else if (observer != null) {
            // Local bookkeeping after a successful replay. It must never
            // demote an item the delivery handler already accepted.
            try {
              await observer(item);
            } catch (e) {
              debugPrint('[SyncQueue] observer for ${item.id} failed: $e');
            }
          }
        } else {
          // Delivery-handler-free (pure offline) mode: the observer decides.
          succeeded = await observer!(item);
          if (!succeeded) failure = 'handler reported failure';
        }
      } catch (e) {
        succeeded = false;
        failure = '$e';
      }

      if (succeeded) {
        _items.remove(item);
        _emit();
        await _persist();
        continue;
      }

      item
        ..status = SyncStatus.failed
        ..attempts += 1
        ..lastError = failure
        ..nextAttemptAt = DateTime.now().millisecondsSinceEpoch +
            backoffFor(item.attempts).inMilliseconds;
      _emit();
      await _persist();
    }
  }

  /// Exponential-ish backoff for a failing item: 5 s, 10 s, 20 s … capped
  /// at five minutes so a long-offline device doesn't hammer the server the
  /// moment it reconnects.
  static Duration backoffFor(int attempts) {
    // Clamp attempts to [1, 7] to prevent shift overflow and excessive backoff.
    // attempts=1 → 5s, 2→10s, 3→20s, 4→40s, 5→80s, 6→160s, 7→300s (capped)
    final clampedAttempts = attempts.clamp(1, 7);
    final shift = clampedAttempts - 1;
    final seconds = 5 << shift;
    return Duration(seconds: seconds > 300 ? 300 : seconds);
  }
}
