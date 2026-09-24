import 'package:flutter/foundation.dart';

import '../models/app_notification.dart';
import '../settings/app_settings.dart';
import 'notification_service.dart';

/// Glue between the in-app [NotificationsRepository] (the offline-first
/// inbox) and the OS notification layer.
///
/// The repository calls [onPersisted] right after an `AppNotification` is
/// saved; this bridge raises the same title/body as a system notification.
/// It is deliberately one-directional — the repository knows nothing about
/// `flutter_local_notifications`, and every failure here is swallowed so
/// existing `push(...)` callers keep working unchanged.
///
/// Gating: no-ops when `AppSettings.instance.notificationsEnabled` is
/// false, when the service was never initialised, or on web/unsupported
/// platforms (all handled inside `NotificationService`).
class NotificationBridge {
  NotificationBridge._();

  /// Raises [n] as an OS notification. Never throws.
  static Future<void> onPersisted(AppNotification n) async {
    try {
      if (!AppSettings.instance.notificationsEnabled) return;
      await NotificationService.instance.show(
        id: idFor(n.id),
        title: n.title,
        body: n.body,
        payload: n.id,
      );
    } catch (e) {
      debugPrint('[NotificationBridge] show failed: $e');
    }
  }

  /// Schedules a one-shot reminder derived from an in-app notification —
  /// e.g. "Assignment X is due tomorrow". [when] is device local time;
  /// re-using the same source [id] updates the previous schedule instead of
  /// stacking duplicates. Never throws.
  static Future<void> scheduleReminder({
    required String id,
    required String title,
    required String body,
    required DateTime when,
    String? payload,
  }) async {
    try {
      if (!AppSettings.instance.notificationsEnabled) return;
      await NotificationService.instance.scheduleAt(
        id: idFor(id),
        title: title,
        body: body,
        when: when,
        payload: payload,
      );
    } catch (e) {
      debugPrint('[NotificationBridge] schedule failed: $e');
    }
  }

  /// Stable positive int id derived from an app-facing notification id
  /// (FNV-1a, 31-bit) so re-showing the same notification updates it in
  /// place rather than duplicating it. Deterministic across launches.
  static int idFor(String sourceId) {
    var hash = 0x811c9dc5;
    for (final unit in sourceId.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }
}
