import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Computed visual properties of a captured page, used to decide whether the
/// photo is good enough for answer extraction.
class ScanImageStats {
  final int width;
  final int height;
  final double luminance;
  final double contrast;

  const ScanImageStats({
    required this.width,
    required this.height,
    required this.luminance,
    required this.contrast,
  });

  bool get portrait => height >= width;
}

/// Reusable, testable quality rules (doc §47: page detection, rotation
/// correction, blur / lighting analysis — the retake trigger).
class ScanQualityCheck {
  static const double _lowLuminance = 0.28;
  static const double _flatContrast = 0.05;
  static const int _minShortSide = 720;

  static List<String> evaluate(ScanImageStats stats) {
    final warnings = <String>[];
    if (!stats.portrait) {
      warnings.add('Page looks sideways — rotate so the page is upright.');
    }
    if (stats.luminance < _lowLuminance) {
      warnings.add('Photo is too dark — answers may not read clearly.');
    }
    if (stats.contrast < _flatContrast) {
      warnings.add('Image looks blurred or flat — retake in good light.');
    }
    if (stats.width < _minShortSide &&
        stats.height < _minShortSide) {
      warnings.add('Image resolution is low — move closer to the page.');
    }
    return warnings;
  }

  static bool needsRetake(ScanImageStats stats) =>
      stats.luminance < _lowLuminance || stats.contrast < _flatContrast;
}

/// Decodes raw image bytes and samples pixels to estimate luminance and
/// contrast without any CV dependency. Runs in the Flutter isolate.
Future<ScanImageStats> measureImage(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final w = image.width;
  final h = image.height;

  final data =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  codec.dispose();

  if (data == null) {
    return ScanImageStats(width: w, height: h, luminance: 0.5, contrast: 0.2);
  }

  // Sample up to 40k evenly-spread pixels for a stable estimate.
  final stride = (w * h) ~/ 40000;
  final step = stride < 1 ? 1 : stride;
  var sum = 0.0;
  var sumSq = 0.0;
  var n = 0;
  for (var i = 0; i < data.lengthInBytes && n < 40000; i += step * 4) {
    final r = data.getUint8(i);
    final g = data.getUint8(i + 1);
    final b = data.getUint8(i + 2);
    final lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
    sum += lum;
    sumSq += lum * lum;
    n++;
  }
  if (n == 0) {
    return ScanImageStats(width: w, height: h, luminance: 0.5, contrast: 0.2);
  }
  final mean = sum / n;
  final variance = sumSq / n - mean * mean;
  return ScanImageStats(
    width: w,
    height: h,
    luminance: mean,
    contrast: variance < 0 ? 0 : math.sqrt(variance),
  );
}