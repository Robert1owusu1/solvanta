import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted user preferences — the single source of truth for appearance,
/// motion, security and data usage.
///
/// Read by the theme controller (`SolvantaApp`), the app-lock gate, the
/// haptics helper in the UI kit and the data-saver. Everything is plain
/// [shared_preferences] so it survives restarts and costs nothing at startup.
class AppSettings extends ChangeNotifier {
  AppSettings._();

  /// App-wide instance. Tests replace the underlying prefs with
  /// `SharedPreferences.setMockInitialValues`, so the defaults below are what
  /// a fresh install (and every widget test) sees.
  static final AppSettings instance = AppSettings._();

  static const _kThemeMode = 'solvanta.themeMode';
  static const _kHaptics = 'solvanta.haptics';
  static const _kReduceMotion = 'solvanta.reduceMotion';
  static const _kDataSaver = 'solvanta.dataSaver';
  static const _kLockEnabled = 'solvanta.lockEnabled';
  static const _kLockMethod = 'solvanta.lockMethod';
  static const _kLockPin = 'solvanta.lockPin';
  static const _kNotifications = 'solvanta.notificationsEnabled';
  static const _kLargeText = 'solvanta.largeText';

  // ---------------------------------------------------------------------
  // Appearance
  // ---------------------------------------------------------------------

  /// Follow the system by default; the user can pin light or dark.
  ThemeMode themeMode = ThemeMode.system;

  // ---------------------------------------------------------------------
  // Feedback & motion
  // ---------------------------------------------------------------------

  /// Haptic tick on meaningful confirmations (marking a state, check-in,
  /// tab change). Honours the OS "touch feedback" setting implicitly because
  /// the platform simply no-ops where it is disabled.
  bool haptics = true;

  /// Accessibility: collapse entrance animations to an instant fade.
  bool reduceMotion = false;

  // ---------------------------------------------------------------------
  // Data usage
  // ---------------------------------------------------------------------

  /// Offline-lite / data saver: skip shimmer, collapse entrance motion and
  /// let repositories prefer the cached local store over the network.
  bool dataSaver = false;

  // ---------------------------------------------------------------------
  // Security
  // ---------------------------------------------------------------------

  /// Require biometric or PIN before the app content is shown.
  bool lockEnabled = false;

  /// `'biometric'` or `'pin'`.
  String lockMethod = 'biometric';

  /// Four-digit PIN. Stored on-device only; this is a front-end demo lock,
  /// not a substitute for the platform keystore.
  String? lockPin;

  // ---------------------------------------------------------------------
  // Notifications
  // ---------------------------------------------------------------------

  /// Master switch for local/push notifications.
  bool notificationsEnabled = true;

  bool _loaded = false;

  /// Whether [load] has completed at least once.
  bool get loaded => _loaded;

  /// Reads persisted values. Safe to call more than once; only the first
  /// call does I/O.
  Future<void> load() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    themeMode = switch (p.getString(_kThemeMode)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    haptics = p.getBool(_kHaptics) ?? true;
    reduceMotion = p.getBool(_kReduceMotion) ?? false;
    dataSaver = p.getBool(_kDataSaver) ?? false;
    lockEnabled = p.getBool(_kLockEnabled) ?? false;
    lockMethod = p.getString(_kLockMethod) ?? 'biometric';
    lockPin = p.getString(_kLockPin);
    notificationsEnabled = p.getBool(_kNotifications) ?? true;
    largeText = p.getBool(_kLargeText) ?? false;
    _loaded = true;
    notifyListeners();
  }

  /// Brightness the neutral palette should render with right now. Resolves
  /// `ThemeMode.system` against the platform so `AppColors` and
  /// `ThemeData` always agree.
  Brightness resolveBrightness() {
    switch (themeMode) {
      case ThemeMode.light:
        return Brightness.light;
      case ThemeMode.dark:
        return Brightness.dark;
      case ThemeMode.system:
        return WidgetsBinding.instance.platformDispatcher.platformBrightness;
    }
  }

  Future<void> _set(ThemeMode? mode, String? boolKey, bool? boolValue,
      {String? stringKey, String? stringValue}) async {
    final p = await SharedPreferences.getInstance();
    if (mode != null) {
      themeMode = mode;
      await p.setString(_kThemeMode, mode.name);
    }
    if (boolKey != null && boolValue != null) {
      await p.setBool(boolKey, boolValue);
    }
    if (stringKey != null) {
      if (stringValue == null) {
        await p.remove(stringKey);
      } else {
        await p.setString(stringKey, stringValue);
      }
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Setters — each persists then notifies so the tree rebuilds.
  // ---------------------------------------------------------------------

  Future<void> setThemeMode(ThemeMode mode) => _set(mode, null, null);

  Future<void> setHaptics(bool value) async {
    haptics = value;
    await _set(null, _kHaptics, value);
  }

  Future<void> setReduceMotion(bool value) async {
    reduceMotion = value;
    await _set(null, _kReduceMotion, value);
  }

  Future<void> setDataSaver(bool value) async {
    dataSaver = value;
    await _set(null, _kDataSaver, value);
  }

  Future<void> setNotificationsEnabled(bool value) async {
    notificationsEnabled = value;
    await _set(null, _kNotifications, value);
  }

  Future<void> setLockEnabled(bool value) async {
    lockEnabled = value;
    await _set(null, _kLockEnabled, value);
  }

  Future<void> setLockMethod(String value) async {
    lockMethod = value;
    await _set(null, null, null, stringKey: _kLockMethod, stringValue: value);
  }

  Future<void> setLockPin(String? value) async {
    lockPin = value;
    await _set(null, null, null, stringKey: _kLockPin, stringValue: value);
  }

  // ---------------------------------------------------------------------
  // Accessibility
  // ---------------------------------------------------------------------

  /// Bump the whole app's text scale (~1.25×) for low-vision users. Applied
  /// globally in `SolvantaApp` via a [MediaQuery] override.
  bool largeText = false;

  Future<void> setLargeText(bool value) async {
    largeText = value;
    await _set(null, _kLargeText, value);
  }

  /// True when entrance animations should be collapsed everywhere.
  bool get motionOff => reduceMotion || dataSaver;
}
