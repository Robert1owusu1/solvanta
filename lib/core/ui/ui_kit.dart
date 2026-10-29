import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings/app_settings.dart';
import '../theme/app_theme.dart';

/// Centered loading view with an optional human-friendly message.
///
/// Use instead of a bare `CircularProgressIndicator` so users always
/// understand the app is working and why.
class SvLoading extends StatelessWidget {
  const SvLoading({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Labelled so screen readers say "Loading" instead of reading
          // nothing while data arrives.
          const SizedBox(
            height: 28,
            width: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              semanticsLabel: 'Loading',
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: 14),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }
}

/// Friendly error state. Ordinary users never need to see stack traces;
/// a clear explanation plus a retry action is enough.
class SvErrorState extends StatelessWidget {
  const SvErrorState({
    super.key,
    this.title = 'Something went wrong',
    this.message = 'We couldn\'t load this screen. Check your connection and try again.',
    this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Semantics(
          container: true,
          // Announce the failure when it replaces content on screen.
          liveRegion: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                excludeSemantics: true,
                label: 'Error',
                child: Icon(Icons.error_outline,
                    size: 40, color: AppColors.danger),
              ),
              const SizedBox(height: 12),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted, fontSize: 13),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Friendly empty state that answers *what is missing*, *why it matters*,
/// and *what the user can do next*.
class SvEmptyState extends StatelessWidget {
  const SvEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: AppColors.brand.withValues(alpha: .1),
              child: Icon(icon, size: 30, color: AppColors.brand),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.add),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Status indicator that uses an icon + label + color together, so status
/// is never communicated by color alone.
class SvStatusBadge extends StatelessWidget {
  const SvStatusBadge({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    this.backgroundColor,
  });

  final String label;
  final IconData icon;
  final Color color;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        // 6% keeps the tint but clears WCAG AA (4.5:1) for the small bold
        // label: at 12% Correct was 4.20:1 and Needs review 4.25:1.
        color: backgroundColor ?? color.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Consistent section heading used across list screens.
class SvSectionTitle extends StatelessWidget {
  const SvSectionTitle(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 16,
            decoration: BoxDecoration(
              color: AppTheme.gold,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w800, height: 1.1),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Consistent SnackBar messaging. Use [error] = true for failures so the
/// message is clearly distinguished from success.
void svSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? AppColors.danger : null,
        duration: const Duration(seconds: 3),
      ),
    );
}

/// Asks the user to confirm an action before it runs. Resolves to true only
/// when [confirmLabel] is tapped; dismissing or cancelling resolves false.
/// Use [destructive] for actions that end a session or discard data.
Future<bool> svConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Fades + slides [child] in once when it first appears. Use [delay] with an
/// index-based offset to stagger lists: `SvEntrance(delay: Duration(milliseconds: 60 * i), child: …)`.
class SvEntrance extends StatefulWidget {
  const SvEntrance({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 480),
    this.offset = const Offset(0, .06),
    this.curve = Curves.easeOutCubic,
  });

  final Widget child;
  final Duration delay;
  final Duration duration;

  /// Slide distance as a fraction of the child's size (defaults to 6% up).
  final Offset offset;
  final Curve curve;

  @override
  State<SvEntrance> createState() => _SvEntranceState();
}

class _SvEntranceState extends State<SvEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _shift;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    final curved = CurvedAnimation(parent: _controller, curve: widget.curve);
    _fade = Tween<double>(begin: 0, end: 1).animate(curved);
    _shift = Tween<Offset>(begin: widget.offset, end: Offset.zero).animate(curved);
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      _timer = Timer(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reduce motion / data saver / the OS "remove animations" setting: show
    // the child at rest instead of fading and sliding it in.
    if (AppSettings.instance.motionOff ||
        MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _shift, child: widget.child),
    );
  }
}

