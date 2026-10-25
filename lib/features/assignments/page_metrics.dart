// Quality measurements for a captured page (doc §47).
//
// Pure Dart over plain bytes — no `dart:ui`, no image-processing dependency —
// so the numbers the quality gate acts on are unit-testable without a device
// or a real photo. See page_geometry.dart for the shared types and the crop,
// page_detection.dart for locating the page, and page_quality.dart for the
// verdict these feed into.

import 'dart:math' as math;

import 'page_geometry.dart';

/// Quality measurements taken over one region of a capture.
class PageMetrics {
  const PageMetrics({
    required this.luminance,
    required this.contrast,
    required this.sharpness,
    required this.darkFraction,
    required this.brightFraction,
  });

  /// Mean brightness, 0.0 .. 1.0.
  final double luminance;

  /// Standard deviation of brightness, 0.0 .. 1.0.
  final double contrast;

  /// Variance of the Laplacian on the 0..255 luma scale. Low means blurred;
  /// high means crisp text edges.
  final double sharpness;

  /// Fraction of the region in deep shadow (< 24/255).
  final double darkFraction;

  /// Fraction of the region blown out by glare (> 232/255).
  final double brightFraction;
}

/// Measures the quality of one region of [img].
///
/// [bounds] selects the region — callers should pass the CROPPED page, not the
/// whole frame. Measuring the full frame would judge the desk around the sheet
/// as if it were part of the work, so a photo of a small page on a large dark
/// table would be rejected as "too dark" even though the page itself is fine.
PageMetrics measureRegion(LumaImage img, PageBounds bounds) {
  final b = bounds.clamped();
  final x0 = math.max(0, math.min(img.width - 1, (b.left * img.width).floor()));
  final y0 = math.max(0, math.min(img.height - 1, (b.top * img.height).floor()));
  final x1 = math.max(x0 + 1, math.min(img.width, (b.right * img.width).ceil()));
  final y1 = math.max(y0 + 1, math.min(img.height, (b.bottom * img.height).ceil()));

  var sum = 0.0;
  var sumSq = 0.0;
  var dark = 0;
  var bright = 0;
  var n = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final v = img.at(x, y);
      sum += v;
      sumSq += v * v;
      if (v < 24) dark++;
      if (v > 232) bright++;
      n++;
    }
  }
  if (n == 0) {
    return const PageMetrics(
      luminance: 0.5,
      contrast: 0,
      sharpness: 0,
      darkFraction: 0,
      brightFraction: 0,
    );
  }

  final mean = sum / n;
  final variance = (sumSq / n) - (mean * mean);

  return PageMetrics(
    luminance: mean / 255.0,
    contrast: (variance < 0 ? 0 : math.sqrt(variance)) / 255.0,
    sharpness: _laplacianVariance(img, x0, y0, x1, y1),
    darkFraction: dark / n,
    brightFraction: bright / n,
  );
}

/// Variance of the 4-neighbour Laplacian over the region.
///
/// A blurred image has no sharp intensity transitions, so its second
/// derivative is close to flat and this lands near zero. Crisp printed or
/// handwritten text has many, so it lands high. It is a proxy, not a proof —
/// but a photo blurry enough to score badly here is genuinely hard to read
/// back, which is the only standard this gate needs to meet.
double _laplacianVariance(LumaImage img, int x0, int y0, int x1, int y1) {
  // Need a one-pixel border of neighbours.
  final sx0 = math.max(1, x0);
  final sy0 = math.max(1, y0);
  final sx1 = math.min(img.width - 1, x1);
  final sy1 = math.min(img.height - 1, y1);
  if (sx1 - sx0 < 2 || sy1 - sy0 < 2) return 0;

  var sum = 0.0;
  var sumSq = 0.0;
  var n = 0;
  for (var y = sy0; y < sy1; y++) {
    for (var x = sx0; x < sx1; x++) {
      final c = img.at(x, y).toDouble();
      final lap = img.at(x - 1, y) +
          img.at(x + 1, y) +
          img.at(x, y - 1) +
          img.at(x, y + 1) -
          4 * c;
      sum += lap;
      sumSq += lap * lap;
      n++;
    }
  }
  if (n == 0) return 0;
  final mean = sum / n;
  final variance = (sumSq / n) - (mean * mean);
  return variance < 0 ? 0 : variance;
}
