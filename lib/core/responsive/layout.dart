library solvanta_responsive_layout;

/// Responsive layout widgets for SOLVANTA.
///
/// These widgets adapt their layout based on the available width and device class.
/// They follow Material Design 3 responsive patterns.

import 'package:flutter/material.dart';
import 'breakpoints.dart';

/// A widget that builds itself differently based on the current device class.
///
/// Use this for semantic layout changes (e.g., phone vs tablet vs desktop)
/// rather than pixel-perfect breakpoints.
class ResponsiveBuilder extends StatelessWidget {
  const ResponsiveBuilder({
    super.key,
    this.builder,
    this.phone,
    this.smallTablet,
    this.tablet,
    this.largeTablet,
    this.desktop,
    this.largeDesktop,
  });

  /// Builds the widget for any device class not explicitly provided.
  final Widget Function(BuildContext, DeviceClass)? builder;

  /// Optional specific builders for each device class.
  /// If not provided, falls back to [builder] or throws if neither is provided.
  final Widget Function(BuildContext)? phone;
  final Widget Function(BuildContext)? smallTablet;
  final Widget Function(BuildContext)? tablet;
  final Widget Function(BuildContext)? largeTablet;
  final Widget Function(BuildContext)? desktop;
  final Widget Function(BuildContext)? largeDesktop;

  @override
  Widget build(BuildContext context) {
    final dc = context.deviceClass;
    final widget = switch (dc) {
      DeviceClass.phone => phone,
      DeviceClass.smallTablet => smallTablet,
      DeviceClass.tablet => tablet,
      DeviceClass.largeTablet => largeTablet,
      DeviceClass.desktop => desktop,
      DeviceClass.largeDesktop => largeDesktop,
    };
    if (widget != null) return widget(context);
    if (builder != null) return builder!(context, dc);
    throw StateError('ResponsiveBuilder: no builder provided for $dc');
  }
}

/// A widget that builds itself based on a specific breakpoint.
///
/// Use this for pixel-perfect control when you need to change layout
/// at exact width thresholds.
class BreakpointBuilder extends StatelessWidget {
  const BreakpointBuilder({
    super.key,
    required this.builder,
    this.breakpoints = const [],
  });

  /// List of (breakpoint, builder) pairs, evaluated in order.
  /// The first matching breakpoint (width >= breakpoint) wins.
  final List<(double, Widget Function(BuildContext))> breakpoints;

  /// Fallback builder when no breakpoint matches.
  final Widget Function(BuildContext) builder;

  @override
  Widget build(BuildContext context) {
    final width = context.width;
    for (final (bp, b) in breakpoints) {
      if (width >= bp) return b(context);
    }
    return builder(context);
  }
}

/// A responsive container that centers content and constrains max width.
///
/// On phone: full width with responsive padding
/// On tablet: max 720dp centered
/// On desktop: max 1024dp centered
/// On large desktop: max 1280dp centered
class ResponsivePage extends StatelessWidget {
  const ResponsivePage({
    super.key,
    required this.child,
    this.padding,
    this.maxWidth,
    this.centered = true,
    this.backgroundColor,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double? maxWidth;
  final bool centered;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final dc = context.deviceClass;
    final mw = maxWidth ?? responsiveMaxWidth(context);
    final p = padding ?? responsivePadding(context);

    final content = Padding(
      padding: p,
      child: child,
    );

    if (dc == DeviceClass.phone) {
      return Container(
        color: backgroundColor,
        child: content,
      );
    }

    return Container(
      color: backgroundColor,
      child: centered
          ? Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: mw),
                child: content,
              ),
            )
          : ConstrainedBox(
              constraints: BoxConstraints(maxWidth: mw),
              child: content,
            ),
    );
  }
}

/// A responsive grid that adapts columns based on available width.
///
/// Wraps [GridView.count] with automatic column calculation.
class ResponsiveGridView extends StatelessWidget {
  const ResponsiveGridView({
    super.key,
    required this.children,
    this.minItemWidth = 220,
    this.maxColumns = 6,
    this.minColumns = 2,
    this.mainAxisSpacing = 16,
    this.crossAxisSpacing = 16,
    this.childAspectRatio,
    this.baseAspectRatio = 1.32,
    this.padding = const EdgeInsets.all(16),
    this.shrinkWrap = false,
    this.physics,
    this.semanticChildCount,
  });

