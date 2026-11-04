import '../../core/models/assessment.dart';
import '../../core/models/question.dart';
import '../../core/models/submission.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';

class AssessmentRepository {
  AssessmentRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  Future<List<Question>> bank() => _store.loadQuestionBank();

  Future<void> saveBankQuestion(Question q) async {
    final all = await _store.loadQuestionBank();
    final list = <Question>[];
    var added = false;
    for (final e in all) {
      if (e.id == q.id) {
        list.add(q);
        added = true;
      } else {
        list.add(e);
      }
    }
    if (!added) list.add(q);
    await _store.saveQuestionBank(list);
    // Questions keep their client id on the server.
    await ServerSync.instance.send(
      added ? 'PATCH' : 'POST',
      added ? '/api/questions/${q.id}' : '/api/questions',
      body: q.toJson(),
    );
  }

  Future<void> deleteBankQuestion(String id) async {
    final all = await _store.loadQuestionBank();
    await _store.saveQuestionBank(
        all.where((q) => q.id != id).toList());
    await ServerSync.instance.send('DELETE', '/api/questions/$id');
  }

  Future<List<Assessment>> assessments() => _store.loadAssessments();

  Future<Assessment?> assessmentById(String id) async {
    for (final a in await _store.loadAssessments()) {
      if (a.id == id) return a;
    }
    return null;
  }

  Future<void> saveAssessment(Assessment a) async {
    final all = await _store.loadAssessments();
    final list = <Assessment>[];
    var added = false;
    for (final e in all) {
      if (e.id == a.id) {
        list.add(a);
        added = true;
      } else {
        list.add(e);
      }
    }
    if (!added) list.add(a);
    await _store.saveAssessments(list);
    // The server keeps the client id, so screens holding [a] stay valid.
    await ServerSync.instance.send(
      added ? 'PUT' : 'POST',
      added ? '/api/assessments/${a.id}' : '/api/assessments',
      body: a.toJson(),
    );
  }

  Future<List<AssessmentSubmission>> submissions() =>
      _store.loadSubmissions();

  Future<AssessmentSubmission?> submissionFor(
      String assessmentId, String studentId) async {
    final subs = await _store.loadSubmissions();
    for (final s in subs) {
      if (s.assessmentId == assessmentId && s.studentId == studentId) {
        return s;
      }
    }
    return null;
  }

  Future<void> submit({
    required Assessment assessment,
    required String studentId,
    required Map<String, String> answers,
    required Map<String, double> teacherMarks,
  }) async {
    final subs = await _store.loadSubmissions();
    final earned = computeEarned(
        assessment.questions, answers, teacherMarks);
    final date = _today();
    final sub = AssessmentSubmission(
      id: 'SUB-${DateTime.now().millisecondsSinceEpoch}',
      assessmentId: assessment.id,
      studentId: studentId,
      classId: assessment.classId,
      date: date,
      answers: answers,
      teacherMarks: teacherMarks,
      earned: earned,
    );
    subs.removeWhere((s) =>
        s.assessmentId == assessment.id && s.studentId == studentId);
    await _store.saveSubmissions([...subs, sub]);

    // The API auto-marks the answers, then takes the teacher's marks as
    // verdicts. Partial marking is normal here: the server keeps the marks
    // it got and answers 422 for the rest, which isn't worth surfacing.
    await ServerSync.instance.send(
      'POST',
      '/api/assessments/${assessment.id}/submit',
      body: {
        'studentId': studentId,
        'answers': answers,
        'classId': assessment.classId,
        'date': date,
      },
    );
    if (teacherMarks.isNotEmpty) {
      await ServerSync.instance.send(
        'POST',
        '/api/assessments/${assessment.id}/verdicts',
        body: {'studentId': studentId, 'teacherMarks': teacherMarks},
        report: false,
      );
    }
  }

