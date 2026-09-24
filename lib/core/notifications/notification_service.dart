import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../settings/app_settings.dart';

/// Called with a notification payload when the user taps a notification —
/// while the app is in the foreground, or when the tap is what launched it.
typedef NotificationOpenedHandler = void Function(String? payload);

/// Singleton wrapper around `flutter_local_notifications`.
///
/// Safety contract (this runs in widget tests and on unsupported platforms):
///
/// * Every public method is a **no-op while
///   `AppSettings.instance.notificationsEnabled` is false** — checked at
///   each call, so the settings toggle is honoured live.
/// * Every platform interaction is wrapped in try/catch and logged with
///   [debugPrint]; a missing plugin, a web build or a desktop platform can
///   never crash a caller.
/// * [init] is idempotent, and [show] will lazily initialise on demand, so
///   the service also works if it was first touched while notifications
///   were disabled and the user enables them later.
///
/// Startup wiring for the lead (after `AppSettings.instance.load()`):
///
/// ```dart
/// await NotificationService.instance.init();
/// NotificationService.instance
///     .configureOnNotificationOpened((payload) => /* route by payload */);
/// ```
class NotificationService {
  NotificationService._();

  /// App-wide instance.
  static final NotificationService instance = NotificationService._();

  static const _channelId = 'solvanta_default';
  static const _channelName = 'SOLVANTA';
  static const _channelDescription =
      'School updates: attendance, gate, assignments and messages.';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Future<void>? _initFuture;
  var _initialized = false;
  var _autoId = 0;
  NotificationOpenedHandler? _onOpened;
  String? _launchPayload;

  /// Whether the plugin finished bootstrapping without error.
  bool get isInitialized => _initialized;

  /// Payload of the notification that cold-started the app, held until a
  /// handler is configured (then dispatched and cleared). Also readable if
  /// the lead prefers to poll instead of using
  /// [configureOnNotificationOpened].
  String? get pendingOpenedPayload => _launchPayload;

  bool get _enabled => AppSettings.instance.notificationsEnabled;

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  /// Initialises the plugin and requests OS notification permission
  /// (Android 13+ runtime prompt, iOS alert/badge/sound prompt).
  ///
  /// No-op while notifications are disabled; idempotent otherwise. Platform
  /// failures are logged and leave the service initialised-but-inert, so
  /// [show] and friends simply no-op for the rest of the session.
  Future<void> init() async {
    if (!_enabled) return;
    await _ensureInitialized();
  }

  Future<void> _ensureInitialized() => _initFuture ??= _doInit();

  Future<void> _doInit() async {
    if (kIsWeb) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const ios = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      await _plugin.initialize(
        const InitializationSettings(android: android, iOS: ios),
        onDidReceiveNotificationResponse: (response) =>
            _dispatchOpened(response.payload),
      );

      // Permission prompts: Android 13+ needs an explicit runtime request;
      // iOS prompts from initialize(), but asking again is harmless.
      if (defaultTargetPlatform == TargetPlatform.android) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      }

      // Did the app cold-start from a notification tap?
      try {
        final details = await _plugin.getNotificationAppLaunchDetails();
        if (details?.didNotificationLaunchApp ?? false) {
          _launchPayload = details?.notificationResponse?.payload;
        }
      } catch (e) {
        debugPrint('[NotificationService] launch details unavailable: $e');
      }

