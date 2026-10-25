import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import 'page_codec.dart';
import 'page_detection.dart';
import 'page_geometry.dart';
import 'page_metrics.dart';
import 'page_quality.dart';

/// Pops the cropped, straightened-and-rotated photo bytes, or null when the
/// teacher backs out.
typedef PageCropResult = ({Uint8List bytes, List<String> warnings});

/// Crop, rotate and quality-check one page before it joins a submission.
///
/// The order here is deliberate and is the point of the screen:
///
///   1. the page is DETECTED (a bright-region heuristic proposes a rectangle),
///   2. the teacher adjusts it and can ROTATE,
///   3. quality is judged on the CROPPED region, not the whole frame,
///   4. only then do the bytes leave this screen.
///
/// Step 3 is why the crop happens before the check rather than after: judging
/// the full frame would score the desk around the sheet as if it were part of
/// the work, so a small page on a large dark table would be rejected as "too
/// dark" even though the page itself is perfectly legible.
class AssignmentCropScreen extends StatefulWidget {
  const AssignmentCropScreen({super.key, required this.bytes});

  /// The full-resolution photo as picked.
  final Uint8List bytes;

  @override
  State<AssignmentCropScreen> createState() => _AssignmentCropScreenState();
}

class _AssignmentCropScreenState extends State<AssignmentCropScreen> {
  RgbaImage? _source;
  LumaImage? _luma;
  ui.Image? _preview;
  String? _error;

  /// The crop window, normalised against the source image.
  PageBounds _bounds = PageBounds.fullFrame();

