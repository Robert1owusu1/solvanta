// Pixel geometry for assignment photo capture (doc §47): the shared container
// types, plus the crop and the rotation themselves.
//
// One of three siblings — page_detection.dart locates the page inside a
// capture, page_metrics.dart judges its quality. Everything here is pure Dart
// over plain bytes: no `dart:ui`, no image-processing dependency, so it is
// unit-testable without a device or a real photo.
//
// Deliberately NOT doing perspective straightening: that needs a homography
// solve plus resampling, which is far more code and far more to get subtly
// wrong than it is worth until real photo testing shows OCR accuracy actually
// suffering from skew. The alignment guide on the capture screen is meant to
// stop tilted captures at the source instead. Revisit only with evidence.

import 'dart:math' as math;
import 'dart:typed_data';

/// A downsampled greyscale view of a capture: row-major, one byte per pixel,
/// 0 (black) .. 255 (white).
class LumaImage {
  const LumaImage(this.width, this.height, this.pixels);

  final int width;
  final int height;
  final Uint8List pixels;

  int at(int x, int y) => pixels[y * width + x];
}

/// Raw RGBA pixels plus their dimensions.
class RgbaImage {
  const RgbaImage(this.width, this.height, this.bytes);

  final int width;
  final int height;
  final Uint8List bytes;
}

/// A crop window in NORMALISED coordinates (0.0 .. 1.0) relative to the
/// capture. Normalised so the same bounds survive a downscale and can be
/// mapped onto whatever resolution is displayed.
///
/// Four scalars, not four corner points: this is an axis-aligned rectangle,
/// and cannot represent a non-rectangular quadrilateral. See the crop screen
/// for how the corner handles drive it.
class PageBounds {
  const PageBounds({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  /// A bounds that is degenerate (inverted or thinner than [minFraction] of
  /// the frame on either axis) is not a usable page — callers should fall back
  /// to [PageBounds.fullFrame].
  bool get usable =>
      right > left &&
      bottom > top &&
      width >= minFraction &&
      height >= minFraction;

  /// Thinnest crop accepted, as a fraction of the frame. Anything smaller is a
  /// mis-detection, not a page.
  static const double minFraction = 0.1;

  /// Safe fallback: the whole frame, inset slightly so a detected border of
  /// desk/background does not end up baked into the crop.
  static PageBounds fullFrame({double inset = 0.04}) => PageBounds(
        left: inset,
        top: inset,
        right: 1 - inset,
        bottom: 1 - inset,
      );

  /// Keeps the window inside the frame and above [minFraction].
  PageBounds clamped() {
    final l = left.clamp(0.0, 1.0);
    final t = top.clamp(0.0, 1.0);
    final r = right.clamp(0.0, 1.0);
    final b = bottom.clamp(0.0, 1.0);
    final grown = PageBounds(
      left: l,
      top: t,
      right: math.max(r, math.min(1.0, l + minFraction)),
      bottom: math.max(b, math.min(1.0, t + minFraction)),
    );
    return grown;
  }

  @override
  bool operator ==(Object other) =>
      other is PageBounds &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() =>
      'PageBounds(${left.toStringAsFixed(3)}, ${top.toStringAsFixed(3)}, '
      '${right.toStringAsFixed(3)}, ${bottom.toStringAsFixed(3)})';
}

/// Cuts [bounds] out of [src] at full resolution.
///
/// Pure byte shuffling, so the crop the teacher approved on screen is exactly
/// the crop that gets uploaded — no second round trip through the codec. A
/// straight rectangular copy: no warp, no resampling, no interpolation.
RgbaImage cropRgba(Uint8List src, int srcW, int srcH, PageBounds bounds) {
  final b = bounds.clamped();
  final x0 = math.max(0, math.min(srcW - 1, (b.left * srcW).floor()));
  final y0 = math.max(0, math.min(srcH - 1, (b.top * srcH).floor()));
  final x1 = math.max(x0 + 1, math.min(srcW, (b.right * srcW).ceil()));
  final y1 = math.max(y0 + 1, math.min(srcH, (b.bottom * srcH).ceil()));

  final outW = x1 - x0;
  final outH = y1 - y0;
  final out = Uint8List(outW * outH * 4);
  final stride = outW * 4;
  for (var y = 0; y < outH; y++) {
    final srcStart = ((y0 + y) * srcW + x0) * 4;
    out.setRange(y * stride, y * stride + stride, src, srcStart);
  }
  return RgbaImage(outW, outH, out);
}

/// Rotates [img] by 90°.
///
/// Assignments are photographed portrait or landscape depending on how the
/// work was written, and a page stored sideways is useless to whoever reads it
/// next. Transposing the byte grid is exact — no resampling, no quality loss.
RgbaImage rotateRgba(RgbaImage img, {bool clockwise = true}) {
  final srcW = img.width;
  final srcH = img.height;
  final outW = srcH;
  final outH = srcW;
  final out = Uint8List(outW * outH * 4);
  final src = img.bytes;

  for (var y = 0; y < outH; y++) {
    for (var x = 0; x < outW; x++) {
      // Clockwise: dst(x, y) <- src(y, srcH - 1 - x).
      // Anti-clockwise: dst(x, y) <- src(srcW - 1 - y, x).
      final sx = clockwise ? y : srcW - 1 - y;
      final sy = clockwise ? srcH - 1 - x : x;
      final s = (sy * srcW + sx) * 4;
      final d = (y * outW + x) * 4;
      out[d] = src[s];
      out[d + 1] = src[s + 1];
      out[d + 2] = src[s + 2];
      out[d + 3] = src[s + 3];
    }
  }
  return RgbaImage(outW, outH, out);
}