/// Gently scales [child] down while the user holds a tap. Wrap any tappable
/// card/tile for a tactile "pressed" response.
class SvPressScale extends StatefulWidget {
  const SvPressScale({
    super.key,
    required this.child,
    this.scaled = .98,
    this.duration = const Duration(milliseconds: 100),
  });

  final Widget child;
  final double scaled;
  final Duration duration;

  @override
  State<SvPressScale> createState() => _SvPressScaleState();
}

class _SvPressScaleState extends State<SvPressScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    // No press feedback motion when the user asked for stillness.
    final still = AppSettings.instance.motionOff ||
        MediaQuery.disableAnimationsOf(context);
    return Listener(
      onPointerDown: still ? null : (_) => setState(() => _pressed = true),
      onPointerUp: still ? null : (_) => setState(() => _pressed = false),
      onPointerCancel: still ? null : (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: (_pressed && !still) ? widget.scaled : 1,
        duration: widget.duration,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Counts [value] up from zero when it first appears. Falls back to a static
/// [Text] when [value] isn't a plain number.
class SvAnimatedNumber extends StatelessWidget {
  const SvAnimatedNumber({
    super.key,
    required this.value,
    this.style,
    this.duration = const Duration(milliseconds: 700),
  });

  final String value;
  final TextStyle? style;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final n = int.tryParse(value.trim());
    // Stillness (or no animation) means the final number, straight away.
    if (n == null ||
        AppSettings.instance.motionOff ||
        MediaQuery.disableAnimationsOf(context)) {
      return Text(value, style: style);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: n.toDouble()),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Text('${v.round()}', style: style),
    );
  }
}

/// Branded gradient header used on every module screen so each screen opened
/// from the dashboard leads with the same visual language as the dashboard
/// hero. Covers back navigation, an optional subtitle and [actions].
class SvScreenHeader extends StatelessWidget
    implements PreferredSizeWidget {
  const SvScreenHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.autoBack = true,
    this.colors = const [AppTheme.brand, AppTheme.brandLight],
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final bool autoBack;
  final List<Color> colors;

  @override
  Size get preferredSize => Size.fromHeight(subtitle == null ? 96 : 114);

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final canPop = Navigator.of(context).canPop();
    return Container(
      width: double.infinity,
      height: preferredSize.height,
      padding: EdgeInsets.fromLTRB(8, top, 8, 0),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (autoBack && canPop)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Ink(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .16),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  tooltip: 'Back',
                  onPressed: () => Navigator.maybePop(context),
                  icon: const Icon(Icons.arrow_back_rounded,
                      color: Colors.white),
                ),
              ),
            ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: .78),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// A single option for [SvFilterChips].
class SvFilterOption {
  const SvFilterOption(this.label, {this.selected = false, this.value});

  final String label;
  final bool selected;
  final Object? value;
}

