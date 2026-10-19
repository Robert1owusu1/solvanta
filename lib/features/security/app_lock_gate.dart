import 'package:flutter/material.dart';

import '../../core/settings/app_settings.dart';
import '../auth/auth_repository.dart';
import 'lock_screen.dart';

/// How long a background → foreground round trip stays unlocked: backgrounding
/// for less than this does not re-prompt, so a quick app switch or
/// notification peek never nags. Anything longer re-locks.
const Duration kAppLockGrace = Duration(seconds: 45);

/// Single widget the app wraps its content with to get a biometric/PIN
/// app lock (wired once in `lib/app.dart`).
///
/// ## Why a Stack cover instead of pushing a ModalRoute
///
/// Wire the gate in `MaterialApp`'s `builder` (or anywhere *above* the app's
/// Navigator). At that position its context sits **above** the Navigator, so
/// there is no `Navigator.of(context)` to push a route on — but stacking the
/// lock screen over `child` is strictly stronger than a route: `child` *is*
/// the Navigator subtree, so the cover sits above every route **and** every
/// dialog, bottom sheet or SnackBar rendered on that Navigator — including
/// ones pushed *while the app is locked*. A route-level lock screen could be
/// covered by a dialog pushed after it; this cannot. A transparent
/// [ModalBarrier] under [LockScreen] swallows all input so nothing underneath
/// is interactive during the fade-in.
///
/// Everything above the gate (Theme, MediaQuery, Localizations,
/// ScaffoldMessenger) is untouched; the layer also carries self-sufficiency
/// fallbacks so it still renders if wired a level higher — among them the
/// [Overlay] that floating widgets ([Tooltip], menus, [OverlayPortal])
/// resolve upwards for: the app's own Overlay lives *inside* the Navigator,
/// i.e. below the gate, so without one the lock screen's tooltips threw
/// "No Overlay widget found" at build time and took the layout down with
/// them (debug error box + a ~100k px cascade overflow).
///
/// Behaviour:
/// * `lockEnabled == false` → `child` renders immediately, zero overlays.
/// * First build (after settings load) with the lock on → cover shows,
///   fading in unless `AppSettings.instance.motionOff` (Reduce motion or
///   Data saver) says to appear instantly.
/// * `paused` records the timestamp; `resumed` re-locks only when the app
///   was backgrounded longer than [grace].
/// * Programmatic control: `AppLockGate.of(context)?.lock()` / `.unlock()`
///   (e.g. call `lock()` right before signing a user out).
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child, this.grace = kAppLockGrace});

  /// The guarded app content — with the prescribed wiring, the widget passed
  /// to `MaterialApp.builder` (the Navigator subtree).
  final Widget child;

  /// Re-lock delay after backgrounding. Defaults to [kAppLockGrace];
  /// overridable mainly so tests can pass a shorter window.
  final Duration grace;

  /// Programmatic handle for this gate, or null when the app forgot to wire
  /// one — callers should use `AppLockGate.of(context)?.lock()` so a missing
  /// gate degrades to a no-op instead of a crash.
  static AppLockGateController? of(BuildContext context) {
    final inherited = context.getElementForInheritedWidgetOfExactType<_AppLockScope>()?.widget;
    return inherited is _AppLockScope ? inherited.controller : null;
  }

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

/// Tiny programmatic API obtained through [AppLockGate.of]. Every call is a
/// safe no-op once the gate has been disposed.
class AppLockGateController {
  const AppLockGateController._(this._gate);

  final _AppLockGateState _gate;

  /// Whether the lock screen currently covers the app.
  bool get isLocked => _gate._locked;

  /// Cover the app immediately — e.g. right before signing a user out.
  void lock() => _gate._showLock();

  /// Dismiss the cover (normally called by [LockScreen] after a successful
  /// check; exposed for tests and special flows).
  void unlock() => _gate._unlock();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  final _settings = AppSettings.instance;
  late final AppLockGateController _controller = AppLockGateController._(this);

  bool _locked = false;
  bool _initialEvalDone = false;

  /// False until the first frame is done: before that, state changes are
  /// picked up by the very first build instead of a setState.
  bool _started = false;

  DateTime? _pausedAt;
  int _epoch = 0;
  String? _userName;
  String? _userEmail;