  /// Records a single manual score (schools that mark on paper). Writes the
  /// submission to the local store first, then mirrors it to the API — the
  /// offline outbox replays the write if there is no connection.
  Future<void> recordScore({
    required Assessment assessment,
    required String studentId,
    double? score,
    bool absent = false,
    String remark = '',
    bool override = false,
  }) async {
    final subs = await _store.loadSubmissions();
    final existing = subs.where((s) =>
        s.assessmentId == assessment.id && s.studentId == studentId);
    final id = existing.isNotEmpty
        ? existing.first.id
        : 'SUB-${DateTime.now().millisecondsSinceEpoch}';
    final date = existing.isNotEmpty && existing.first.date.isNotEmpty
        ? existing.first.date
        : _today();
    final sub = AssessmentSubmission(
      id: id,
      assessmentId: assessment.id,
      studentId: studentId,
      classId: assessment.classId,
      date: date,
      answers: const {},
      teacherMarks: const {},
      earned: absent ? 0 : (score ?? 0),
      source: SubmissionSource.manual,
      remark: remark,
      absent: absent,
    );
    subs.removeWhere((s) =>
        s.assessmentId == assessment.id && s.studentId == studentId);
    await _store.saveSubmissions([...subs, sub]);

    await ServerSync.instance.send(
      'PUT',
      '/api/assessments/${assessment.id}/scores/$studentId',
      body: {
        'absent': absent,
        if (!absent && score != null) 'score': score,
        if (remark.isNotEmpty) 'remark': remark,
        if (override) 'override': true,
      },
    );
  }

  /// Records many manual scores in one batch. [rows] is the confirmed bulk
  /// payload (see [scorePayload] in manual_scores/score_io.dart): each element
  /// is `{studentId, absent, score?, remark?}`.
  Future<void> bulkRecordScores({
    required Assessment assessment,
    required List<Map<String, dynamic>> rows,
    bool override = false,
  }) async {
    final subs = await _store.loadSubmissions();
    for (final row in rows) {
      final studentId = row['studentId'] as String;
      final absent = (row['absent'] ?? false) as bool;
      final score = (row['score'] as num?)?.toDouble();
      final remark = (row['remark'] ?? '') as String;
      final existing = subs.where((s) =>
          s.assessmentId == assessment.id && s.studentId == studentId);
      final id = existing.isNotEmpty
          ? existing.first.id
          : 'SUB-${DateTime.now().microsecondsSinceEpoch}-$studentId';
      subs
        ..removeWhere((s) =>
            s.assessmentId == assessment.id && s.studentId == studentId)
        ..add(AssessmentSubmission(
          id: id,
          assessmentId: assessment.id,
          studentId: studentId,
          classId: assessment.classId,
          date: _today(),
          answers: const {},
          teacherMarks: const {},
          earned: absent ? 0 : (score ?? 0),
          source: SubmissionSource.manual,
          remark: remark,
          absent: absent,
        ));
    }
    await _store.saveSubmissions(subs);

    await ServerSync.instance.send(
      'POST',
      '/api/assessments/${assessment.id}/scores/bulk',
      body: override ? {'override': true, 'scores': rows} : rows,
    );
  }

  Future<List<({Assessment assessment, AssessmentSubmission? submission})>>
      resultsForStudent(String studentId) async {
    final assessments = await _store.loadAssessments();
    final subs = await _store.loadSubmissions();
    final out =
        <({Assessment assessment, AssessmentSubmission? submission})>[];
    for (final a in assessments) {
      AssessmentSubmission? match;
      for (final s in subs) {
        if (s.assessmentId == a.id && s.studentId == studentId) {
          match = s;
          break;
        }
      }
      out.add((assessment: a, submission: match));
    }
    return out;
  }

  List<Question> blueprintPick({
    required List<Question> from,
    String? topic,
    String? subjectId,
    int count = 5,
  }) {
    var pool = from.where((q) =>
        (subjectId == null || q.subjectId == subjectId) &&
        (topic == null || q.topic == topic)).toList();
    if (pool.isEmpty) {
      pool = from
          .where((q) => subjectId == null || q.subjectId == subjectId)
          .toList();
    }
    pool.shuffle();
    return pool.take(count).toList();
  }

  String _today() {
    final d = DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}