  final List<Widget> children;
  final double minItemWidth;
  final int maxColumns;
  final int minColumns;
  final double mainAxisSpacing;
  final double crossAxisSpacing;
  final double? childAspectRatio;
  final double baseAspectRatio;
  final EdgeInsetsGeometry padding;
  final bool shrinkWrap;
  final ScrollPhysics? physics;
  final int? semanticChildCount;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = padding.resolveHorizontal(context);
        final availableWidth = constraints.maxWidth - horizontalPadding;
        final columns = calculateColumns(
          availableWidth: availableWidth,
          minItemWidth: minItemWidth,
          maxColumns: maxColumns,
          minColumns: minColumns,
        );
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final aspectRatio = childAspectRatio ?? calculateAspectRatio(
          baseRatio: baseAspectRatio,
          textScale: textScale,
        );

        return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: shrinkWrap,
          physics: physics,
          padding: padding,
          mainAxisSpacing: mainAxisSpacing,
          crossAxisSpacing: crossAxisSpacing,
          childAspectRatio: aspectRatio,
          semanticChildCount: semanticChildCount ?? children.length,
          children: children,
        );
      },
    );
  }
}

/// A responsive list/grid that switches between [ListView] and [GridView]
/// based on the device class.
///
/// - Phone: Single column list
/// - Tablet: 2-column grid
/// - Desktop: 3+ column grid
class AdaptiveListView extends StatelessWidget {
  const AdaptiveListView({
    super.key,
    required this.children,
    this.itemBuilder,
    this.listPadding = const EdgeInsets.all(16),
    this.gridPadding = const EdgeInsets.all(16),
    this.gridMinItemWidth = 300,
    this.gridMaxColumns = 4,
    this.gridChildAspectRatio = 1.5,
    this.shrinkWrap = false,
    this.physics,
  });

  final List<Widget> children;
  final Widget Function(BuildContext, int)? itemBuilder;
  final EdgeInsetsGeometry listPadding;
  final EdgeInsetsGeometry gridPadding;
  final double gridMinItemWidth;
  final int gridMaxColumns;
  final double gridChildAspectRatio;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    final dc = context.deviceClass;

    if (dc == DeviceClass.phone) {
      return ListView.builder(
        shrinkWrap: shrinkWrap,
        physics: physics,
        padding: listPadding,
        itemCount: children.length,
        itemBuilder: itemBuilder ?? (context, index) => children[index],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = gridPadding.resolveHorizontal(context);
        final availableWidth = constraints.maxWidth - horizontalPadding;
        final columns = calculateColumns(
          availableWidth: availableWidth,
          minItemWidth: gridMinItemWidth,
          maxColumns: gridMaxColumns,
          minColumns: 2,
        );
        return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: shrinkWrap,
          physics: physics,
          padding: gridPadding,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: gridChildAspectRatio,
          children: children,
        );
      },
    );
  }
}

/// A responsive row/column that switches direction based on available width.
///
/// - Below [breakpoint]: Column (vertical stack)
/// - Above [breakpoint]: Row (horizontal)
class ResponsiveRowColumn extends StatelessWidget {
  const ResponsiveRowColumn({
    super.key,
    required this.children,
    this.breakpoint = Breakpoints.tablet,
    this.rowMainAxisAlignment = MainAxisAlignment.start,
    this.rowCrossAxisAlignment = CrossAxisAlignment.center,
    this.columnMainAxisAlignment = MainAxisAlignment.start,
    this.columnCrossAxisAlignment = CrossAxisAlignment.start,
    this.rowSpacing = 16,
    this.columnSpacing = 16,
  });

  final List<Widget> children;
  final double breakpoint;
  final MainAxisAlignment rowMainAxisAlignment;
  final CrossAxisAlignment rowCrossAxisAlignment;
  final MainAxisAlignment columnMainAxisAlignment;
  final CrossAxisAlignment columnCrossAxisAlignment;
  final double rowSpacing;
  final double columnSpacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= breakpoint) {
          return Row(
            mainAxisAlignment: rowMainAxisAlignment,
            crossAxisAlignment: rowCrossAxisAlignment,
            children: [
              for (int i = 0; i < children.length; i++) ...[
                if (i > 0) SizedBox(width: rowSpacing),
                Expanded(child: children[i]),
              ],
            ],
          );
        }
        return Column(
          mainAxisAlignment: columnMainAxisAlignment,
          crossAxisAlignment: columnCrossAxisAlignment,
          children: [
            for (int i = 0; i < children.length; i++) ...[
              if (i > 0) SizedBox(height: columnSpacing),
              children[i],
            ],
          ],
        );
      },
    );
  }
}

/// A responsive sidebar layout with a navigation rail on larger screens
/// and a bottom navigation bar on phones.
class ResponsiveScaffold extends StatelessWidget {
  const ResponsiveScaffold({
    super.key,
    required this.body,
    this.navigationRail,
    this.bottomNavigationBar,
    this.drawer,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.backgroundColor,
    this.resizeToAvoidBottomInset = true,
    this.breakpoint = Breakpoints.tablet,
  });

