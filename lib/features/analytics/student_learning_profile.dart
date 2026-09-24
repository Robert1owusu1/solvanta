import '../../core/models/assessment.dart';
import '../../core/models/intervention.dart';
import '../../core/models/student.dart';
import '../../core/models/submission.dart';
import 'error_pattern_engine.dart';

class TopicMastery {
  final String subjectId;
  final String topic;
  final int attempts;
  final double correctRate;
  final double previousCorrectRate;

  const TopicMastery({
    required this.subjectId,
    required this.topic,
    required this.attempts,
    required this.correctRate,
    this.previousCorrectRate = -1,
  });

  bool get improving =>
      previousCorrectRate >= 0 && correctRate >= previousCorrectRate;
  bool get declining =>
      previousCorrectRate >= 0 && correctRate < previousCorrectRate;
}

class StudentLearningProfile {
  final Student student;
  final List<TopicMastery> topics;
  final List<ErrorPattern> errorPatterns;
  final List<Intervention> interventions;

  const StudentLearningProfile({
    required this.student,
    required this.topics,
    required this.errorPatterns,
    required this.interventions,
  });
}

class LearningProfileBuilder {
  final List<Assessment> assessments;
  final List<AssessmentSubmission> subs;
  final List<Intervention> interventions;

  LearningProfileBuilder({
    required this.assessments,
    required this.subs,
    required this.interventions,
  });

  StudentLearningProfile build(Student student) {
    final mine = subs.where((s) => s.studentId == student.id).toList();
    final byTopic = <String, _TopicAcc>{};
    final analyzer = ErrorPatternAnalyzer();

    for (final sub in mine) {
      final assessment =
          assessments.where((a) => a.id == sub.assessmentId).firstOrNull;
      if (assessment == null) continue;
      for (final q in assessment.questions) {
        final acc = byTopic.putIfAbsent(q.topic, () => _TopicAcc(
            subjectId: assessment.subjectId, topic: q.topic));
        final answer = (sub.answers[q.id] ?? '').trim();
        acc.attempts++;
        final isCorrect = q.isObjective
            ? answer.isNotEmpty &&
                answer.toLowerCase() == q.correctAnswer.trim().toLowerCase()
            : (sub.teacherMarks[q.id] ?? 0) >= q.marks * 0.8;
        if (isCorrect) acc.correct++;
      }
      for (final p in analyzer.analyze(
          questions: assessment.questions, sub: sub)) {
        _patterns[p.label] = _patterns[p.label] ?? 0;
        _patterns[p.label] = _patterns[p.label]! + p.count;
      }
    }

    final topics = [
      for (final acc in byTopic.values)
        TopicMastery(
          subjectId: acc.subjectId,
          topic: acc.topic,
          attempts: acc.attempts,
          correctRate: acc.attempts == 0 ? 0 : acc.correct / acc.attempts,
        ),
    ]..sort((a, b) => (a.correctRate).compareTo(b.correctRate));

    final studentInterventions =
        interventions.where((i) => i.studentId == student.id).toList();

    return StudentLearningProfile(
      student: student,
      topics: topics,
      errorPatterns: [
        for (final e in _patterns.entries)
          ErrorPattern(label: e.key, count: e.value, detail: ''),
      ]..sort((a, b) => b.count.compareTo(a.count)),
      interventions: studentInterventions,
    );
  }

  final _patterns = <String, int>{};
}

class _TopicAcc {
  final String subjectId;
  final String topic;
  int attempts = 0;
  int correct = 0;

  _TopicAcc({required this.subjectId, required this.topic});
}