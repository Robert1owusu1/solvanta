import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/api/api_client.dart';
import 'package:solvanta/core/models/marking_draft.dart';
import 'package:solvanta/core/models/ocr_job.dart';
import 'package:solvanta/core/models/question.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/features/auth/auth_repository.dart';
import 'package:solvanta/features/marking/marking_drafts_repository.dart';
import 'package:solvanta/features/ocr/ocr_repository.dart';

// =============================================================================
// Draft marks — Phase 5, app side
//
// The offline tests run with no backend, so the path under test is the real
// offline one. The live group runs only with SOLVANTA_API_URL set:
//
//   SOLVANTA_API_URL=http://127.0.0.1:8080 flutter test test/marking_drafts_test.dart
//
// The live tests finalize STU-002's diagnostic, so run them against a freshly
// started in-memory server.
// =============================================================================

Map<String, dynamic> draftJson({
  String id = 'MD-1',
  String submissionId = 'SUB-1',
  String status = 'draft',
}) =>
    {
      'id': id,
      'schemeId': 'MS-1',
      'schemeVersion': 2,
      'targetKind': 'assessment',
      'submissionId': submissionId,
      'studentId': 'STU-002',
      'classId': 'JHS2A',
      'sourceText': '1. 1/2',
      'ocrJobIds': ['OCR-1'],
      'unassigned': ['Name: Akosua'],
      'status': status,
      'draftTotal': 3,
      'maxTotal': 7,
      'needsReview': 1,
      'createdAt': '2026-10-25 10:00',
      'final': false,
      'answers': [
        {
          'schemeQuestionId': 'SQ-1',
          'questionNumber': 1,
          'studentAnswer': '1/2',
          'working': <String>[],
          'draftMarks': 3,
          'totalMarks': 4,
          'method': 'exact',
          'matchedText': '1/2',
          'needsReview': false,
          'reasons': ['Matches the accepted answer "1/2" exactly (worth 3 marks).'],
          'steps': [
            {'stepId': 'step-1', 'type': 'method', 'criteria': 'x', 'marks': 2, 'awarded': 0, 'status': 'set_by_answer'},
          ],
        },
      ],
    };

