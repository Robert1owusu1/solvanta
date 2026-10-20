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