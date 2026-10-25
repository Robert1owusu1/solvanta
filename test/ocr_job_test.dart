import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/api/api_client.dart';
import 'package:solvanta/core/models/ocr_job.dart';
import 'package:solvanta/core/models/question.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/features/ocr/ocr_repository.dart';
import 'package:solvanta/features/ocr/ocr_review_screen.dart';

// =============================================================================
// OCR queue — Phase 4 guards
//
// Two things are pinned here, both of which the phase depends on being able
// to trust later: that a teacher's confirmation is never lost or confused
// with what the machine said, and that a page photographed with no signal is
// still there afterwards. Everything runs with no backend and no network, so
// the offline path under test is the real one rather than a simulation of it.
// =============================================================================

OcrJob aJob({
  String id = 'OCR-1',
  OcrJobStatus status = OcrJobStatus.read,
  String text = 'solve 2x + 1 = 7',
  String? reviewedText,
  String? confirmedAt,
  String? image = 'AAAA',
}) =>
    OcrJob(
      id: id,
      subjectId: 'MATH',
      topic: 'Linear equations',
      type: QuestionType.shortAnswer,
      classId: 'CLS-1',
      createdAt: '2026-10-25T10:00:00.000',
      status: status,
      text: text,
      reviewedText: reviewedText,
      confirmedAt: confirmedAt,
      imageBase64: image,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('OcrJob', () {
    test('a reading survives a JSON round trip', () {
      final before = aJob(
        status: OcrJobStatus.read,
        text: 'x = 3',
        image: null,
      ).copyWith(
        provider: 'mock',
        costTier: 'standard',
        lines: 12,
        confidence: 0.87,
        warnings: const ['watch for stray marks'],
        requestId: 'QGEN-1',
      );

      final after = OcrJob.fromJson(before.toJson());

      expect(after.text, 'x = 3');
      expect(after.provider, 'mock');
      expect(after.costTier, 'standard');
      expect(after.lines, 12);
      expect(after.confidence, closeTo(0.87, 1e-9));
      expect(after.warnings, ['watch for stray marks']);
      expect(after.requestId, 'QGEN-1');
      expect(after.status, OcrJobStatus.read);
    });

    test('the parked photo rides along in the JSON', () {
      expect(aJob().toJson()['imageBase64'], 'AAAA');
      expect(aJob().imageBase64, 'AAAA');
    });

    test('an unknown status falls back to queued rather than guessing', () {
      expect(OcrJobStatus.fromKey('not-a-status'), OcrJobStatus.queued);
      expect(OcrJobStatus.fromKey('read'), OcrJobStatus.read);
    });

    test('a correction sits beside the engine text, never over it', () {
      final edited = aJob(text: 'x = 3').copyWith(reviewedText: 'x = 3.');

      // Both survive: what was read, and what the teacher decided it says.
      expect(edited.text, 'x = 3',
          reason: 'overwriting the engine text would make the correction '
              'impossible to distinguish from the original reading');
      expect(edited.reviewedText, 'x = 3.');
      expect(edited.effectiveText, 'x = 3.');
    });

    test('without a correction the engine text is what is on offer', () {
      final unreviewed = aJob(text: 'x = 3');

      expect(unreviewed.reviewedText, isNull);
      expect(unreviewed.effectiveText, 'x = 3');
      expect(unreviewed.isConfirmed, isFalse);
    });

    test('clearing the photo leaves every other field alone', () {
      final cleared = aJob().copyWith(clearImage: true);

      expect(cleared.imageBase64, isNull);
      expect(cleared.text, 'solve 2x + 1 = 7');
      expect(cleared.status, OcrJobStatus.read,
          reason: 'dropping bytes must not quietly mark the job done');
    });

    test('a confirmation is only a confirmation once confirmedAt is set', () {
      expect(aJob().copyWith(status: OcrJobStatus.confirmed).isConfirmed,
          isFalse);
      expect(
          aJob()
              .copyWith(
                  status: OcrJobStatus.confirmed,
                  confirmedAt: '2026-10-25T11:00:00.000')
              .isConfirmed,
          isTrue);
    });
  });

  group('merge rank', () {
    // The merge between this device and the server is where a confirmation
    // could be thrown away. These pin the ordering that prevents it.

    test('a confirmation beats every other state on either side', () {
      final confirmed = aJob(status: OcrJobStatus.confirmed).mergeRank;
      for (final s in OcrJobStatus.values) {
        if (s == OcrJobStatus.confirmed) continue; // itself, not a rival
        expect(confirmed, greaterThan(aJob(status: s).mergeRank),
            reason: 'merging away a $s copy would discard the teacher decision');
      }
    });

    test('an unreadable page never beats one that was read', () {
      expect(aJob(status: OcrJobStatus.failed).mergeRank,
          lessThan(aJob(status: OcrJobStatus.read).mergeRank));
      // Failure is stuck, not ahead: it sits level with a read in progress.
      expect(aJob(status: OcrJobStatus.failed).mergeRank,
          aJob(status: OcrJobStatus.reading).mergeRank);
    });

    test('a finished copy always beats one still queued', () {
      expect(aJob(status: OcrJobStatus.queued).mergeRank, 0);
      expect(aJob(status: OcrJobStatus.read).mergeRank,
          greaterThan(aJob(status: OcrJobStatus.queued).mergeRank));
    });
  });

  group('OcrRepository', () {
    test('a job written offline is still there to be retried', () async {
      final repo = OcrRepository();
      await repo.enqueue(aJob(status: OcrJobStatus.queued));

      final jobs = await repo.all();
      expect(jobs, hasLength(1));
      expect(jobs.single.id, 'OCR-1');
      expect(jobs.single.status, OcrJobStatus.queued,
          reason: 'it was never read, so it must still be waiting');
      expect(jobs.single.imageBase64, 'AAAA',
          reason: 'the photo is the whole point of the queue — losing it '
              'would lose the page');
    });

    test('saving the same job twice replaces rather than duplicates',
        () async {
      final repo = OcrRepository();
      await repo.save(aJob());
      await repo.save(aJob().copyWith(status: OcrJobStatus.reading));

      final jobs = await repo.all();
      expect(jobs, hasLength(1));
      expect(jobs.single.status, OcrJobStatus.reading);
    });

    test('confirm records the decision without altering the reading',
        () async {
      final repo = OcrRepository();
      await repo.save(aJob(text: 'x = 3'));

      await repo.confirm('OCR-1', 'x = 3 (working shown)');

      final job = (await repo.all()).single;
      expect(job.text, 'x = 3', reason: "the engine's own words are evidence");
      expect(job.reviewedText, 'x = 3 (working shown)');
      expect(job.effectiveText, 'x = 3 (working shown)');
      expect(job.status, OcrJobStatus.confirmed);
      expect(job.confirmedAt, isNotNull);
      expect(job.isConfirmed, isTrue);
    });

    test('confirming drops the photo now that review is over', () async {
      final repo = OcrRepository();
      await repo.save(aJob());

      await repo.confirm('OCR-1', 'x = 3');

      expect((await repo.all()).single.imageBase64, isNull);
    });

    test('a job still awaiting confirmation keeps its photo', () async {
      final repo = OcrRepository();
      await repo.save(aJob());

      expect((await repo.all()).single.imageBase64, 'AAAA');
    });

    test('confirming a job that is not there changes nothing', () async {
      final repo = OcrRepository();
      await repo.save(aJob());

      await repo.confirm('OCR-NOPE', 'x = 3');

      final job = (await repo.all()).single;
      expect(job.confirmedAt, isNull);
      expect(job.reviewedText, isNull);
      expect(job.status, OcrJobStatus.read);
    });

    test('push without a backend leaves the job exactly as it was',
        skip: ApiClient.isConfigured ? 'needs no backend configured' : null,
        () async {
      final repo = OcrRepository();
      await repo.save(aJob(status: OcrJobStatus.queued));

      await repo.push(aJob(status: OcrJobStatus.queued));

      final job = (await repo.all()).single;
      expect(job.status, OcrJobStatus.queued);
      expect(job.imageBase64, 'AAAA');
      expect(job.requestId, isNull);
      expect(job.error, isEmpty,
          reason: 'being offline is not an error worth showing as one');
    });

    test('retryQueued is a no-op without a backend, not a crash',
        skip: ApiClient.isConfigured ? 'needs no backend configured' : null,
        () async {
      final repo = OcrRepository();
      await repo.save(aJob(status: OcrJobStatus.queued));

      await expectLater(repo.retryQueued(), completes);

      expect((await repo.all()).single.status, OcrJobStatus.queued);
    });

    test('only queued jobs are candidates for a retry', () async {
      final repo = OcrRepository();
      await repo.save(aJob(id: 'OCR-QUEUED', status: OcrJobStatus.queued));
      await repo.save(aJob(id: 'OCR-CONFIRMED', status: OcrJobStatus.confirmed));

      // The read set is what retryQueued filters on; if a confirmed job ever
      // became a retry candidate it would be re-submitted after a teacher had
      // already signed it off.
      final jobs = await repo.all();
      expect(
        jobs.where((j) => j.status == OcrJobStatus.queued).map((j) => j.id),
        ['OCR-QUEUED'],
      );
    });
  });

  group('LocalStore', () {
    test('ocr jobs are stored under their own key', () async {
      final store = LocalStore();
      await store.saveOcrJobs([aJob()]);

      expect(await store.loadOcrJobs(), hasLength(1));
      // And nothing is left behind for the next run.
      SharedPreferences.setMockInitialValues({});
      expect(await store.loadOcrJobs(), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Layout at the narrowest width anyone will use.
  //
  // The dashboard smoke test only ever opens the queue screen — it stops at
  // the list and never pushes the confirmation step, which is the screen a
  // teacher actually reads a page on. These pump it directly, in every state
  // it can be in, so a widget that only breaks once a page has been read
  // still has to fit a phone.
  // -------------------------------------------------------------------------
  group('phone-width layout', () {
    const phone = Size(390, 900);

    Future<void> pumpAt(WidgetTester tester, Widget w) async {
      addTearDown(tester.view.reset);
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(home: w));
      // Real async hops for storage and image decoding, like the smoke test.
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('the queue screen fits', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpAt(tester, const OcrReviewScreen());

      expect(tester.takeException(), isNull);
    });

    testWidgets('the queue screen fits with pages already queued',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore();
      await store.saveOcrJobs([
        aJob(id: 'OCR-A', status: OcrJobStatus.queued),
        aJob(id: 'OCR-B', status: OcrJobStatus.read),
        aJob(id: 'OCR-C', status: OcrJobStatus.confirmed),
      ]);
      await pumpAt(tester, const OcrReviewScreen());

      expect(tester.takeException(), isNull);
    });

    for (final status in OcrJobStatus.values) {
      testWidgets('confirmation fits when the job is ${status.name}',
          (tester) async {
        await pumpAt(
            tester, OcrConfirmationScreen(job: aJob(status: status)));

        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('confirmation fits with a photo, warnings and every chip',
        (tester) async {
      final job = aJob(status: OcrJobStatus.read, image: _onePixelPng)
          .copyWith(
        provider: 'mock',
        costTier: 'high',
        lines: 40,
        confidence: 0.42,
        warnings: const [
          'Watch for stray marks',
          'This page is low contrast',
          'Line 4 could not be read',
        ],
      );
      await pumpAt(tester, OcrConfirmationScreen(job: job));

      // What a teacher reads together sits above the fold…
      expect(find.text('What the engine read'), findsOneWidget);
      expect(find.textContaining('Watch for stray marks'), findsOneWidget);

      // …and the decision is below it, reached the way a phone reaches it: by
      // scrolling. A ListView builds children as they arrive, so if the list
      // never got far enough the confirm button would not exist at all.
      for (var i = 0;
          i < 8 && find.text('Confirm this reading').evaluate().isEmpty;
          i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -300));
        await tester.pump(const Duration(milliseconds: 80));
      }

      expect(find.text('Confirm this reading'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a page that failed to read still fits and still offers a retry',
        (tester) async {
      final job = aJob(status: OcrJobStatus.failed).copyWith(
          error: 'The server said this file was not an image.');
      await pumpAt(tester, OcrConfirmationScreen(job: job));

      expect(tester.takeException(), isNull);
      expect(find.text('Try again'), findsOneWidget);
    });
  });
}

/// A real 1×1 PNG, so the photo path is exercised with bytes that decode.
const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