      _initialized = true;
      _consumeLaunchPayload();
    } catch (e) {
      debugPrint('[NotificationService] init failed — notifications inert '
          'for this session: $e');
      _initialized = false;
    }
  }

  /// Registers the tap handler. Any payload waiting from a launch-time tap
  /// is dispatched immediately.
  void configureOnNotificationOpened(NotificationOpenedHandler handler) {
    _onOpened = handler;
    _consumeLaunchPayload();
  }

  void _consumeLaunchPayload() {
    final payload = _launchPayload;
    if (payload == null || !_initialized) return;
    _launchPayload = null;
    _dispatchOpened(payload);
  }

  void _dispatchOpened(String? payload) {
    try {
      _onOpened?.call(payload);
    } catch (e) {
      debugPrint('[NotificationService] opened handler failed: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Show / cancel
  // ---------------------------------------------------------------------

  /// Shows a local notification. Returns the id used (or null when it was
  /// skipped/failed). [id] is generated when omitted; pass a stable id to
  /// update rather than duplicate. [payload] comes back through the opened
  /// handler when the user taps it.
  Future<int?> show({
    int? id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_enabled) return null;
    try {
      await _ensureInitialized();
      if (!_initialized) return null;
      final nid = id ?? _nextAutoId();
      await _plugin.show(nid, title, body, _details(), payload: payload);
      return nid;
    } catch (e) {
      debugPrint('[NotificationService] show failed: $e');
      return null;
    }
  }

  /// Cancels one notification by [id], or all of them when [id] is null.
  Future<void> cancel({int? id}) async {
    if (!_enabled) return;
    try {
      await _ensureInitialized();
      if (!_initialized) return;
      if (id == null) {
        await _plugin.cancelAll();
      } else {
        await _plugin.cancel(id);
      }
    } catch (e) {
      debugPrint('[NotificationService] cancel failed: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Reminders ("assignment due tomorrow")
  // ---------------------------------------------------------------------

  /// Schedules a one-shot reminder at [when] (device local time).
  ///
  /// Uses `zonedSchedule` with an *inexact* Android alarm mode, which needs
  /// no `SCHEDULE_EXACT_ALARM` permission — the notification fires around
  /// the requested moment (and later still after a reboot once the lead has
  /// added the boot receivers — see the sync/notifications notes). Silently
  /// no-ops for past times, disabled notifications, or unsupported
  /// platforms.
  Future<void> scheduleAt({
    required int id,
    required String title,
    required String body,
    required DateTime when,
    String? payload,
  }) async {
    if (!_enabled || !when.isAfter(DateTime.now())) return;
    await _schedule(
      id: id,
      title: title,
      body: body,
      when: when,
      payload: payload,
      match: null,
    );
  }

  /// Schedules a daily reminder at [hour]:[minute] device local time,
  /// first firing at the next occurrence (today if still ahead, otherwise
  /// tomorrow), then repeating every day via `matchDateTimeComponents`.
  ///
  /// Timezone note: the device's IANA zone *name* isn't available without an
  /// extra plugin, so the schedule is anchored to the correct absolute
  /// instant (the VM has already resolved local wall-clock against OS zone
  /// rules, DST included) rather than a zone id. Daily repeats therefore
  /// keep their instant and can shift by an hour across a DST change — an
  /// accepted trade-off for a school reminder.
  Future<void> scheduleDaily({
    required int id,
    required String title,
    required String body,
    required int hour,
    int minute = 0,
    String? payload,
  }) async {
    if (!_enabled) return;
    final now = DateTime.now();
    var first = DateTime(now.year, now.month, now.day, hour, minute);
    if (!first.isAfter(now)) {
      first = first.add(const Duration(days: 1));
    }
    await _schedule(
      id: id,
      title: title,
      body: body,
      when: first,
      payload: payload,
      match: DateTimeComponents.time,
    );
  }

  Future<void> _schedule({
    required int id,
    required String title,
    required String body,
    required DateTime when,
    required String? payload,
    required DateTimeComponents? match,
  }) async {
    try {
      await _ensureInitialized();
      if (!_initialized) return;
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        // Absolute instant, anchored to UTC: correct regardless of the
        // (unavailable) local zone id. See [scheduleDaily].
        tz.TZDateTime.from(when, tz.UTC),
        _details(),
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: match,
        payload: payload,
      );
    } catch (e) {
      debugPrint('[NotificationService] schedule failed: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  NotificationDetails _details() => NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
        ),
      );

  int _nextAutoId() {
    _autoId = _autoId >= 0x7ffffffe ? 1 : _autoId + 1;
    return _autoId;
  }
}
