library solvanta_responsive_breakpoints;

/// Responsive breakpoints for SOLVANTA web/desktop.
///
/// Based on Material Design 3 breakpoints with adjustments for our module grids.
/// These are used via [ResponsiveBuilder] and [LayoutBuilder] throughout the app.
import 'package:flutter/material.dart';

class Breakpoints {
  /// Phone portrait: < 600dp
  static const double phone = 600;

  /// Phone landscape / small tablet: 600dp - 840dp
  static const double smallTablet = 840;

  /// Tablet portrait: 840dp - 1024dp
  static const double tablet = 1024;

  /// Tablet landscape / small desktop: 1024dp - 1280dp
  static const double largeTablet = 1280;

  /// Desktop: >= 1280dp
  static const double desktop = 1280;

  /// Large desktop: >= 1600dp
  static const double largeDesktop = 1600;
}

/// Enum representing the current device class for semantic layout decisions.
enum DeviceClass {
  /// Phone in portrait (< 600dp)
  phone,

  /// Phone landscape or small tablet (600-840dp)
  smallTablet,

  /// Tablet portrait (840-1024dp)
  tablet,

  /// Tablet landscape or small desktop (1024-1280dp)
  largeTablet,

  /// Desktop (1280-1600dp)
  desktop,

  /// Large desktop (>= 1600dp)
  largeDesktop,
}

/// Extension on [BuildContext] for easy breakpoint queries.
extension ResponsiveContext on BuildContext {
  /// Current width in logical pixels.
  double get width => MediaQuery.sizeOf(this).width;

  /// Current height in logical pixels.
  double get height => MediaQuery.sizeOf(this).height;

  /// Whether the current width is at least [breakpoint].
  bool isAtLeast(double breakpoint) => width >= breakpoint;

  /// Whether the current width is less than [breakpoint].
  bool isLessThan(double breakpoint) => width < breakpoint;

  /// Current device class based on width.
  DeviceClass get deviceClass {
    final w = width;
    if (w < Breakpoints.phone) return DeviceClass.phone;
    if (w < Breakpoints.smallTablet) return DeviceClass.smallTablet;
    if (w < Breakpoints.tablet) return DeviceClass.tablet;
    if (w < Breakpoints.largeTablet) return DeviceClass.largeTablet;
    if (w < Breakpoints.desktop) return DeviceClass.desktop;
    return DeviceClass.largeDesktop;
  }

  /// Convenience getters for common breakpoints.
  bool get isPhone => deviceClass == DeviceClass.phone;
  bool get isTablet => deviceClass == DeviceClass.tablet;
  bool get isDesktop => deviceClass == DeviceClass.desktop;
  bool get isLargeDesktop => deviceClass == DeviceClass.largeDesktop;
  bool get isMobile => isPhone || isTablet;
  bool get isAtLeastTablet => isAtLeast(Breakpoints.tablet);
  bool get isAtLeastDesktop => isAtLeast(Breakpoints.desktop);
  bool get isAtLeastSmallTablet => isAtLeast(Breakpoints.smallTablet);
}

/// Calculates the number of columns for a grid based on available width and minimum item width.
///
/// [availableWidth] - The total width available for the grid
/// [minItemWidth] - Minimum width per item (default 220dp)
/// [maxColumns] - Maximum number of columns (default 6)
/// [minColumns] - Minimum number of columns (default 2)
int calculateColumns({
  required double availableWidth,
  double minItemWidth = 220,
  int maxColumns = 6,
  int minColumns = 2,
}) {
  final cols = (availableWidth / minItemWidth).floor();
  return cols.clamp(minColumns, maxColumns);
}

/// Calculates the child aspect ratio for a grid based on text scale.
///
/// As text scales up, cards need to be taller to prevent label clipping.
double calculateAspectRatio({
  required double baseRatio,
  required double textScale,
  double minRatio = 0.6,
  double maxRatio = 1.32,
}) {
  // Inverse relationship: larger text -> taller cards -> smaller aspect ratio
  final adjusted = baseRatio / textScale.clamp(1.0, 2.2);
  return adjusted.clamp(minRatio, maxRatio);
}

/// Returns responsive padding based on device class.
EdgeInsets responsivePadding(BuildContext context, {
  double phoneHorizontal = 16,
  double phoneVertical = 16,
  double tabletHorizontal = 24,
  double tabletVertical = 24,
  double desktopHorizontal = 32,
  double desktopVertical = 32,
}) {
  final dc = context.deviceClass;
  if (dc == DeviceClass.phone) {
    return EdgeInsets.symmetric(horizontal: phoneHorizontal, vertical: phoneVertical);
  } else if (dc == DeviceClass.tablet) {
    return EdgeInsets.symmetric(horizontal: tabletHorizontal, vertical: tabletVertical);
  } else {
    return EdgeInsets.symmetric(horizontal: desktopHorizontal, vertical: desktopVertical);
  }
}

/// Returns responsive horizontal padding only.
double responsiveHorizontalPadding(BuildContext context, {
  double phone = 16,
  double tablet = 24,
  double desktop = 32,
}) {
  final dc = context.deviceClass;
  if (dc == DeviceClass.phone) return phone;
  if (dc == DeviceClass.tablet) return tablet;
  return desktop;
}

/// Returns responsive max width for content containers.
double responsiveMaxWidth(BuildContext context, {
  double phone = double.infinity,
  double tablet = 720,
  double desktop = 1024,
  double largeDesktop = 1280,
}) {
  final dc = context.deviceClass;
  if (dc == DeviceClass.phone) return phone;
  if (dc == DeviceClass.tablet) return tablet;
  if (dc == DeviceClass.desktop) return desktop;
  return largeDesktop;
}