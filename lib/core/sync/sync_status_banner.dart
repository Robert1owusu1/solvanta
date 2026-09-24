import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'connectivity_monitor.dart';
import 'sync_queue.dart';

/// Slim status strip for the app shell showing one of two states:
///
/// * **Offline** — "changes are saved and will sync automatically" (⚠ glyph +
///   label + warning colour, per the status-never-colour-alone rule).
/// * **Online with a backlog** — "N changes waiting to sync" plus a
///   *Sync now* action that flushes the outbox immediately.
///
/// Renders nothing when the device is online and the outbox is empty, so it
/// is safe to leave permanently in the shell (drop it below the app bar /
/// above the nav bar and forget about it). It starts the connectivity
/// monitor and warms the queue itself — no extra wiring needed.
class SyncStatusBanner extends StatefulWidget {
  const SyncStatusBanner({super.key});

  @override
  State<SyncStatusBanner> createState() => _SyncStatusBannerState();
}

class _SyncStatusBannerState extends State<SyncStatusBanner> {
  @override
  void initState() {
    super.initState();
    // Warm the outbox so pendingCount is correct after the first frame and
    // kick reachability (both are idempotent / safe to call anywhere).
    SyncQueue.instance.ensureLoaded();
    ConnectivityMonitor.instance.start();
  }

  @override
  Widget build(BuildContext context) {
    // The shell pins this strip to the very top of an edge-to-edge body,
    // where it would otherwise paint its label *behind* the status-bar
    // icons (observed on device: clock and banner text overlapping).
    // SafeArea is a no-op when the strip renders nothing and when an
    // ancestor has already consumed the top inset.
    return SafeArea(
      bottom: false,
      child: StreamBuilder<bool>(
        stream: ConnectivityMonitor.instance.online,
        initialData: ConnectivityMonitor.instance.lastKnown ?? true,
        builder: (context, snap) {
          final isOnline = snap.data ?? true;
          if (!isOnline) {
            return _banner(
              background: AppColors.warningBg,
              foreground: AppColors.warning,
              icon: Icons.cloud_off,
              label: 'Offline — changes are saved and will sync automatically',
            );
          }
          return ListenableBuilder(
            listenable: SyncQueue.instance,
            builder: (context, _) {
              final pending = SyncQueue.instance.pendingCount;
              if (pending == 0) return const SizedBox.shrink();
              return _banner(
                background: AppColors.infoBg,
                foreground: AppColors.brand,
                icon: Icons.sync,
                label: pending == 1
                    ? '1 change waiting to sync'
                    : '$pending changes waiting to sync',
                trailing: TextButton(
                  onPressed: () =>
                      SyncQueue.instance.flush(ignoreBackoff: true),
                  child: const Text('Sync now'),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _banner({
    required Color background,
    required Color foreground,
    required IconData icon,
    required String label,
    Widget? trailing,
  }) {
    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: foreground,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
