import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/security/secret_hash.dart';
import '../../core/settings/app_settings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import 'pin_pad.dart';

/// Full-screen branded lock cover shown by [AppLockGate].
///
/// Visual language: the navy gradient (`AppTheme.navy900` → `navy700`) with a
/// single gold hairline under the SOLVANTA wordmark; white text is correct on
/// this surface in both theme modes. Status is always glyph + text
/// (⚠ "Incorrect PIN"), never colour alone.
///
/// Unlock paths, in preference order:
/// 1. `lockMethod == 'biometric'` → a fingerprint/face button, with the
///    4–6 digit PIN keypad underneath as an alternative/fallback.
/// 2. `lockMethod == 'pin'` → the keypad directly.
/// 3. **No PIN set** → a device-credential prompt
///    (`local_auth`, `biometricOnly: false`); if the platform errors out
///    (widget tests, unsupported device, missing Activity) the screen falls
///    back to a clear explanatory state with a working **Continue** button.
///
/// The screen can never brick the user: every state exposes Sign out, and
/// every failure state exposes either the keypad or Continue.
class LockScreen extends StatefulWidget {
  const LockScreen({
    super.key,
    required this.onUnlocked,
    required this.onSignOut,
    this.userName,
    this.userEmail,
  });

  /// Invoked once a check succeeds (correct PIN, biometric or Continue).
  final VoidCallback onUnlocked;

  /// Ends the session. The returned future should complete once the sign-out
  /// has been applied (the gate remounts the app tree underneath).
  final Future<void> Function() onSignOut;

  /// Signed-in user's display name, when the caller could resolve one.
  final String? userName;

