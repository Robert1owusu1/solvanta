import 'dart:typed_data';
import 'dart:ui' as ui;

import 'page_geometry.dart';

/// Decode/encode helpers that bridge raw RGBA buffers to Flutter's image
/// types.
///
/// Kept apart from [page_geometry] on purpose: that file is pure Dart and
/// unit-testable with no Flutter binding, while everything here needs
/// `dart:ui`, which only initialises on a device or in a real test binding.
///
/// No image-processing package is involved — `dart:ui` already decodes the
/// JPEG that image_picker hands back, and can re-encode a PNG from raw pixels.
/// Adding a dependency for this would be paying a build cost for nothing.

/// Decodes encoded image bytes to full-resolution RGBA.
///
/// Returns null when the bytes are not a decodable image. Callers treat that
/// as "the photo is unusable" rather than crashing — a truncated or partial
/// file is a normal thing to receive from a picker.
Future<RgbaImage?> decodeRgba(Uint8List bytes) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    final image = frame.image;

    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();

    if (data == null) return null;
    return RgbaImage(
      image.width,
      image.height,
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } catch (_) {
    // Anything the codec throws — truncated file, unsupported format, a
    // buffer that was disposed underneath us — means the same thing here.
    return null;
  }
}

/// Encodes raw RGBA back to PNG bytes for upload and storage.
///
/// PNG rather than JPEG: it is lossless, so a page that was cropped and
/// rotated does not lose a second round of quality to compression on top of
/// the camera's own. Pages are text, which PNG handles well, and the capture
/// pipeline already caps the resolution.
Future<Uint8List?> encodePng(RgbaImage img) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(img.bytes);
    // ImageDescriptor.raw is synchronous in this Flutter version.
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: img.width,
      height: img.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    final image = frame.image;

    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();

    if (data == null) return null;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (_) {
    return null;
  }
}

/// Decodes to a [ui.Image] for display only.
///
/// Used by the crop screen to show the uncropped photo. It is disposed by the
/// caller once the widget that holds it is done.
Future<ui.Image?> decodeForDisplay(Uint8List bytes) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  } catch (_) {
    return null;
  }
}