  final Widget body;
  final Widget? navigationRail;
  final Widget? bottomNavigationBar;
  final Widget? drawer;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Color? backgroundColor;
  final bool resizeToAvoidBottomInset;
  final double breakpoint;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= breakpoint;

        if (!isWide) {
          // Phone layout: bottom nav, optional drawer
          return Scaffold(
            body: body,
            bottomNavigationBar: bottomNavigationBar,
            drawer: drawer,
            floatingActionButton: floatingActionButton,
            floatingActionButtonLocation: floatingActionButtonLocation,
            backgroundColor: backgroundColor,
            resizeToAvoidBottomInset: resizeToAvoidBottomInset,
          );
        }

        // Tablet/Desktop layout: navigation rail + body
        return Scaffold(
          body: Row(
            children: [
              navigationRail ?? const SizedBox.shrink(),
              Expanded(child: body),
            ],
          ),
          floatingActionButton: floatingActionButton,
          floatingActionButtonLocation: floatingActionButtonLocation,
          backgroundColor: backgroundColor,
          resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        );
      },
    );
  }
}

/// A responsive card that adjusts its padding and elevation based on device class.
class ResponsiveCard extends StatelessWidget {
  const ResponsiveCard({
    super.key,
    required this.child,
    this.onTap,
    this.elevation,
    this.margin,
    this.color,
    this.borderRadius = 16,
    this.phonePadding = 16,
    this.tabletPadding = 20,
    this.desktopPadding = 24,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double? elevation;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final double borderRadius;
  final double phonePadding;
  final double tabletPadding;
  final double desktopPadding;

  @override
  Widget build(BuildContext context) {
    final dc = context.deviceClass;
    final padding = switch (dc) {
      DeviceClass.phone => phonePadding,
      DeviceClass.tablet => tabletPadding,
      _ => desktopPadding,
    };

    final card = Card(
      elevation: elevation,
      margin: margin,
      color: color,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(borderRadius)),
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: child,
      ),
    );

    if (onTap == null) return card;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(borderRadius),
      child: card,
    );
  }
}

/// A responsive app bar that adapts to different screen sizes.
///
/// On phone: Standard app bar with centered title
/// On tablet/desktop: Can show more actions, larger title, etc.
class ResponsiveAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ResponsiveAppBar({
    super.key,
    required this.title,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.flexibleSpace,
    this.bottom,
    this.elevation,
    this.scrolledUnderElevation,
    this.backgroundColor,
    this.foregroundColor,
    this.titleSpacing,
    this.toolbarHeight,
    this.phoneToolbarHeight = kToolbarHeight,
    this.tabletToolbarHeight = 72,
    this.desktopToolbarHeight = 80,
  });

  final Widget title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool automaticallyImplyLeading;
  final Widget? flexibleSpace;
  final PreferredSizeWidget? bottom;
  final double? elevation;
  final double? scrolledUnderElevation;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final double? titleSpacing;
  final double? toolbarHeight;
  final double phoneToolbarHeight;
  final double tabletToolbarHeight;
  final double desktopToolbarHeight;

  @override
  Size get preferredSize => Size.fromHeight(toolbarHeight ?? kToolbarHeight);

  double _getToolbarHeight(BuildContext context) {
    final dc = context.deviceClass;
    if (dc == DeviceClass.phone) return phoneToolbarHeight;
    if (dc == DeviceClass.tablet) return tabletToolbarHeight;
    return desktopToolbarHeight;
  }

  @override
  Widget build(BuildContext context) {
    final dc = context.deviceClass;
    final height = _getToolbarHeight(context);

    return AppBar(
      title: title,
      actions: actions,
      leading: leading,
      automaticallyImplyLeading: automaticallyImplyLeading,
      flexibleSpace: flexibleSpace,
      bottom: bottom,
      elevation: elevation,
      scrolledUnderElevation: scrolledUnderElevation,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      titleSpacing: titleSpacing ?? (dc == DeviceClass.phone ? 16 : 24),
      toolbarHeight: height,
    );
  }
}

/// Extension to get horizontal padding from EdgeInsetsGeometry.
extension EdgeInsetsGeometryExtension on EdgeInsetsGeometry {
  double get horizontal {
    // This extension cannot resolve without a BuildContext,
    // so we provide a helper method instead.
    throw UnsupportedError('Use resolveHorizontal(context) instead');
  }

  double resolveHorizontal(BuildContext context) {
    final resolved = resolve(Directionality.of(context));
    return resolved.left + resolved.right;
  }
}