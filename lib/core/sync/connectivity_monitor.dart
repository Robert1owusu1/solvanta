import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'sync_queue.dart';

/// Reachability signal for the app, wrapping `connectivity_plus`.
///
/// Started lazily — the first read of [online], [isOnline] or [start] kicks
/// off one initial check plus a single platform subscription, so callers can
/// treat it as free to touch anywhere.
///
/// On every offline → online transition (including the first known-online
/// state after launch) it automatically calls
/// `SyncQueue.instance.flush(ignoreBackoff: true)`, which is what replays
/// the outbox the moment the network comes back.
///
/// Platform failures are swallowed and logged; an unknown state is treated
/// as *online* so a broken plugin never holds the queue hostage.
class ConnectivityMonitor {
  ConnectivityMonitor._({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  /// App-wide instance.
  static final ConnectivityMonitor instance = ConnectivityMonitor._();

  final Connectivity _connectivity;
  final _events = StreamController<bool>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Future<void>? _starting;
  bool? _lastKnown;

  /// Most recently observed state; null until the first check completes.
  /// Handy as `StreamBuilder(initialData:)` for [online].
  bool? get lastKnown => _lastKnown;

  /// Broadcast stream of connectivity states. Emits the current state once
  /// the initial check lands, then every transition (deduplicated).
  Stream<bool> get online {
    unawaited(start());
    return _events.stream;
  }

  /// Whether the device currently has a network path. Resolves once the
  /// initial check completes; defaults to true if the check itself fails.
  Future<bool> get isOnline async {
    await start();
    return _lastKnown ?? true;
  }

  /// Starts monitoring (idempotent — safe to call from app startup and from
  /// widgets alike).
  Future<void> start() => _starting ??= _start();

  /// Stops the platform subscription. Only needed in tests — the singleton
  /// monitors for the life of the app; call [start] again to resume.
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _starting = null;
  }

  Future<void> _start() async {
    try {
      _update(_isConnected(await _connectivity.checkConnectivity()));
    } catch (e) {
      debugPrint('[ConnectivityMonitor] initial check failed: $e');
      _update(true);
    }
    try {
      _sub = _connectivity.onConnectivityChanged.listen(
        (results) => _update(_isConnected(results)),
        onError: (Object e) =>
            debugPrint('[ConnectivityMonitor] stream error: $e'),
      );
    } catch (e) {
      debugPrint('[ConnectivityMonitor] cannot subscribe: $e');
    }
  }

  bool _isConnected(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  void _update(bool value) {
    final previous = _lastKnown;
    _lastKnown = value;
    if (previous == value) return;
    _events.add(value);
    // offline → online (or the first known state being online, which covers
    // "app restarted with a non-empty outbox"): replay now.
    if (value && previous != true) {
      unawaited(SyncQueue.instance.flush(ignoreBackoff: true));
    }
  }
}
