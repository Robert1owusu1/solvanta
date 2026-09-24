/// SOLVANTA app lock (biometric / PIN).
///
/// Wiring for the lead:
/// * `AppLockGate` — wrap the app content once in `lib/app.dart`
///   (inside `MaterialApp.builder`; see the class doc for why).
/// * `LockSettingsSection` — one line in `settings_screen.dart`'s ListView
///   (see its doc comment for the exact spot).
/// * `AppLockGate.of(context)?.lock()` — programmatic lock, e.g. before
///   signing a user out.
/// * `LockScreen` / `PinPad` are exported for reuse and tests.
library;

export 'app_lock_gate.dart';
export 'lock_settings.dart';
export 'lock_screen.dart';
export 'pin_pad.dart';
