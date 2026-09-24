import 'package:flutter_test/flutter_test.dart';
import 'package:solvanta/features/assessment/scan_quality.dart';
import 'package:solvanta/core/models/scan_page.dart';

void main() {
  ScanImageStats good() => const ScanImageStats(
      width: 2400, height: 3200, luminance: 0.62, contrast: 0.21);

  test('clean portrait photo passes all checks', () {
    expect(ScanQualityCheck.evaluate(good()), isEmpty);
    expect(ScanQualityCheck.needsRetake(good()), isFalse);
  });

  test('landscape page triggers rotation warning', () {
    final landscape = const ScanImageStats(
        width: 3200, height: 2400, luminance: 0.62, contrast: 0.21);
    final warnings = ScanQualityCheck.evaluate(landscape);
    expect(warnings, isNotEmpty);
    expect(warnings.any((w) => w.toLowerCase().contains('rotate')), isTrue);
  });

  test('dark photo requests a retake', () {
    final dark = const ScanImageStats(
        width: 2400, height: 3200, luminance: 0.15, contrast: 0.2);
    expect(ScanQualityCheck.evaluate(dark),
        anyElement(contains('dark')));
    expect(ScanQualityCheck.needsRetake(dark), isTrue);
  });

  test('blurred/flat image requests a retake', () {
    final blurry = const ScanImageStats(
        width: 2400, height: 3200, luminance: 0.6, contrast: 0.02);
    expect(ScanQualityCheck.evaluate(blurry),
        anyElement(contains('blurred')));
    expect(ScanQualityCheck.needsRetake(blurry), isTrue);
  });

  test('low resolution adds a warning', () {
    final tiny = const ScanImageStats(
        width: 400, height: 500, luminance: 0.6, contrast: 0.2);
    expect(ScanQualityCheck.evaluate(tiny),
        anyElement(contains('resolution')));
  });

  test('multiple quality problems are reported together', () {
    final bad = const ScanImageStats(
        width: 3200, height: 2400, luminance: 0.1, contrast: 0.01);
    final warnings = ScanQualityCheck.evaluate(bad);
    expect(warnings, hasLength(greaterThanOrEqualTo(3)));
  });

  test('ScanPage JSON round-trip preserves warnings and status', () {
    final scan = ScanPage(
      id: 'SCAN-1',
      assessmentId: 'ASSMT-A',
      studentId: 'STU-1',
      imagePath: '/tmp/p1.jpg',
      pageNumber: 2,
      capturedAt: '2026-09-21 07:45',
      recorder: 'Ms. Mensah',
      status: ScanStatus.needsReview,
      qualityWarnings: const ['Photo is too dark'],
    );
    final back = ScanPage.fromJson(scan.toJson());
    expect(back.id, scan.id);
    expect(back.imagePath, scan.imagePath);
    expect(back.pageNumber, 2);
    expect(back.status, ScanStatus.needsReview);
    expect(back.qualityWarnings, ['Photo is too dark']);
  });

  test('ScanPage copyWith updates status', () {
    const scan = ScanPage(
      id: 'SCAN-2',
      assessmentId: 'ASSMT-B',
      studentId: 'STU-2',
      imagePath: '/tmp/p2.jpg',
      pageNumber: 1,
      capturedAt: '2026-09-21',
      recorder: 'Gate',
      status: ScanStatus.queued,
    );
    expect(scan.copyWith(status: ScanStatus.processed).status,
        ScanStatus.processed);
  });
}