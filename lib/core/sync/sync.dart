/// Offline-first plumbing: the durable sync outbox, reachability signal,
/// data-saver helpers and the shell status banner.
///
/// Wire-up the lead needs (all optional except the banner placement —
/// everything else self-starts):
///
/// * `SyncQueue.instance` — handler auto-registers with the first `ApiClient`.
/// * `ConnectivityMonitor.instance.start()` — flushes on offline → online.
/// * `SyncStatusBanner()` — drop into the shell; it renders nothing when
///   idle.
library;

export 'connectivity_monitor.dart';
export 'offline_lite.dart';
export 'sync_queue.dart';
export 'sync_status_banner.dart';
