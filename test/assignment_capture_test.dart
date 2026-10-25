import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:solvanta/core/models/assignment_submission.dart';
import 'package:solvanta/features/assignments/page_detection.dart';
import 'package:solvanta/features/assignments/page_geometry.dart';
import 'package:solvanta/features/assignments/page_metrics.dart';
import 'package:solvanta/features/assignments/page_quality.dart';

// =============================================================================
// Assignment page capture — Phase 3 guards
//
// Everything under test here is pure Dart, so these run with no device, no
// camera and no real photo. The images are synthesised byte buffers, which is
// enough to pin down the geometry and the quality gate.
// =============================================================================

/// Builds an RGBA buffer of [w]×[h] filled with a flat [shade], with an
/// optional bright "page" rectangle in the middle.
///
/// The rectangle is what page detection has to find: bright paper on a darker
/// desk is exactly the contrast the heuristic keys off.
Uint8List frame({
  required int w,
  required int h,
  int shade = 60,
  int? pageShade,
  double pageLeft = 0.15,
  double pageTop = 0.15,
  double pageRight = 0.85,
  double pageBottom = 0.85,
}) {
  final out = Uint8List(w * h * 4);
  final x0 = (pageLeft * w).round();
  final y0 = (pageTop * h).round();
  final x1 = (pageRight * w).round();
  final y1 = (pageBottom * h).round();
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final inside = pageShade != null &&
          x >= x0 &&
          x < x1 &&
          y >= y0 &&
          y < y1;
      final v = inside ? pageShade : shade;
      final i = (y * w + x) * 4;
      out[i] = v;
      out[i + 1] = v;
      out[i + 2] = v;
      out[i + 3] = 255;
    }
  }
  return out;
}

/// A flat, evenly-lit buffer: no edges, so nothing is blurred by definition.
Uint8List flat(int w, int h, int shade) => frame(w: w, h: h, shade: shade);

/// A buffer that mimics printed text: thin dark strokes on mostly-light paper.
///
/// The geometry matters as much as the values. Ink on a real page covers a
/// small share of the area — a 50/50 checkerboard would put half the pixels
/// below the shadow threshold and get rejected as obscured, which is a
/// different test entirely. Thin strokes keep the high-frequency edges that
/// the sharpness metric keys off while leaving the coverage realistic.
Uint8List sharpText(int w, int h) {
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = x % 4 == 0 ? 30 : 215;
      final i = (y * w + x) * 4;
      out[i] = v;
      out[i + 1] = v;
      out[i + 2] = v;
      out[i + 3] = 255;
    }
  }
  return out;
}

