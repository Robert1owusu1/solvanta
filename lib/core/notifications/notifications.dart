/// Local/push notification plumbing.
///
/// Wire-up the lead needs (once, at startup, after `AppSettings.load()`):
///
/// ```dart
/// await NotificationService.instance.init();
/// NotificationService.instance.configureOnNotificationOpened((payload) { … });
/// ```
///
/// The inbox bridge is already wired inside `NotificationsRepository.push`
/// — no call site changes required.
library;

export 'notification_bridge.dart';
export 'notification_service.dart';
