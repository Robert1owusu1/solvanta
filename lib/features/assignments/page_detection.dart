// Locating the page inside a capture (doc §47).
//
// Pure Dart over plain bytes — no `dart:ui`, no image-processing dependency —
// so the heuristic that proposes a crop is unit-testable without a device or a
// real photo. See page_geometry.dart for the shared types and the crop itself,
// page_metrics.dart for judging the result.

import 'dart:math' as math;
import 'dart:typed_data';

import 'page_geometry.dart';

int _luma(int r, int g, int b) {
  // Rec. 709 luma, integer form. Rounded so a flat white field lands on 255
  // rather than 254.
  final v = (54 * r + 183 * g + 19 * b + 128) >> 8;
  return v < 0 ? 0 : (v > 255 ? 255 : v);
}

/// Greyscales [src] (RGBA8888) down to at most [maxDim] on its longer side.
///
/// Downsampling is what keeps every metric below cheap enough to run on the
/// UI thread of a mid-range phone: a 2400×3200 capture becomes ~192×256, and
/// the page geometry is unaffected because bounds come back normalised.
LumaImage toLuma(Uint8List src, int width, int height, {int maxDim = 192}) {
  final longest = math.max(width, height);
  final scale = longest / maxDim;

  if (scale <= 1) {
    final out = Uint8List(width * height);
    for (var i = 0, p = 0; i < out.length; i++, p += 4) {
      out[i] = _luma(src[p], src[p + 1], src[p + 2]);
    }
    return LumaImage(width, height, out);
  }

  final w = math.max(1, (width / scale).round());
  final h = math.max(1, (height / scale).round());
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final sy = math.min(height - 1, (y * scale).floor());
    for (var x = 0; x < w; x++) {
      final sx = math.min(width - 1, (x * scale).floor());
      final p = (sy * width + sx) * 4;
      out[y * w + x] = _luma(src[p], src[p + 1], src[p + 2]);
    }
  }
  return LumaImage(w, h, out);
}

/// Otsu's threshold: the split point that maximises between-class variance.
///
/// Used to separate the page (bright) from the desk or floor behind it
/// (darker) without hand-tuning a brightness constant that would break the
/// first time a teacher photographs work on a dark table.
int otsuThreshold(LumaImage img) {
  final hist = List<int>.filled(256, 0);
  for (final p in img.pixels) {
    hist[p]++;
  }
  final total = img.pixels.length;
  var sum = 0;
  for (var i = 0; i < 256; i++) {
    sum += i * hist[i];
  }

  var sumB = 0;
  var wB = 0;
  var best = 127;
  var bestVar = -1.0;
  for (var i = 0; i < 256; i++) {
    wB += hist[i];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += i * hist[i];
    final mB = sumB / wB;
    final mF = (sum - sumB) / wF;
    final v = wB.toDouble() * wF * (mB - mF) * (mB - mF);
    if (v > bestVar) {
      bestVar = v;
      best = i;
    }
  }
  return best;
}

/// Finds the page inside [img] by locating the bright region the sheet
/// occupies, returning NORMALISED bounds.
///
/// This is a heuristic, and it is meant to be one: it proposes a crop, the
/// teacher sees the rectangle over the photo and drags it if it is wrong. It
/// never silently decides the crop on its own.
PageBounds detectPageBounds(LumaImage img) {
  if (img.width < 4 || img.height < 4) return PageBounds.fullFrame();

  final threshold = otsuThreshold(img);

  // A row counts as "page" when a solid share of it is above threshold. The
  // sheet is a large contiguous bright block, so its rows and columns are
  // almost entirely bright while the background is not.
  const coverage = 0.45;

  final rowHits = Uint8List(img.height);
  for (var y = 0; y < img.height; y++) {
    var above = 0;
    final row = y * img.width;
    for (var x = 0; x < img.width; x++) {
      if (img.pixels[row + x] > threshold) above++;
    }
    if (above / img.width >= coverage) rowHits[y] = 1;
  }

  final colHits = Uint8List(img.width);
  for (var x = 0; x < img.width; x++) {
    var above = 0;
    for (var y = 0; y < img.height; y++) {
      if (img.pixels[y * img.width + x] > threshold) above++;
    }
    if (above / img.height >= coverage) colHits[x] = 1;
  }

  final rows = _longestRun(rowHits);
  final cols = _longestRun(colHits);

  if (rows == null || cols == null) return PageBounds.fullFrame();

  // Pad out by a pixel's worth of the frame: the anti-aliased sheet edge is
  // darker than the sheet itself and would otherwise be clipped.
  final padX = 1.0 / img.width;
  final padY = 1.0 / img.height;

  final bounds = PageBounds(
    left: cols.$1 / img.width - padX,
    top: rows.$1 / img.height - padY,
    right: (cols.$2 + 1) / img.width + padX,
    bottom: (rows.$2 + 1) / img.height + padY,
  ).clamped();

  return bounds.usable ? bounds : PageBounds.fullFrame();
}

/// The longest contiguous run of set entries as (start, end) inclusive, or
/// null when nothing is set.
(int, int)? _longestRun(Uint8List hits) {
  int? start;
  var bestStart = 0;
  var bestLen = 0;
  var curStart = 0;
  for (var i = 0; i <= hits.length; i++) {
    final on = i < hits.length && hits[i] == 1;
    if (on && start == null) {
      start = i;
      curStart = i;
    } else if (!on && start != null) {
      final len = i - start;
      if (len > bestLen) {
        bestLen = len;
        bestStart = curStart;
      }
      start = null;
    }
  }
  if (bestLen == 0) return null;
  return (bestStart, bestStart + bestLen - 1);
}