  /// Signed-in user's e-mail address, when available.
  final String? userEmail;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> with SingleTickerProviderStateMixin {
  final _settings = AppSettings.instance;
  final _localAuth = LocalAuthentication();

  late final AnimationController _shake =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 380));

  String _entry = '';
  String? _message;
  bool _messageIsError = true;
  int _failures = 0;
  bool _cooldown = false;
  Timer? _cooldownTimer;
  bool _busy = false;
  bool _autoPrompted = false;
  bool _bioFailed = false;
  // True only when the device reports it cannot authenticate at all
  // (isDeviceSupported() == false) — the genuine anti-brick case. A prompt that
  // merely FAILED or was cancelled must never unlock the app, so Continue is
  // keyed off this flag rather than off _bioFailed.
  bool _deviceAuthUnavailable = false;
  bool _signingOut = false;
  IconData _bioIcon = Icons.fingerprint;
  String _bioLabel = 'Verify it’s you';

  /// The stored PIN verifier (hashed after migration, plain for an install
  /// that has not loaded yet); anything unusable counts as "no PIN" so the
  /// fallback paths (device credential / Continue) take over.
  String get _pin => _settings.lockPin ?? '';
  bool get _hasPin => _settings.hasLockPin;
  int get _pinLength => _hasPin ? _settings.lockPinLength : 4;
  bool get _methodBiometric => _settings.lockMethod == 'biometric';

  @override
  void initState() {
    super.initState();
    // Auto-attempt once shortly after showing the lock, so the user is not
    // asked to tap the fingerprint before anything happens. Runs after the
    // first frame; any platform failure is caught inside _authenticate.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _autoPrompted) return;
      _autoPrompted = true;
      if (_methodBiometric || !_hasPin) {
        _resolveBiometricIcon();
        _authenticate();
      }
    });
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _shake.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Biometric / device-credential path
  // -------------------------------------------------------------------------

  /// Resolves a face/fingerprint icon so the button matches the device.
  Future<void> _resolveBiometricIcon() async {
    try {
      final types = await _localAuth.getAvailableBiometrics();
      if (!mounted || types.isEmpty) return;
      setState(() {
        if (types.contains(BiometricType.face)) {
          _bioIcon = Icons.face;
          _bioLabel = 'Face unlock';
        } else if (types.contains(BiometricType.fingerprint)) {
          _bioIcon = Icons.fingerprint;
          _bioLabel = 'Fingerprint';
        }
      });
    } catch (e) {
      debugPrint('SOLVANTA lock: biometric types unavailable ($e)');
    }
  }

  /// Attempts local authentication. Never throws: tests, unsupported devices
  /// and missing-Activity errors all degrade to the PIN / Continue path.
  Future<void> _authenticate() async {
    if (_busy || _cooldown) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (!await _localAuth.isDeviceSupported()) {
        if (!mounted) return;
        setState(() {
          _bioFailed = true;
          // Device genuinely can't authenticate — the only state allowed to
          // offer Continue.
          _deviceAuthUnavailable = true;
          _messageIsError = false;
          _message = 'Automatic check unavailable';
        });
        return;
      }
      final ok = await _localAuth.authenticate(
        localizedReason: 'Unlock SOLVANTA to access your school data',
        options: const AuthenticationOptions(
          // Also offer the device PIN/pattern/passcode inside the prompt…
          biometricOnly: false,
          // …and resume the prompt if the app is briefly backgrounded.
          stickyAuth: true,
        ),
      );
      if (!mounted) return;
      if (ok) {
        svHaptic(SvHaptic.medium);
        widget.onUnlocked();
        return;
      }
      setState(() {
        _bioFailed = true;
        _messageIsError = true;
        _message = _hasPin ? 'Couldn’t verify — enter your PIN' : 'Verification didn’t finish';
      });
    } catch (e) {
      debugPrint('SOLVANTA lock: local auth failed, falling back ($e)');
      if (!mounted) return;
      setState(() {
        _bioFailed = true;
        _messageIsError = false;
        _message = _hasPin ? 'Biometrics unavailable — use your PIN' : 'Automatic check unavailable';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // -------------------------------------------------------------------------
  // PIN path
  // -------------------------------------------------------------------------

  void _onDigit(String d) {
    if (_cooldown || _entry.length >= _pinLength) return;
    setState(() {
      _entry += d;
      _message = null;
    });
    if (_entry.length == _pinLength) _verifyPin();
  }

  void _onBackspace() {
    if (_cooldown || _entry.isEmpty) return;
    setState(() => _entry = _entry.substring(0, _entry.length - 1));
  }

  void _verifyPin() {
    if (verifySecret(_entry, _pin)) {
      _upgradeLegacyPin();
      svHaptic(SvHaptic.medium);
      widget.onUnlocked();
      return;
    }
    _failures++;
    svHaptic(SvHaptic.error);
    if (!_settings.motionOff) _shake.forward(from: 0);
    setState(() {
      _entry = '';
      _messageIsError = true;
      _message = _failures >= 5 ? 'Too many attempts — hold on' : 'Incorrect PIN';
    });
    if (_failures >= 5) _startCooldown();
  }

  /// Rewrites a legacy plain PIN in hashed form once it has verified. [load]
  /// normally migrates it earlier, but the plain value must not outlive a
  /// successful unlock even if settings were read through another path.
  void _upgradeLegacyPin() {
    final stored = _settings.lockPin;
    if (stored == null || stored.isEmpty || isHashedSecret(stored)) return;
    // Fire and forget: the session is already opening.
    _settings.setLockPin(stored);
  }

  /// Rate limit: after five wrong PINs the keypad pauses for a few seconds.
  /// Delays are security, not motion, so they are not reduced by
  /// Reduce motion / Data saver.
  void _startCooldown() {
    if (_cooldown) return;
    setState(() => _cooldown = true);
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() {
        _cooldown = false;
        _failures = 0;
      });
    });
  }

  Future<void> _handleSignOut() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);
    await widget.onSignOut();
    if (mounted) setState(() => _signingOut = false);
  }

  double get _shakeShift {
    final t = _shake.value;
    return math.sin(t * math.pi * 4) * 12 * (1 - t);
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.navy900,
      // No text input on this screen; never jump for the keyboard.
      resizeToAvoidBottomInset: false,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppTheme.navy900, AppTheme.navy700],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
            child: Column(
              children: [
                // Flexible + FittedBox: the header scales down instead of
                // overflowing at very large text sizes.
                Expanded(
                  flex: 1,
                  child: Center(
                    child: FittedBox(fit: BoxFit.scaleDown, child: _header()),
                  ),
                ),
                SizedBox(height: 40, child: Center(child: _status())),
                Expanded(
                  flex: 2,
                  child: _hasPin ? _pinBody() : _noPinBody(),
                ),
                _signOutRow(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'SOLVANTA',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: 5,
          ),
        ),
        const SizedBox(height: 10),
        // The gold hairline — the one accent on the lock surface.
        Container(
          width: 72,
          height: 2,
          decoration: const BoxDecoration(
            color: AppTheme.gold,
            borderRadius: BorderRadius.all(Radius.circular(1)),
          ),
        ),
        const SizedBox(height: 12),
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 14, color: Colors.white70),
            SizedBox(width: 6),
            Text(
              'App locked',
              style: TextStyle(color: Colors.white70, fontSize: 12.5, letterSpacing: .6),
            ),
          ],
        ),
        if (widget.userName != null) ...[
          const SizedBox(height: 12),
          Text(
            'Welcome back, ${widget.userName}',
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
          ),
        ],
        if (widget.userEmail != null) ...[
          const SizedBox(height: 2),
          Text(
            widget.userEmail!,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white.withValues(alpha: .72), fontSize: 12.5),
          ),
        ],
      ],
    );
  }

  /// Glyph + text status line, announced to screen readers (live region).
  /// A fixed-height box keeps the keypad from jumping when it appears.
  Widget _status() {
    final message = _message;
    if (message == null) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      label: message,
      child: ExcludeSemantics(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: _messageIsError
              ? SvStatusBadge(
                  label: message,
                  icon: Icons.warning_amber_rounded,
                  color: Colors.white,
                  backgroundColor: AppColors.dangerSolid,
                )
              : SvStatusBadge(
                  label: message,
                  icon: Icons.info_outline,
                  color: AppTheme.gold,
                  backgroundColor: Colors.white.withValues(alpha: .14),
                ),
        ),
      ),
    );
  }

  Widget _biometricButton() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: 'Verify it’s you with biometrics or device credentials',
          child: Tooltip(
            message: 'Verify it’s you',
            child: TextButton(
              onPressed: (_busy || _cooldown) ? null : _authenticate,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.all(18),
                minimumSize: const Size(88, 88),
                backgroundColor: Colors.white.withValues(alpha: .10),
                foregroundColor: Colors.white,
                disabledForegroundColor: Colors.white.withValues(alpha: .45),
                // Gold hairline circle — key accent, used sparingly.
                shape: const CircleBorder(
                  side: BorderSide(color: AppTheme.gold, width: 1.3),
                ),
              ),
              child: Icon(_bioIcon, size: 40, color: Colors.white),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _busy ? 'Checking…' : _bioLabel,
          style: TextStyle(color: Colors.white.withValues(alpha: .75), fontSize: 12.5),
        ),
      ],
    );
  }

  Widget _pinBody() {
    final showBiometric = _methodBiometric;
    Widget body = Column(
      children: [
        if (showBiometric) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [FittedBox(fit: BoxFit.scaleDown, child: _biometricButton())],
          ),
          const SizedBox(height: 6),
        ],
        _dots(),
        const SizedBox(height: 8),
        Expanded(
          child: PinPad(
            onDigit: _onDigit,
            onBackspace: _onBackspace,
            onBiometric: (showBiometric && !_cooldown) ? _authenticate : null,
            biometricIcon: _bioIcon,
            enabled: !_cooldown,
          ),
        ),
      ],
    );
    if (_settings.motionOff) return body;
    // Wrong-PIN shake; skipped entirely under Reduce motion / Data saver.
    return AnimatedBuilder(
      animation: _shake,
      builder: (context, child) => Transform.translate(
        offset: Offset(_shakeShift, 0),
        child: child,
      ),
      child: body,
    );
  }

  Widget _dots() {
    final motionOff = _settings.motionOff;
    return Semantics(
      label: '${_entry.length} of $_pinLength digits entered',
      child: ExcludeSemantics(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < _pinLength; i++)
              AnimatedContainer(
                duration: motionOff ? Duration.zero : const Duration(milliseconds: 150),
                margin: const EdgeInsets.symmetric(horizontal: 6),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < _entry.length
                      ? Colors.white
                      : Colors.white.withValues(alpha: .25),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// No usable PIN: offer the device-credential prompt. Continue appears only
  /// when the device cannot authenticate at all (the anti-brick state) — a
  /// prompt that merely FAILED or was cancelled must not open the app, so the
  /// biometric button above stays as the retry path instead.
  Widget _noPinBody() {
    final unsupported = _deviceAuthUnavailable;
    final failed = _bioFailed;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [FittedBox(fit: BoxFit.scaleDown, child: _biometricButton())],
            ),
            const SizedBox(height: 16),
            Text(
              unsupported
                  ? 'Automatic check didn’t work'
                  : failed
                      ? 'Couldn’t verify you'
                      : 'Confirm it’s you',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              unsupported
                  ? 'No PIN is set for the app and this device can’t verify you '
                      'automatically. Continue to open the app — you can add a PIN '
                      'in Settings › Security at any time.'
                  : failed
                      ? 'Verification didn’t finish. Try again with the button '
                          'above, or sign out to start over.'
                      : 'You’ll be asked for your device’s fingerprint, face or screen lock.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: .75),
                fontSize: 13,
                height: 1.5,
              ),
            ),
            if (unsupported) ...[
              const SizedBox(height: 18),
              FilledButton(
                onPressed: widget.onUnlocked,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppTheme.navy900,
                ),
                child: const Text('Continue'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The escape hatch: always present, always works, even mid-PIN.
  Widget _signOutRow() {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton.icon(
            onPressed: _signingOut ? null : _handleSignOut,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: Text(_signingOut ? 'Signing out…' : 'Sign out'),
          ),
        ],
      ),
    );
  }
}