  bool _working = true;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void dispose() {
    _preview?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    final rgba = await decodeRgba(widget.bytes);
    if (rgba == null) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = 'Could not read this photo. Please take another one.';
      });
      return;
    }
    final preview = await decodeForDisplay(widget.bytes);
    final luma = toLuma(rgba.bytes, rgba.width, rgba.height);
    if (!mounted) {
      preview?.dispose();
      return;
    }
    setState(() {
      _source = rgba;
      _luma = luma;
      _preview = preview;
      _working = false;
      // Start from the detected page so the first thing the teacher sees is a
      // rectangle roughly on the sheet, ready to nudge — not the full frame
      // they would then have to drag in from every edge.
      _bounds = detectPageBounds(luma);
    });
  }

  /// Quality of the CURRENT crop, recomputed whenever the bounds move.
  PageQualityVerdict get _verdict {
    final luma = _luma;
    if (luma == null) {
      return const PageQualityVerdict(issues: []);
    }
    return const PageQualityCheck().evaluate(measureRegion(luma, _bounds));
  }

  void _rotate() {
    final src = _source;
    final luma = _luma;
    if (src == null || luma == null) return;
    final rotated = rotateRgba(src);
    setState(() {
      _source = rotated;
      _luma = toLuma(rotated.bytes, rotated.width, rotated.height);
      // The crop window is normalised, so it survives the rotation as a
      // starting point; the teacher adjusts from there.
      _bounds = PageBounds.fullFrame();
    });
    _preview?.dispose();
    _preview = null;
  }

  Future<void> _confirm() async {
    final src = _source;
    if (src == null) return;
    setState(() => _working = true);

    final cropped = cropRgba(src.bytes, src.width, src.height, _bounds);
    final png = await encodePng(cropped);
    if (!mounted) return;
    if (png == null) {
      setState(() => _working = false);
      svSnack(context, 'Could not prepare that page. Please try again.',
          error: true);
      return;
    }
    setState(() => _working = false);
    // A record literal rather than the typedef name: the alias reads better in
    // the signature, but Dart does not let it be invoked as a constructor.
    Navigator.of(context).pop((
      bytes: png,
      warnings: _verdict.recordedWarnings,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Adjust page')),
      body: _working
          ? const SvLoading(message: 'Preparing the page…')
          : _error != null
              ? SvErrorState(message: _error!, onRetry: _decode)
              : _buildEditor(),
    );
  }

  Widget _buildEditor() {
    final verdict = _verdict;
    return Column(
      children: [
        Expanded(child: _buildCanvas(verdict)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Text(
            'Drag corners to adjust the crop area',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: AppColors.muted),
          ),
        ),
        _buildControls(verdict),
      ],
    );
  }

  Widget _buildCanvas(PageQualityVerdict verdict) {
    final preview = _preview;
    if (preview == null) {
      return const SvEmptyState(
        icon: Icons.broken_image_outlined,
        title: 'Photo unavailable',
        message: 'Please take another photo.',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // Fit the image inside the available space, preserving aspect, so the
        // crop rectangle the teacher drags maps exactly onto image pixels.
        final ar = preview.width / preview.height;
        var w = constraints.maxWidth;
        var h = w / ar;
        if (h > constraints.maxHeight) {
          h = constraints.maxHeight;
          w = h * ar;
        }
        return Center(
          child: GestureDetector(
            // Tap-drag anywhere on the photo to move the whole window; the
            // corner handles below do the fine work.
            onPanUpdate: (d) => _nudge(d.delta, w, h),
            child: SizedBox(
              width: w,
              height: h,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  RawImage(image: preview, width: w, height: h, fit: BoxFit.fill),
                  // Dimmed surround, so the kept region reads clearly.
                  CustomPaint(
                    size: Size(w, h),
                    painter: _CropMaskPainter(_bounds, verdict.hasBlocking),
                  ),
                  // Alignment guide: the page-shaped frame with corner ticks
                  // and a centre cross, drawn over the photo. UI only.
                  CustomPaint(
                    size: Size(w, h),
                    painter: _AlignmentGuidePainter(),
                  ),
                  for (final handle in _handles(w, h)) handle,
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The four corner handles, sized generously — this is being dragged with a
  /// thumb on a phone, often one-handed while holding a paper with the other.
  List<Widget> _handles(double w, double h) {
    const size = 34.0;
    Widget at(Alignment align, void Function(Offset) apply, String label) {
      return Align(
        alignment: align,
        child: GestureDetector(
          onPanUpdate: (d) => apply(d.delta),
          child: Tooltip(
            message: label,
            child: Container(
              width: size,
              height: size,
              margin: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: .85),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: const Icon(Icons.crop_free, size: 16, color: Colors.white),
            ),
          ),
        ),
      );
    }

    return [
      at(Alignment.topLeft, (d) => _moveCorner(d, w, h, 0), 'Top left'),
      at(Alignment.topRight, (d) => _moveCorner(d, w, h, 1), 'Top right'),
      at(Alignment.bottomRight, (d) => _moveCorner(d, w, h, 2), 'Bottom right'),
      at(Alignment.bottomLeft, (d) => _moveCorner(d, w, h, 3), 'Bottom left'),
    ];
  }

  /// Drags corner [index] by [delta] in widget space, back into normalised
  /// image space. Each corner is clamped against its opposite so the window
  /// can never invert or collapse to nothing.
  void _moveCorner(Offset delta, double w, double h, int index) {
    final dx = delta.dx / w;
    final dy = delta.dy / h;
    var l = _bounds.left;
    var t = _bounds.top;
    var r = _bounds.right;
    var b = _bounds.bottom;

    switch (index) {
      case 0:
        l = (l + dx).clamp(0.0, r - PageBounds.minFraction);
        t = (t + dy).clamp(0.0, b - PageBounds.minFraction);
      case 1:
        r = (r + dx).clamp(l + PageBounds.minFraction, 1.0);
        t = (t + dy).clamp(0.0, b - PageBounds.minFraction);
      case 2:
        r = (r + dx).clamp(l + PageBounds.minFraction, 1.0);
        b = (b + dy).clamp(t + PageBounds.minFraction, 1.0);
      case 3:
        l = (l + dx).clamp(0.0, r - PageBounds.minFraction);
        b = (b + dy).clamp(t + PageBounds.minFraction, 1.0);
    }
    setState(() => _bounds = PageBounds(left: l, top: t, right: r, bottom: b));
  }

  /// Moves the whole window, keeping its size.
  void _nudge(Offset delta, double w, double h) {
    final dx = delta.dx / w;
    final dy = delta.dy / h;
    var l = (_bounds.left + dx).clamp(0.0, 1.0 - _bounds.width);
    var t = (_bounds.top + dy).clamp(0.0, 1.0 - _bounds.height);
    setState(() => _bounds = PageBounds(
          left: l,
          top: t,
          right: l + _bounds.width,
          bottom: t + _bounds.height,
        ));
  }

  Widget _buildControls(PageQualityVerdict verdict) {
    final blocking = verdict.blockingMessages;
    final advisory = verdict.advisoryMessages;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (blocking.isNotEmpty)
              _qualityCard(
                icon: Icons.block,
                color: AppColors.danger,
                title: 'This page cannot be uploaded as it is',
                messages: blocking,
              )
            else if (advisory.isNotEmpty)
              _qualityCard(
                icon: Icons.warning_amber_rounded,
                color: AppColors.warning,
                title: 'Usable, but worth reshooting',
                messages: advisory,
              )
            else
              _qualityCard(
                icon: Icons.check_circle,
                color: AppColors.success,
                title: 'Page looks good',
                messages: const [],
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _rotate,
                  icon: const Icon(Icons.rotate_90_degrees_cw),
                  label: const Text('Rotate'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    // A blocking issue does not make the button vanish — it
                    // makes it explicit. A threshold cannot see a genuinely
                    // faded pencil page that a human can still read, so the
                    // teacher keeps the last word, but has to say so out loud.
                    onPressed: _confirm,
                    style: blocking.isNotEmpty
                        ? FilledButton.styleFrom(
                            backgroundColor: AppColors.danger)
                        : null,
                    icon: Icon(blocking.isNotEmpty
                        ? Icons.warning_amber_rounded
                        : Icons.check),
                    label: Text(blocking.isNotEmpty
                        ? 'Upload anyway'
                        : 'Use this page'),
                  ),
                ),
              ],
            ),
            if (blocking.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Retaking is usually the right call — the page as captured '
                  'may not be readable later.',
                  style: TextStyle(fontSize: 11, color: AppColors.muted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _qualityCard({
    required IconData icon,
    required Color color,
    required String title,
    required List<String> messages,
  }) {
    return Card(
      color: color.withValues(alpha: .07),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      style: TextStyle(
                          fontWeight: FontWeight.w700, color: color)),
                ),
              ],
            ),
            for (final m in messages)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 28),
                child: Text(m, style: const TextStyle(fontSize: 12.5)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Dims everything outside the crop window so the kept region reads clearly.
class _CropMaskPainter extends CustomPainter {
  const _CropMaskPainter(this.bounds, this.blocking);

  final PageBounds bounds;
  final bool blocking;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      bounds.left * size.width,
      bounds.top * size.height,
      bounds.right * size.width,
      bounds.bottom * size.height,
    );
    final outside = Path()
      ..addRect(Offset.zero & size)
      ..addRect(rect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      outside,
      Paint()..color = Colors.black.withValues(alpha: .45),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = blocking ? AppColors.danger : AppTheme.brand,
    );
  }

  @override
  bool shouldRepaint(_CropMaskPainter old) =>
      old.bounds != bounds || old.blocking != blocking;
}

/// The alignment guide: a page-shaped frame with corner ticks and a centre
/// cross.
///
/// UI only, and deliberately so — it draws over the photo the teacher is
/// about to keep, as a visual reference for how a page should sit. It cannot
/// overlay the live camera, because image_picker hands off to the OS camera
/// app, which is not ours to draw on. Closing that gap needs the `camera`
/// plugin for an in-app preview, which is a new dependency and therefore not
/// this phase.
class _AlignmentGuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Inset frame, leaving a margin for the page edge.
    final rect = Rect.fromLTWH(
      size.width * .06,
      size.height * .06,
      size.width * .88,
      size.height * .88,
    );
    final guide = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white.withValues(alpha: .55);

    // Dashed rectangle.
    const dash = 9.0;
    const gap = 7.0;
    for (final side in _sides(rect)) {
      final len = (side.end - side.start).distance;
      final dir = (side.end - side.start) / len;
      var travelled = 0.0;
      while (travelled < len) {
        final from = side.start + dir * travelled;
        final to = side.start + dir * (travelled + dash).clamp(0.0, len);
        canvas.drawLine(from, to, guide);
        travelled += dash + gap;
      }
    }

    // Corner ticks, heavier, to mark where the page corners should land.
    final tick = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: .9);
    const t = 26.0;
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(t, 0), tick);
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(0, t), tick);
    canvas.drawLine(rect.topRight, rect.topRight - const Offset(t, 0), tick);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(0, t), tick);
    canvas.drawLine(
        rect.bottomLeft, rect.bottomLeft + const Offset(t, 0), tick);
    canvas.drawLine(
        rect.bottomLeft, rect.bottomLeft - const Offset(0, t), tick);
    canvas.drawLine(
        rect.bottomRight, rect.bottomRight - const Offset(t, 0), tick);
    canvas.drawLine(
        rect.bottomRight, rect.bottomRight - const Offset(0, t), tick);

    // Centre cross, to line the page up on.
    final c = rect.center;
    final cross = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white.withValues(alpha: .7);
    canvas.drawLine(c - const Offset(16, 0), c + const Offset(16, 0), cross);
    canvas.drawLine(c - const Offset(0, 16), c + const Offset(0, 16), cross);
  }

  List<({Offset start, Offset end})> _sides(Rect r) => [
        (start: r.topLeft, end: r.topRight),
        (start: r.topRight, end: r.bottomRight),
        (start: r.bottomRight, end: r.bottomLeft),
        (start: r.bottomLeft, end: r.topLeft),
      ];

  @override
  bool shouldRepaint(_AlignmentGuidePainter old) => false;
}