void main() {
  group('offline', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a draft survives a JSON round trip and is never final', () {
      final d = MarkingDraft.fromJson(draftJson());
      final again = MarkingDraft.fromJson(d.toJson());
      expect(again.isFinal, isFalse);
      expect(again.toJson()['final'], isFalse);
      expect(again.draftTotal, 3);
      expect(again.unassigned, ['Name: Akosua']);
      expect(again.answers.single.schemeQuestionId, 'SQ-1');
      expect(again.answers.single.reasons, isNotEmpty);
      expect(again.answers.single.steps.single.status, 'set_by_answer');
    });

    test('a request made offline is kept on the device', () async {
      final repo = MarkingDraftsRepository();
      final req = await repo.request(
        schemeId: 'MS-1',
        submissionId: 'SUB-1',
        studentId: 'STU-002',
        answers: [
          {'questionNumber': 1, 'text': '1/2'},
        ],
      );
      final pending = await repo.pending();
      expect(pending.map((r) => r.id), [req.id]);
      expect(pending.single.failed, isFalse);
      expect(pending.single.body()['answers'], isNotEmpty);
      expect(pending.single.body().containsKey('ocrJobIds'), isFalse);
    });

    test('exactly one source: confirmed readings or typed answers', () async {
      final repo = MarkingDraftsRepository();
      expect(
        () => repo.request(schemeId: 'MS-1', submissionId: 'SUB-1', studentId: 'STU-002'),
        throwsArgumentError,
      );
      expect(
        () => repo.request(
          schemeId: 'MS-1',
          submissionId: 'SUB-1',
          studentId: 'STU-002',
          ocrJobIds: ['OCR-1'],
          answers: [
            {'questionNumber': 1, 'text': '1/2'},
          ],
        ),
        throwsArgumentError,
      );
      expect(await repo.pending(), isEmpty);
    });

    test('the draft to review skips discarded ones', () async {
      await LocalStore().saveMarkingDrafts([
        MarkingDraft.fromJson(draftJson(id: 'MD-OLD', status: 'discarded')),
        MarkingDraft.fromJson(draftJson(id: 'MD-NEW')),
        MarkingDraft.fromJson(draftJson(id: 'MD-ELSE', submissionId: 'SUB-2')),
      ]);
      final repo = MarkingDraftsRepository();
      expect((await repo.currentDraft('SUB-1'))?.id, 'MD-NEW');
      expect((await repo.draftsFor('SUB-1')).length, 2);
      expect(await repo.currentDraft('SUB-9'), isNull);
    });

    test('an unconfirmed reading is never sent for marking', () async {
      await OcrRepository().save(OcrJob(
        id: 'OCR-1',
        subjectId: 'MATH',
        topic: 'Fractions',
        type: QuestionType.shortAnswer,
        classId: 'JHS2A',
        createdAt: '2026-10-25T10:00:00.000',
        status: OcrJobStatus.read,
        text: '1. 1/2',
      ));
      expect(await OcrRepository().sendConfirmed(['OCR-1']), isFalse);
    });
  });

  group('live', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    final skip = !ApiClient.isConfigured;

    Future<void> signInFresh(String email, String password) async {
      SharedPreferences.setMockInitialValues({});
      ApiClient.sharedToken = null;
      final user = await AuthRepository().login(email: email, password: password);
      expect(user, isNotNull, reason: 'sign-in for $email');
    }

    late String schemeId;

    test('a headteacher writes the scheme for the diagnostic', skip: skip, () async {
      await signInFresh('head@school.gh', 'head123');
      final res = await ApiClient().post('/api/assessments/ASSMT-MAT-HALF/marking-scheme', {
        'assessmentId': 'ASSMT-MAT-HALF',
        'questions': [
          {
            'questionNumber': 1,
            'totalMarks': 4,
            'markBreakdown': [
              {'type': 'method', 'criteria': 'Equivalent fraction', 'marks': 2},
              {'type': 'final_answer', 'criteria': 'Answer', 'marks': 2},
            ],
            'acceptedAnswers': [
              {'answerText': '2/4', 'normalizedForm': '24', 'marksAwarded': 4, 'isPrimary': true},
              {'answerText': '1/2', 'normalizedForm': '12', 'marksAwarded': 3, 'isPrimary': false},
            ],
            'misconceptions': [],
          },
        ],
      });
      schemeId = (res as Map<String, dynamic>)['id'] as String;
    });

    test('a teacher confirms a reading and gets a draft, not a mark', skip: skip, () async {
      await signInFresh('efua.mensah@school.gh', 'teacher123');
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final ocr = OcrRepository();
      await ocr.save(OcrJob(
        id: 'OCR-LIVE-$stamp',
        subjectId: 'MATH',
        topic: 'Fractions',
        type: QuestionType.shortAnswer,
        classId: 'JHS2A',
        createdAt: DateTime.now().toIso8601String(),
        status: OcrJobStatus.read,
        text: '1. l/2',
      ));
      // The teacher corrects the engine's "l/2" to "1/2" and confirms.
      await ocr.confirm('OCR-LIVE-$stamp', 'Name: Akosua\n1. 1/2');

      final repo = MarkingDraftsRepository();
      await repo.request(
        schemeId: schemeId,
        submissionId: 'SUB-M1-STU002',
        studentId: 'STU-002',
        ocrJobIds: ['OCR-LIVE-$stamp'],
      );
      expect(await repo.pending(), isEmpty, reason: 'the request was answered');
      final draft = await repo.currentDraft('SUB-M1-STU002');
      expect(draft, isNotNull);
      expect(draft!.isFinal, isFalse);
      expect(draft.status, 'draft');
      expect(draft.draftTotal, 3);
      expect(draft.answers.single.studentAnswer, '1/2');
      expect(draft.unassigned, ['Name: Akosua']);
    });

    test('a teacher reviews and finalizes a draft, and the score is recorded', skip: skip, () async {
      // A scheme that mirrors ASSMT-MAT-HALF question for question, so the
      // finalized marks can be recorded against the paper.
      await signInFresh('head@school.gh', 'head123');
      Map<String, dynamic> q(int n, double total, String answer) => {
            'questionNumber': n,
            'totalMarks': total,
            'markBreakdown': [
              {'type': 'final_answer', 'criteria': 'Answer', 'marks': total},
            ],
            'acceptedAnswers': [
              {'answerText': answer, 'normalizedForm': answer, 'marksAwarded': total, 'isPrimary': true},
            ],
            'misconceptions': [],
          };
      final scheme = await ApiClient().post('/api/assessments/ASSMT-MAT-HALF/marking-scheme', {
        'assessmentId': 'ASSMT-MAT-HALF',
        'questions': [q(1, 2, '2/4'), q(2, 3, '3/8 m'), q(3, 4, '11/12')],
      }) as Map<String, dynamic>;

      await signInFresh('efua.mensah@school.gh', 'teacher123');
      final repo = MarkingDraftsRepository();
      await repo.request(
        schemeId: scheme['id'] as String,
        studentId: 'STU-002', // the server finds the paper
        answers: [
          {'questionNumber': 1, 'text': '2/4'},
          {'questionNumber': 2, 'text': '1/2 m'},
          {'questionNumber': 3, 'text': '11/12'},
        ],
      );
      final queued = (await repo.reviewQueue())
          .where((d) => d.schemeId == scheme['id'] && d.studentId == 'STU-002')
          .toList();
      expect(queued, hasLength(1));
      final draft = (await repo.load(queued.single.id))!;
      expect(draft.isFinal, isFalse);
      expect(draft.draftTotal, 6);

      final decisions = {
        ...acceptConfident(draft, {}),
        draft.answers[1].schemeQuestionId: const DraftDecision(marks: 1, note: 'Method shown'),
      };
      final done = await repo.finalize(draft, decisions);
      expect(done.isFinal, isTrue);
      expect(done.finalTotal, 7);

      final results = await ApiClient().get('/api/assessments/ASSMT-MAT-HALF/results') as Map<String, dynamic>;
      final row = (results['rows'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((r) => (r['student'] as Map)['id'] == 'STU-002');
      expect(row['earned'], 7);
    });

    test('a pupil cannot see drafts', skip: skip, () async {
      await signInFresh('kojo.owusu@school.gh', 'student123');
      await expectLater(
        ApiClient().get('/api/marking-drafts?submissionId=SUB-M1-STU002'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 403)),
      );
    });
  });
}
