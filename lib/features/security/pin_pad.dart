import 'package:flutter/material.dart';

import '../../core/ui/ui_kit.dart';

/// Reusable numeric keypad for PIN entry: digits 0–9, a delete key and an
/// optional biometric key in the bottom-left slot.
///
/// Design notes:
/// * Every key fires [svHaptic] (`SvHaptic.selection`) before invoking its
///   callback — `svHaptic` already honours the Haptics preference, so this
///   is safe to call unconditionally.
/// * Every key is a real, focusable [TextButton] wrapped in [Semantics] with
///   a spoken label ("Digit 5", "Delete"), so keyboard/switch access and
///   screen readers work. Icons never ship without a label.
/// * Keys stretch to fill the available box (`Expanded` rows/columns inside
///   the caller's constraints), giving large touch targets and letting the
///   pad scale with device width and large text instead of overflowing.
class PinPad extends StatelessWidget {
  const PinPad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    this.onBiometric,
    this.biometricIcon = Icons.fingerprint,
    this.enabled = true,
    this.keyColor,
    this.keyFill,
  });

  /// Called with the pressed digit (`'0'`–`'9'`).
  final ValueChanged<String> onDigit;

  /// Called when the delete key is pressed.
  final VoidCallback onBackspace;

  /// Rendered in the bottom-left slot when non-null (fingerprint / face).
  final VoidCallback? onBiometric;

  /// Icon for [onBiometric].
  final IconData biometricIcon;

  /// When false, every key renders disabled (used for the wrong-PIN
  /// rate-limit cooldown). Keys stay labelled, just not actionable.
  final bool enabled;

  /// Key foreground (digit/icon) colour. Defaults to white for the navy
  /// lock screen; pass theme colours when reusing on a light surface.
  final Color? keyColor;

  /// Key background fill. Defaults to a subtle 10% white tint.
  final Color? keyFill;

  @override
  Widget build(BuildContext context) {
    final fg = keyColor ?? Colors.white;
    final fill = keyFill ?? Colors.white.withValues(alpha: .10);

    Widget digit(String d) => _PadKey(
          enabled: enabled,
          fill: fill,
          fg: fg,
          onPressed: () {
            svHaptic(SvHaptic.selection);
            onDigit(d);
          },
          child: Semantics(
            label: 'Digit $d',
            excludeSemantics: true,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(d, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
            ),
          ),
        );

    final deleteKey = _PadKey(
      enabled: enabled,
      fill: fill,
      fg: fg,
      tooltip: 'Delete',
      onPressed: () {
        svHaptic(SvHaptic.selection);
        onBackspace();
      },
      child: Semantics(
        label: 'Delete',
        excludeSemantics: true,
        child: const Icon(Icons.backspace_outlined, size: 24),
      ),
    );

    final Widget bottomLeft;
    final cb = onBiometric;
    if (cb == null) {
      bottomLeft = const SizedBox();
    } else {
      bottomLeft = _PadKey(
        enabled: enabled,
        fill: fill,
        fg: fg,
        tooltip: 'Verify it’s you',
        onPressed: () {
          svHaptic(SvHaptic.selection);
          cb();
        },
        child: Semantics(
          label: 'Verify it’s you',
          excludeSemantics: true,
          child: Icon(biometricIcon, size: 26),
        ),
      );
    }

    Widget row(List<Widget> keys) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Row(
              // Stretch so every key fills its cell → maximum touch target.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final k in keys) Expanded(child: k)],
            ),
          ),
        );

    // When the caller gives the pad an unbounded height (e.g. inside a
    // scroll view), fall back to a 4:3 box derived from the width so the
    // rows still lay out.
    return LayoutBuilder(
      builder: (context, constraints) {
        final unbounded = !constraints.hasBoundedHeight || constraints.maxHeight.isInfinite;
        final height = unbounded
            ? (constraints.maxWidth.isFinite ? constraints.maxWidth * 4 / 3 : 320.0)
            : null;
        return SizedBox(
          height: height,
          child: Column(
            children: [
              row([digit('1'), digit('2'), digit('3')]),
              row([digit('4'), digit('5'), digit('6')]),
              row([digit('7'), digit('8'), digit('9')]),
              row([bottomLeft, digit('0'), deleteKey]),
            ],
          ),
        );
      },
    );
  }
}

/// One keypad cell: a full-cell [TextButton] with press feedback, optional
/// tooltip and a disabled state that keeps its semantics label.
class _PadKey extends StatelessWidget {
  const _PadKey({
    required this.onPressed,
    required this.fill,
    required this.fg,
    required this.child,
    this.tooltip,
    this.enabled = true,
  });

  final VoidCallback? onPressed;
  final Color fill;
  final Color fg;
  final Widget child;
  final String? tooltip;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    Widget key = TextButton(
      onPressed: enabled ? onPressed : null,
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        backgroundColor: fill,
        foregroundColor: fg,
        disabledBackgroundColor: Colors.transparent,
        disabledForegroundColor: fg.withValues(alpha: .35),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Center(child: child),
    );
    final tip = tooltip;
    if (tip != null) key = Tooltip(message: tip, child: key);
    return SvPressScale(child: key);
  }
}