  /// The cover's [OverlayEntry] and the widget it mirrors (see [_lockLayer]).
  /// Released with the cover so each lock cycle inserts a fresh entry: an
  /// entry keeps a back-reference to the Overlay that held it, unmounting
  /// does not clear it, and the next Overlay's `insertAll` asserts on a
  /// stale one.
  OverlayEntry? _lockEntry;
  Widget? _lockContent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settings.addListener(_onSettingsChanged);
    if (_settings.loaded) _evaluateInitial();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _started = true;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settings.removeListener(_onSettingsChanged);
    // Ensure the lock overlay is removed if the gate is disposed while locked.
    // This prevents a stale OverlayEntry from leaking into the next app session.
    _releaseLockEntry();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Lifecycle — grace period
  // -------------------------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (pausedAt == null || !_settings.lockEnabled || _locked) return;
    if (DateTime.now().difference(pausedAt) >= widget.grace) _showLock();
  }

  // -------------------------------------------------------------------------
  // Settings
  // -------------------------------------------------------------------------

  void _onSettingsChanged() {
    if (!_initialEvalDone && _settings.loaded) _evaluateInitial();
    // Turning App lock off anywhere releases an active cover at once.
    if (_locked && !_settings.lockEnabled) _unlock();
    // Rebuild so motion-off, and the freshly loaded user greeting, apply live.
    _safeSetState(() {});
  }

  /// First-build decision, taken as soon as persisted settings are in.
  void _evaluateInitial() {
    _initialEvalDone = true;
    if (_settings.lockEnabled) _showLock();
  }

  // -------------------------------------------------------------------------
  // Cover control
  // -------------------------------------------------------------------------

  /// Shows the cover. Automatic callers (resume, first build) only get here
  /// when `lockEnabled`; [AppLockGateController.lock] is an explicit request
  /// and always honours.
  void _showLock() {
    if (_locked) return;
    _locked = true;
    _loadUser();
    _safeSetState(() {});
  }

  void _unlock() {
    if (!_locked) return;
    _locked = false;
    _releaseLockEntry();
    _safeSetState(() {});
  }

  /// Detaches the cover's overlay entry before the cover unmounts. Has to
  /// run while the entry is still inserted (unmount alone leaves a stale
  /// back-reference behind, which the next lock cycle's `insertAll` rejects).
  /// No-ops when the entry never made it into an Overlay — created during a
  /// build that was discarded before mounting.
  void _releaseLockEntry() {
    final entry = _lockEntry;
    _lockEntry = null;
    _lockContent = null;
    if (entry != null && entry.mounted) entry.remove();
  }

  /// Applies the mutation always; only schedules a rebuild once the first
  /// frame exists (setState during initState would be a build-time error).
  void _safeSetState(VoidCallback fn) {
    fn();
    if (_started && mounted) setState(() {});
  }

  /// Greets the signed-in user on the lock screen; best effort only.
  Future<void> _loadUser() async {
    try {
      final user = await AuthRepository().currentUser();
      if (!mounted || user == null) return;
      _safeSetState(() {
        _userName = user.name;
        _userEmail = user.email;
      });
    } catch (e) {
      debugPrint('SOLVANTA lock: could not read the signed-in user ($e)');
    }
  }

  /// Sign out from the lock screen: end the session, then bump the subtree
  /// key so the guarded Navigator remounts from its initial route ('/') —
  /// the session gate there sees no user and lands on the sign-in screen.
  Future<void> _signOut() async {
    try {
      await AuthRepository().logout();
    } catch (e) {
      // Never strand the user on the lock screen because teardown failed.
      debugPrint('SOLVANTA lock: logout failed ($e)');
    }
    if (!mounted) return;
    _releaseLockEntry();
    _safeSetState(() {
      _locked = false;
      _userName = null;
      _userEmail = null;
      _epoch++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return _AppLockScope(
      controller: _controller,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Keyed so Sign out remounts the whole guarded subtree.
          KeyedSubtree(key: ValueKey('solvanta-app-$_epoch'), child: widget.child),
          if (_locked) Positioned.fill(child: _lockLayer(context)),
        ],
      ),
    );
  }

  Widget _lockLayer(BuildContext context) {
    Widget layer = TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: _settings.motionOff ? Duration.zero : const Duration(milliseconds: 320),
      curve: Curves.easeOut,
      builder: (context, opacity, _) => Opacity(
        opacity: opacity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Input goes here and stops; routes underneath stay painted but
            // unreachable while locked.
            const ModalBarrier(dismissible: false, color: Colors.transparent),
            LockScreen(
              onUnlocked: _unlock,
              onSignOut: _signOut,
              userName: _userName,
              userEmail: _userEmail,
            ),
          ],
        ),
      ),
    );

    // Self-sufficiency fallbacks: with the prescribed wiring (inside
    // MaterialApp's builder) all of these already exist and none of these
    // branches run — they only keep the layer renderable if it is wired a
    // level higher, above MaterialApp.
    if (Directionality.maybeOf(context) == null) {
      layer = Directionality(textDirection: TextDirection.ltr, child: layer);
    }
    if (MediaQuery.maybeOf(context) == null) {
      layer = MediaQuery(
        data: MediaQueryData.fromView(View.of(context)),
        child: layer,
      );
    }
    if (Localizations.of<MaterialLocalizations>(context, MaterialLocalizations) == null) {
      layer = Localizations(
        locale: const Locale('en', 'US'),
        delegates: const [
          DefaultMaterialLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        child: layer,
      );
    }

    // Unlike the fallbacks above, this one runs even with the prescribed
    // wiring: the app's Overlay lives *inside* the Navigator, which sits
    // below the gate, so there is never an ancestor Overlay up here.
    // Overlay-backed widgets (Tooltip — the PIN keys and the biometric
    // button use them — plus menus, dialogs, OverlayPortal) resolve the
    // nearest Overlay and throw "No Overlay widget found" without one; on
    // device that took the whole lock screen down: debug error box, plus a
    // ~100k px cascade overflow from the injected error widget inside the
    // header's unbounded FittedBox chain.
    //
    // `Overlay` only consumes `initialEntries` in `initState`, so the entry
    // is created once per lock cycle, mirrors the cover through
    // [_lockContent], and re-announces itself with
    // [OverlayEntry.markNeedsBuild] — legal mid-build because the entry's
    // element is a descendant of the gate that is currently building (see
    // Element.markNeedsBuild). [_releaseLockEntry] removes it again.
    if (Overlay.maybeOf(context) == null) {
      _lockContent = layer;
      final entry = _lockEntry ?? OverlayEntry(
        builder: (_) => SizedBox.expand(child: _lockContent!),
      );
      _lockEntry = entry;
      entry.markNeedsBuild();
      layer = Overlay(initialEntries: [entry]);
    }
    return layer;
  }
}

/// Exposes the [AppLockGateController] to everything below the gate.
class _AppLockScope extends InheritedWidget {
  const _AppLockScope({required this.controller, required super.child});

  final AppLockGateController controller;

  @override
  bool updateShouldNotify(_AppLockScope oldWidget) => oldWidget.controller != controller;
}