void main() {
  group('page detection', () {
    test('finds a bright page on a darker background', () {
      final luma = toLuma(
          frame(w: 200, h: 200, shade: 40, pageShade: 230,
              pageLeft: 0.2, pageTop: 0.25, pageRight: 0.8, pageBottom: 0.75),
          200, 200);
      final b = detectPageBounds(luma);

      expect(b.usable, isTrue);
      // Generous tolerance: this is a proposal the teacher adjusts, not a
      // measurement. What matters is that it lands on the page, not the desk.
      expect(b.left, inInclusiveRange(0.12, 0.28));
      expect(b.top, inInclusiveRange(0.17, 0.33));
      expect(b.right, inInclusiveRange(0.72, 0.88));
      expect(b.bottom, inInclusiveRange(0.67, 0.83));
    });

    test('falls back to the full frame when there is no page to find', () {
      // A flat frame: no bright region at all, so there is nothing to detect
      // and the teacher gets the whole photo to work with.
      final luma = toLuma(flat(120, 120, 90), 120, 120);
      expect(detectPageBounds(luma), PageBounds.fullFrame());
    });

    test('falls back to the full frame on a degenerate image', () {
      expect(detectPageBounds(toLuma(Uint8List(0), 0, 0)),
          PageBounds.fullFrame());
      expect(
          detectPageBounds(toLuma(flat(2, 2, 100), 2, 2)), PageBounds.fullFrame());
    });

    test('bounds are normalised, so resolution does not change them', () {
      final small = detectPageBounds(toLuma(
          frame(w: 100, h: 100, shade: 40, pageShade: 230), 100, 100));
      final large = detectPageBounds(toLuma(
          frame(w: 800, h: 800, shade: 40, pageShade: 230), 800, 800));
      expect(small.left, closeTo(large.left, 0.05));
      expect(small.right, closeTo(large.right, 0.05));
      expect(small.top, closeTo(large.top, 0.05));
      expect(small.bottom, closeTo(large.bottom, 0.05));
    });
  });

  group('crop', () {
    test('cuts exactly the requested window, at full resolution', () {
      // An 8-wide buffer with each column a distinct value, so the crop can be
      // read straight back off the bytes.
      final src = Uint8List(8 * 4 * 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 8; x++) {
          final i = (y * 8 + x) * 4;
          src[i] = x * 30; // column identity
          src[i + 3] = 255;
        }
      }
      final cropped = cropRgba(src, 8, 4,
          const PageBounds(left: 0.25, top: 0, right: 0.75, bottom: 1));

      expect(cropped.width, 4);
      expect(cropped.height, 4);
      // Column 2 was the first inside the window (0.25 * 8 = 2).
      expect(cropped.bytes[0], 2 * 30);
      expect(cropped.bytes[4], 3 * 30);
      expect(cropped.bytes[8], 4 * 30);
      expect(cropped.bytes[12], 5 * 30);
      // RGBA survives: the alpha channel is carried through.
      expect(cropped.bytes[3], 255);
    });

    test('never produces a zero-sized crop', () {
      final src = frame(w: 40, h: 40, shade: 100);
      // A window thinner than the minimum gets grown rather than collapsing.
      final cropped = cropRgba(src, 40, 40,
          const PageBounds(left: 0.5, top: 0.5, right: 0.5, bottom: 0.5));
      expect(cropped.width, greaterThan(0));
      expect(cropped.height, greaterThan(0));
      expect(cropped.bytes.length, cropped.width * cropped.height * 4);
    });
  });

  group('rotation', () {
    test('90° clockwise transposes and flips correctly', () {
      // 2×1: pixel A then pixel B. After CW rotation the result is 1×2 with
      // A on top and B below.
      final src = Uint8List(2 * 1 * 4);
      src[0] = 10; // A
      src[4] = 20; // B
      final out = rotateRgba(RgbaImage(2, 1, src));

      expect(out.width, 1);
      expect(out.height, 2);
      expect(out.bytes[0], 10, reason: 'A should be at the top');
      expect(out.bytes[4], 20, reason: 'B should be at the bottom');
    });

    test('four rotations return the original image', () {
      final src = frame(w: 6, h: 4, shade: 70);
      var img = RgbaImage(6, 4, src);
      for (var i = 0; i < 4; i++) {
        img = rotateRgba(img);
      }
      expect(img.width, 6);
      expect(img.height, 4);
      expect(img.bytes, src);
    });

    test('anti-clockwise is the inverse of clockwise', () {
      final src = frame(w: 5, h: 3, shade: 120);
      final back =
          rotateRgba(rotateRgba(RgbaImage(5, 3, src), clockwise: false),
              clockwise: true);
      expect(back.width, 5);
      expect(back.height, 3);
      expect(back.bytes, src);
    });

    test('rotation preserves every pixel value', () {
      final src = sharpText(7, 5);
      final out = rotateRgba(RgbaImage(7, 5, src));
      final srcValues = <int>{for (var i = 0; i < src.length; i += 4) src[i]};
      final outValues = <int>{for (var i = 0; i < out.bytes.length; i += 4) out.bytes[i]};
      expect(outValues, srcValues);
    });
  });

  group('quality gate', () {
    PageMetrics metrics({
      double luminance = 0.65,
      double contrast = 0.18,
      double sharpness = 400,
      double darkFraction = 0.0,
      double brightFraction = 0.0,
    }) =>
        PageMetrics(
          luminance: luminance,
          contrast: contrast,
          sharpness: sharpness,
          darkFraction: darkFraction,
          brightFraction: brightFraction,
        );

    const gate = PageQualityCheck();

    test('a well-lit, sharp page is accepted with no issues', () {
      final v = gate.evaluate(metrics());
      expect(v.clean, isTrue);
      expect(v.hasBlocking, isFalse);
      expect(v.hasAdvisory, isFalse);
      expect(v.recordedWarnings, isEmpty);
    });

    test('a blurred page is BLOCKED, not merely flagged', () {
      final v = gate.evaluate(metrics(sharpness: 3));
      expect(v.hasBlocking, isTrue);
      expect(v.blockingMessages, anyElement(contains('blurred')));
    });

    test('a too-dark page is BLOCKED', () {
      final v = gate.evaluate(metrics(luminance: 0.08));
      expect(v.hasBlocking, isTrue);
      expect(v.blockingMessages, anyElement(contains('dark')));
    });

    test('glare is BLOCKED — a blown-out page loses real work', () {
      final v = gate.evaluate(metrics(brightFraction: 0.5));
      expect(v.hasBlocking, isTrue);
      expect(v.blockingMessages, anyElement(contains('Glare')));
    });

    test('a shadow is BLOCKED', () {
      final v = gate.evaluate(metrics(darkFraction: 0.6));
      expect(v.hasBlocking, isTrue);
      expect(v.blockingMessages, anyElement(contains('shadow')));
    });

    test('low contrast is advisory — usable, just not ideal', () {
      final v = gate.evaluate(metrics(contrast: 0.01));
      expect(v.hasBlocking, isFalse);
      expect(v.hasAdvisory, isTrue);
      expect(v.advisoryMessages, anyElement(contains('Low contrast')));
    });

    test('a washed-out page is advisory, not blocking', () {
      final v = gate.evaluate(metrics(luminance: 0.96));
      expect(v.hasBlocking, isFalse);
      expect(v.hasAdvisory, isTrue);
    });

    test('only advisory issues are recorded on the page', () {
      // A blocking issue is either stopped here or consciously overridden;
      // re-flagging it afterwards would quietly re-litigate that decision.
      final blocked = gate.evaluate(metrics(sharpness: 2, luminance: 0.05));
      expect(blocked.hasBlocking, isTrue);
      expect(blocked.recordedWarnings, isEmpty);

      final advisoryOnly = gate.evaluate(metrics(contrast: 0.01));
      expect(advisoryOnly.recordedWarnings, advisoryOnly.advisoryMessages);
      expect(advisoryOnly.recordedWarnings, isNotEmpty);
    });

    test('blocking and advisory issues are reported together', () {
      final v = gate.evaluate(
          metrics(sharpness: 1, luminance: 0.05, contrast: 0.005));
      expect(v.blockingMessages.length, 2);
      expect(v.advisoryMessages, isNotEmpty);
    });
  });

  group('measured quality', () {
    test('a flat field has no sharpness and scores as blurred', () {
      // A genuinely flat image has no second derivative at all. This is the
      // case that proves the sharpness metric is doing something, rather than
      // every image passing by accident.
      final m = measureRegion(
          toLuma(flat(64, 64, 180), 64, 64), PageBounds.fullFrame());
      expect(m.sharpness, closeTo(0, 0.001));
      expect(
          const PageQualityCheck().evaluate(m).blockingMessages,
          anyElement(contains('blurred')));
    });

    test('high-frequency detail reads as sharp', () {
      final m = measureRegion(
          toLuma(sharpText(64, 64), 64, 64), PageBounds.fullFrame());
      expect(m.sharpness, greaterThan(1000),
          reason: 'hard black/white edges should score far above the gate');
      expect(const PageQualityCheck().evaluate(m).hasBlocking, isFalse);
    });

    test('measuring only the page ignores the desk around it', () {
      // A small bright page on a large dark frame. Measured whole, the frame
      // is mostly dark and would be rejected; measured on the page, it passes.
      // This is why the crop runs before the check.
      final bytes = frame(
          w: 120, h: 120, shade: 10, pageShade: 210,
          pageLeft: 0.3, pageTop: 0.3, pageRight: 0.7, pageBottom: 0.7);
      final luma = toLuma(bytes, 120, 120);

      final whole = measureRegion(luma, PageBounds.fullFrame());
      final pageOnly = measureRegion(luma,
          const PageBounds(left: 0.3, top: 0.3, right: 0.7, bottom: 0.7));

      expect(whole.luminance, lessThan(0.2),
          reason: 'the whole frame is dominated by the dark desk');
      expect(pageOnly.luminance, greaterThan(0.6),
          reason: 'the page itself is well lit');
      expect(const PageQualityCheck().evaluate(pageOnly).hasBlocking, isFalse);
    });

    test('luminance and contrast land in their documented ranges', () {
      final m = measureRegion(
          toLuma(sharpText(80, 80), 80, 80), PageBounds.fullFrame());
      expect(m.luminance, inInclusiveRange(0, 1));
      expect(m.contrast, greaterThan(0));
      expect(m.darkFraction, inInclusiveRange(0, 1));
      expect(m.brightFraction, inInclusiveRange(0, 1));
    });
  });

  group('downsampling', () {
    test('large images are reduced, small ones are not', () {
      final big = toLuma(flat(1200, 1600, 100), 1200, 1600);
      expect(big.width, lessThanOrEqualTo(192));
      expect(big.height, lessThanOrEqualTo(192));

      final small = toLuma(flat(100, 80, 100), 100, 80);
      expect(small.width, 100);
      expect(small.height, 80);
    });

    test('aspect ratio is preserved when downsampling', () {
      final luma = toLuma(flat(800, 400, 100), 800, 400);
      expect(luma.width / luma.height, closeTo(2.0, 0.1));
    });

    test('a flat image downsamples to a flat image', () {
      final luma = toLuma(flat(600, 600, 150), 600, 600);
      expect(luma.pixels.every((p) => (p - 150).abs() <= 1), isTrue);
    });
  });

  group('submission model', () {
    AssignmentSubmission blank() => const AssignmentSubmission(
          id: 'ASUB-1',
          assignmentId: 'ASG-001',
          studentId: 'STU-001',
          classId: 'JHS2A',
          subjectId: 'MATH',
          recorder: 'Ms. Mensah',
          capturedAt: '2026-09-20 09:15',
        );

    AssignmentPage page(int n, {String id = '', List<String> warnings = const []}) =>
        AssignmentPage(
          id: id.isEmpty ? 'APAGE-$n' : id,
          pageNumber: n,
          imagePath: '/tmp/p$n.png',
          capturedAt: '2026-09-20 09:15',
          qualityWarnings: warnings,
        );

    test('pages stay together as one submission', () {
      final sub = blank().withAppendedPage(page(1)).withAppendedPage(page(2));
      expect(sub.pages, hasLength(2));
      expect(sub.assignmentId, 'ASG-001');
      expect(sub.hasPhotos, isTrue);
    });

    test('appended pages are ordered, regardless of insertion order', () {
      final sub = blank().withAppendedPage(page(3)).withAppendedPage(page(1));
      expect(sub.pages.map((p) => p.pageNumber).toList(), [1, 3]);
    });

    test('removing a page renumbers the rest so the booklet stays contiguous',
        () {
      final sub = blank()
          .withAppendedPage(page(1))
          .withAppendedPage(page(2, id: 'APAGE-2'))
          .withAppendedPage(page(3));
      final after = sub.withoutPage('APAGE-2');

      expect(after.pages, hasLength(2));
      expect(after.pages.map((p) => p.pageNumber).toList(), [1, 2],
          reason: 'a gap would read as a missing page');
      expect(after.pages.any((p) => p.id == 'APAGE-2'), isFalse);
    });

    test('removing the first page keeps the remaining order', () {
      final sub = blank()
          .withAppendedPage(page(1, id: 'APAGE-A'))
          .withAppendedPage(page(2, id: 'APAGE-B'));
      final after = sub.withoutPage('APAGE-A');
      expect(after.pages.single.id, 'APAGE-B');
      expect(after.pages.single.pageNumber, 1);
    });

    test('warnings are prefixed with their page so a reviewer can act on them',
        () {
      final sub = blank()
          .withAppendedPage(page(1, warnings: const ['blurred']))
          .withAppendedPage(page(2, warnings: const ['too dark']));
      expect(sub.allWarnings, ['Page 1: blurred', 'Page 2: too dark']);
    });

    test('a submission with no photos and no notes is neither', () {
      final sub = blank();
      expect(sub.hasPhotos, isFalse);
      expect(sub.hasManualEntry, isFalse);
    });

    test('manual notes count as an entry even with no photos', () {
      final sub = blank().copyWith(manualNotes: '  3/4 + 1/6 = 11/12  ');
      expect(sub.hasPhotos, isFalse);
      expect(sub.hasManualEntry, isTrue,
          reason: 'a teacher who could not photograph still handed over work');
      expect(sub.manualNotes, '  3/4 + 1/6 = 11/12  ');
    });

    test('JSON round-trip preserves pages, notes and status', () {
      final sub = blank()
          .withAppendedPage(page(1, warnings: const ['glare']))
          .copyWith(
              manualNotes: 'Q1: 11/12',
              status: AssignmentSubmissionStatus.needsReview);

      final back = AssignmentSubmission.fromJson(sub.toJson());
      expect(back.id, sub.id);
      expect(back.assignmentId, 'ASG-001');
      expect(back.studentId, 'STU-001');
      expect(back.pages, hasLength(1));
      expect(back.pages.first.pageNumber, 1);
      expect(back.pages.first.qualityWarnings, ['glare']);
      expect(back.manualNotes, 'Q1: 11/12');
      expect(back.status, AssignmentSubmissionStatus.needsReview);
    });

    test('an unknown status decodes to queued rather than throwing', () {
      final back = AssignmentSubmission.fromJson(blank().toJson()
        ..['status'] = 'something_new');
      expect(back.status, AssignmentSubmissionStatus.queued);
    });

    test('a missing pages key decodes to no pages', () {
      final json = blank().toJson()..remove('pages');
      expect(AssignmentSubmission.fromJson(json).pages, isEmpty);
    });
  });
}