/// Horizontal row of pill chips for filtering a list. The selected option is
/// filled with the brand color, the rest are neutral surfaces — a much kinder
/// alternative to stacked dropdowns on small screens.
class SvFilterChips extends StatelessWidget {
  const SvFilterChips({
    super.key,
    required this.options,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final List<SvFilterOption> options;
  final ValueChanged<int> onSelected;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: Row(
        children: [
          for (var i = 0; i < options.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(options[i].label),
                selected: options[i].selected,
                showCheckmark: false,
                onSelected: (_) => onSelected(i),
                selectedColor: AppTheme.brand,
                backgroundColor: AppColors.surface,
                side: BorderSide(
                  color: options[i].selected
                      ? AppTheme.brand
                      : AppColors.border,
                ),
                labelStyle: TextStyle(
                  color: options[i].selected ? Colors.white : AppColors.ink,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
                visualDensity: VisualDensity.compact,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Consistent search input with a brand icon, rounded surface and a clear
/// button. Theme-level input decoration is applied automatically.
class SvSearchField extends StatefulWidget {
  const SvSearchField({
    super.key,
    required this.onChanged,
    this.hint = 'Search…',
    this.controller,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 0),
  });

  final ValueChanged<String> onChanged;
  final String hint;
  final TextEditingController? controller;
  final EdgeInsetsGeometry padding;

  @override
  State<SvSearchField> createState() => _SvSearchFieldState();
}

class _SvSearchFieldState extends State<SvSearchField> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.padding,
      child: TextField(
        controller: _controller,
        onChanged: widget.onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: widget.hint,
          prefixIcon: Icon(Icons.search_rounded, color: AppColors.brand),
          prefixIconColor: AppTheme.brand,
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Clear',
                    icon: Icon(Icons.cancel, color: AppColors.muted),
                    onPressed: () {
                      _controller.clear();
                      widget.onChanged('');
                      setState(() {});
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

/// The consistent list card for every screen: a gradient avatar (initials or
/// icon), a bold title, optional meta line, an optional status [chip] and a
/// chevron affordance when it opens something.
class SvAvatarTile extends StatelessWidget {
  const SvAvatarTile({
    super.key,
    required this.title,
    this.meta,
    this.initials,
    this.icon,
    this.chip,
    this.onTap,
    this.avatarColor,
    this.trailing,
    this.color,
  });

  final String title;
  final String? meta;
  final String? initials;
  final IconData? icon;
  final Widget? chip;
  final VoidCallback? onTap;
  /// The avatar's hue (icon/initials plate).
  final Color? avatarColor;
  final Widget? trailing;

  /// Optional *card* background — e.g. a ~8% tint of the row's status colour
  /// for an unread notification. Null keeps the theme's surface. This is a
  /// different channel from [avatarColor]; conflating them paints the whole
  /// tile in the avatar colour and hides the ink-coloured text inside it.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final hue = avatarColor ?? AppTheme.brand;
    final opens = onTap != null;
    return Card(
      color: color,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 14, vertical: 6),
        leading: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [hue, hue.withValues(alpha: .58)],
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Center(
            child: initials != null
                ? Text(
                    initials!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  )
                : Icon(icon, color: Colors.white, size: 22),
          ),
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
        subtitle: meta == null
            ? null
            : Text(
                meta!,
                style: const TextStyle(fontSize: 13, height: 1.35),
              ),
        trailing: trailing ??
            (chip != null
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      chip!,
                      if (opens) const SizedBox(width: 2),
                      if (opens)
                        Icon(Icons.chevron_right,
                            size: 20, color: AppColors.muted),
                    ],
                  )
                : opens
                    ? Icon(Icons.chevron_right,
                        size: 20, color: AppColors.muted)
                    : null),
        onTap: onTap,
      ),
    );
  }
}

/// A convenient way to attach a status [SvStatusBadge] to an [SvAvatarTile].
Widget svStatus(String label, IconData icon, Color color) {
  return SvStatusBadge(label: label, icon: icon, color: color);
}

// ---------------------------------------------------------------------------
// Haptics
// ---------------------------------------------------------------------------

/// Flavours of tactile feedback used across the app.
enum SvHaptic {
  /// Light tick — tab changes, opening a screen.
  light,

  /// Selection tick — chips, filters, keypad digits, toggles.
  selection,

  /// Firm bump — a meaningful commit: marking state, attendance check-in,
  /// recording a payment.
  medium,

  /// Heavier bump — something the user should notice went wrong.
  error,
}

/// Fires a haptic tick unless the user turned haptics off in Settings.
///
/// Always safe to call: on platforms without a vibrator the call no-ops, and
/// we short-circuit first so we never even reach the platform channel when
/// the preference is off.
void svHaptic(SvHaptic kind) {
  if (!AppSettings.instance.haptics) return;
  switch (kind) {
    case SvHaptic.light:
      HapticFeedback.lightImpact();
    case SvHaptic.selection:
      HapticFeedback.selectionClick();
    case SvHaptic.medium:
      HapticFeedback.mediumImpact();
    case SvHaptic.error:
      HapticFeedback.heavyImpact();
  }
}

// ---------------------------------------------------------------------------
// Skeleton loaders
// ---------------------------------------------------------------------------

/// A single shimmering placeholder block.
///
/// Prefer skeletons over spinners for list/grid content so the page keeps its
/// shape while data arrives. The shimmer is suppressed automatically when the
/// user enables Reduce motion or Data saver (Settings), degrading to a static
/// block.
class SvSkeleton extends StatefulWidget {
  const SvSkeleton({
    super.key,
    this.width = double.infinity,
    this.height = 14,
    this.radius = 8,
    this.circle = false,
  });

  final double width;
  final double height;
  final double radius;

  /// Renders a pill/avatar shape (radius = half the height). Requires an
   /// explicit finite [width].
  final bool circle;

  @override
  State<SvSkeleton> createState() => _SvSkeletonState();
}

class _SvSkeletonState extends State<SvSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    );
    // Never start a looping ticker the user asked us not to run.
    if (!AppSettings.instance.motionOff) _controller.repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Preferences can flip while we are on screen.
    if (AppSettings.instance.motionOff) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = AppColors.ink.withValues(alpha: AppColors.isDark ? .10 : .07);
    final sheen = AppColors.ink.withValues(alpha: AppColors.isDark ? .20 : .15);
    final radius = BorderRadius.circular(
      widget.circle ? widget.height / 2 : widget.radius,
    );

    if (AppSettings.instance.motionOff) {
      return ExcludeSemantics(
        child: Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(color: base, borderRadius: radius),
        ),
      );
    }

    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                begin: Alignment(-1.6 + 2.4 * t, 0),
                end: Alignment(-0.6 + 2.4 * t, 0),
                colors: [base, sheen, base],
                stops: const [0, .5, 1],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// List-row skeleton that mimics the geometry of an [SvAvatarTile].
class SvListSkeleton extends StatelessWidget {
  const SvListSkeleton({super.key, this.rows = 5, this.avatar = true});

