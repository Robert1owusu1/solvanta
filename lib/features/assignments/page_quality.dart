/// Quality gate for assignment page photos (doc §47).
///
/// Pure logic over [PageMetrics] — no Flutter, no I/O — so the thresholds that
/// decide whether a photo is accepted are unit-testable directly.
///
/// The gate deliberately has TWO levels, because the task it implements asks
/// for photos to be "rejected or flagged … before upload, not after":
///
///   * BLOCKING — the page is unreadable as captured. Uploading it would only
///     push the problem downstream, where whoever reads it cannot retake the
///     shot. The teacher is stopped here, while the paper is still in front of
///     them. An explicit "Upload anyway" escape hatch exists, because a
///     threshold cannot see a genuinely faded pencil page that a human can
///     still read.
///
///   * ADVISORY — the page is usable but worth reshooting. These are recorded
///     on the submission so the reviewer knows the capture was imperfect, and
///     never block.
///
/// Both are evaluated BEFORE any upload happens.
library;

import 'page_metrics.dart';

class PageQualityIssue {
  const PageQualityIssue(this.message, {required this.blocking});

  final String message;

  /// True when the photo should not be uploaded without an explicit override.
  final bool blocking;

  @override
  String toString() => 'PageQualityIssue($message, blocking: $blocking)';
}

/// Thresholds, kept as named constants so they can be argued about and tuned
/// against real photos rather than buried in conditionals.
class PageQualityThresholds {
  const PageQualityThresholds({
    this.minLuminance = 0.20,
    this.maxLuminance = 0.92,
    this.minContrast = 0.045,
    this.minSharpness = 55,
    this.maxDarkFraction = 0.35,
    this.maxBrightFraction = 0.30,
  });

  /// Below this mean brightness the page is too dark to read.
  final double minLuminance;

  /// Above this mean brightness the whole frame is washed out.
  final double maxLuminance;

  /// Below this standard deviation the image is flat — no separation between
  /// ink and paper.
  final double minContrast;

  /// Below this Laplacian variance the image is blurred.
  final double minSharpness;

  /// Above this share of pixels in deep shadow the page is partly obscured.
  final double maxDarkFraction;

  /// Above this share of blown-out pixels glare has eaten part of the work.
  final double maxBrightFraction;

  static const PageQualityThresholds standard = PageQualityThresholds();
}

/// The verdict for one page.
class PageQualityVerdict {
  const PageQualityVerdict({required this.issues});

  final List<PageQualityIssue> issues;

  /// Messages of the blocking issues, in order.
  List<String> get blockingMessages => [
        for (final i in issues)
          if (i.blocking) i.message
      ];

  /// Messages of the advisory issues, in order.
  List<String> get advisoryMessages => [
        for (final i in issues)
          if (!i.blocking) i.message
      ];

  bool get hasBlocking => blockingMessages.isNotEmpty;
  bool get hasAdvisory => advisoryMessages.isNotEmpty;
  bool get clean => issues.isEmpty;

  /// What to persist on the page record. Advisory issues are recorded so the
  /// reviewer knows the capture was imperfect; blocking ones are not, because
  /// the gate either stopped them or the teacher consciously overrode them,
  /// and an override is a decision that should not be quietly re-litigated by
  /// a warning colour later.
  List<String> get recordedWarnings => advisoryMessages;
}

class PageQualityCheck {
  const PageQualityCheck({this.thresholds = PageQualityThresholds.standard});

  final PageQualityThresholds thresholds;

  /// Judges the cropped page region — see [measureRegion] for why the crop is
  /// what gets measured.
  PageQualityVerdict evaluate(PageMetrics m) {
    final issues = <PageQualityIssue>[];

    // Blur is the failure mode that costs the most downstream, and the one a
    // teacher is least likely to notice on a small phone screen.
    if (m.sharpness < thresholds.minSharpness) {
      issues.add(const PageQualityIssue(
        'Photo is blurred — hold steady and retake.',
        blocking: true,
      ));
    }

    if (m.luminance < thresholds.minLuminance) {
      issues.add(const PageQualityIssue(
        'Too dark to read — move to better light and retake.',
        blocking: true,
      ));
    }

    if (m.brightFraction > thresholds.maxBrightFraction) {
      issues.add(const PageQualityIssue(
        'Glare has washed out part of the page — tilt away from the light '
        'and retake.',
        blocking: true,
      ));
    }

    if (m.darkFraction > thresholds.maxDarkFraction) {
      issues.add(const PageQualityIssue(
        'A shadow covers part of the page — move and retake.',
        blocking: true,
      ));
    }

    // Advisory from here down: worth saying, not worth stopping for.

    if (m.luminance > thresholds.maxLuminance) {
      issues.add(const PageQualityIssue(
        'The photo looks washed out — it may be hard to read.',
        blocking: false,
      ));
    }

    if (m.contrast < thresholds.minContrast) {
      issues.add(const PageQualityIssue(
        'Low contrast between ink and paper — reshoot if possible.',
        blocking: false,
      ));
    }

    return PageQualityVerdict(issues: issues);
  }
}
