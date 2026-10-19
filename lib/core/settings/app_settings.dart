import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../security/secret_hash.dart';

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
  // The PIN's digit count (4–6). Kept as its own value because the PIN itself
  // is hashed now, so its length can no longer be inferred from storage.
  static const _kLockPinLength = 'solvanta.lockPinLength';
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

  /// App-lock PIN, stored hashed (`v2$salt$iterations$digest`) so a dump of
  /// SharedPreferences no longer hands over a usable PIN. A legacy plain value
  /// may still be present until the first [load] migrates it.
  ///
  /// Front-end demo lock, not a substitute for the platform keystore.
  String? lockPin;

  /// How many digits the PIN was created with (4–6). Stored separately because
  /// the length of [lockPin] says nothing about it once hashed.
  int lockPinLength = 4;

  /// Whether a usable PIN is stored: the hashed form, or a legacy plain value
  /// that [load] has not upgraded yet.
  bool get hasLockPin {
    final v = lockPin;
    if (v == null || v.isEmpty) return false;
    if (isHashedSecret(v)) return true;
    return v.length >= 4 && v.length <= 6;
  }

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
  ///
  /// Concurrent callers (app startup + the lock gate + the settings screen)
  /// share one in-flight read, so the legacy-PIN migration below runs once.
  /// A failed read clears the cached future so the next call can retry.
  Future<void> load() {
    if (_loaded) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void>? _loading;

  Future<void> _load() async {
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
    lockPinLength = p.getInt(_kLockPinLength) ?? 4;
    // Upgrade a PIN written by an older build, which stored it as plain digits.
    // Rewriting it hashed is what actually gets the secret out of the file:
    // verification still works afterwards because [verifySecret] accepts both
    // forms, but the plain value is gone once this runs.
    final legacyPin = lockPin;
    if (legacyPin != null &&
        legacyPin.length >= 4 &&
        legacyPin.length <= 6 &&
        !isHashedSecret(legacyPin)) {
      lockPinLength = legacyPin.length;
      lockPin = hashSecret(legacyPin);
      await p.setString(_kLockPin, lockPin!);
      await p.setInt(_kLockPinLength, lockPinLength);
    }
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

  /// Stores [value] hashed so the plain PIN never lands on disk. Null/empty
  /// clears the PIN along with its recorded length.
  Future<void> setLockPin(String? value) async {
    if (value == null || value.isEmpty) {
      lockPin = null;
      lockPinLength = 4;
      await _set(null, null, null, stringKey: _kLockPin, stringValue: null);
      final p = await SharedPreferences.getInstance();
      await p.remove(_kLockPinLength);
      return;
    }
    lockPin = hashSecret(value);
    lockPinLength = value.length;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kLockPinLength, lockPinLength);
    await _set(null, null, null, stringKey: _kLockPin, stringValue: lockPin);
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