  final int rows;
  final bool avatar;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: rows,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            if (avatar) ...[
              const SvSkeleton(width: 46, height: 46, radius: 14),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  SvSkeleton(height: 13),
                  SizedBox(height: 9),
                  SvSkeleton(width: 150, height: 11),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Card skeleton shaped like the dashboard "needs attention" panel.
class SvCardSkeleton extends StatelessWidget {
  const SvCardSkeleton({super.key, this.lines = 3});

  final int lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              SvSkeleton(width: 40, height: 40, radius: 13),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SvSkeleton(width: 140, height: 13),
                    SizedBox(height: 8),
                    SvSkeleton(width: 96, height: 11),
                  ],
                ),
              ),
            ],
          ),
          for (var i = 0; i < lines; i++) ...[
            const SizedBox(height: 16),
            const SvSkeleton(height: 12),
          ],
        ],
      ),
    );
  }
}

/// Two-column grid skeleton matching the dashboard module grid.
class SvGridSkeleton extends StatelessWidget {
  const SvGridSkeleton({super.key, this.count = 4});

  final int count;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.32,
      children: [
        for (var i = 0; i < count; i++)
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.border),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SvSkeleton(width: 40, height: 40, radius: 13),
                    Spacer(),
                    SvSkeleton(width: 44, height: 16, circle: true),
                  ],
                ),
                Spacer(),
                SvSkeleton(width: 92, height: 13),
                SizedBox(height: 8),
                SvSkeleton(width: 130, height: 10),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Pull to refresh
// ---------------------------------------------------------------------------

/// Branded pull-to-refresh wrapper with a haptic tick on release.
///
/// The [child] must be scrollable; add `AlwaysScrollableScrollPhysics` to it
/// so the gesture also works when the list is short.
class SvRefresh extends StatelessWidget {
  const SvRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        svHaptic(SvHaptic.selection);
        await onRefresh();
      },
      color: AppColors.brand,
      backgroundColor: AppColors.surface,
      strokeWidth: 2.6,
      edgeOffset: 10,
      child: child,
    );
  }
}