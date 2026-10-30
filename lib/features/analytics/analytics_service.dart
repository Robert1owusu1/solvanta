import '../../core/models/assessment.dart';
import '../../core/models/grading.dart';
import '../../core/models/student.dart';
import '../../core/models/submission.dart';

String gradeLetter(double percent) {
  if (percent >= 85) return 'A';
  if (percent >= 70) return 'B';
  if (percent >= 60) return 'C';
  if (percent >= 50) return 'D';
  return 'F';
}

class QuestionPerformance {
  final Assessment assessment;
  final String questionId;
  final String topic;
  final String cognitiveLevel;
  final String subjectId;
  final double marks;
  final int attempts;
  final double correctRate;

  QuestionPerformance({
    required this.assessment,
    required this.questionId,
    required this.topic,
    required this.cognitiveLevel,
    required this.subjectId,
    required this.marks,
    required this.attempts,
    required this.correctRate,
  });

  double get gap => 1 - correctRate;
}

class StudentAlert {
  final Student student;
  final double average;
  final String grade;
  final String suggestedIntervention;

  const StudentAlert({
    required this.student,
    required this.average,
    required this.grade,
    required this.suggestedIntervention,
  });
}

String interventionFor(QuestionPerformance gap) {
  if (gap.attempts == 0) {
    return 'Unattempted — schedule the assessment';
  }
  if (gap.correctRate < 0.3) {
    return 'Re-teach "${gap.topic}" in class; small-group support';
  }
  if (gap.correctRate < 0.6) {
    return 'Targeted practice on "${gap.topic}" (${gap.cognitiveLevel} level)';
  }
  return 'Monitor — revision sheet for "${gap.topic}"';
}

/// Section 27-29: learning analytics, gap detection and at-risk alerts.
class ClassPerformance {
  final List<Assessment> assessments;
  final List<AssessmentSubmission> subs;
  final List<Student> students;

  ClassPerformance({
    required this.assessments,
    required this.subs,
    required this.students,
  });

  List<AssessmentSubmission> _for(String assessmentId) =>
      subs.where((s) => s.assessmentId == assessmentId).toList();

  Assessment? _assessment(String id) {
    for (final a in assessments) {
      if (a.id == id) return a;
    }
    return null;
  }

  double averageFor(Assessment a) {
    final list = _for(a.id);
    if (list.isEmpty || a.totalMarks <= 0) return 0;
    return list.map((s) => s.earned / a.totalMarks).reduce((x, y) => x + y) /
        list.length;
  }

  double subjectAverage(String subjectId) {
    final rel = assessments.where((a) => a.subjectId == subjectId).toList();
    var earned = 0.0, possible = 0.0;
    for (final a in rel) {
      for (final s in _for(a.id)) {
        earned += s.earned;
        possible += a.totalMarks;
      }
    }
    return possible > 0 ? earned / possible : 0;
  }

  double classAverage() {
    var earned = 0.0, possible = 0.0;
    for (final a in assessments) {
      for (final s in _for(a.id)) {
        earned += s.earned;
        possible += a.totalMarks;
      }
    }
    return possible > 0 ? earned / possible : 0;
  }

  /// Papers per grade, best grade first, on the school's scheme for the
  /// assessment's class (1–9, A–F…).
  Map<String, int> distributionFor(Assessment a) {
    final scheme = SchoolGrading.current.schemeFor(a.classId);
    final out = {for (final b in scheme.bands) b.grade: 0};
    for (final s in _for(a.id)) {
      final pct = a.totalMarks > 0 ? 100 * s.earned / a.totalMarks : 0.0;
      final g = scheme.bandFor(pct).grade;
      out[g] = out[g]! + 1;
    }
    return out;
  }

  List<QuestionPerformance> gapsFor(Assessment a) {
    final list = _for(a.id);
    if (list.isEmpty) return const [];
    final out = <QuestionPerformance>[];
    for (final q in a.questions) {
      var correct = 0;
      for (final sub in list) {
        final ans = sub.answers[q.id]?.trim().toLowerCase() ?? '';
        if (q.isObjective) {
          if (ans.isNotEmpty &&
              ans == q.correctAnswer.trim().toLowerCase()) {
            correct++;
          }
        } else {
          final m = sub.teacherMarks[q.id] ?? 0;
          if (m >= q.marks * 0.8) correct++;
        }
      }
      out.add(QuestionPerformance(
        assessment: a,
        questionId: q.id,
        topic: q.topic,
        cognitiveLevel: q.cognitiveLevel,
        subjectId: a.subjectId,
        marks: q.marks,
        attempts: list.length,
        correctRate: correct / list.length,
      ));
    }
    out.sort((x, y) => y.gap.compareTo(x.gap));
    return out;
  }

  List<StudentAlert> atRisk({double threshold = 50}) {
    final out = <StudentAlert>[];
    for (final s in students) {
      final mine =
          subs.where((x) => x.studentId == s.id && x.classId == s.classId);
      if (mine.isEmpty) continue;
      var earned = 0.0, possible = 0.0;
      for (final m in mine) {
        final a = _assessment(m.assessmentId);
        if (a == null) continue;
        earned += m.earned;
        possible += a.totalMarks;
      }
      final pct = possible > 0 ? 100 * earned / possible : 0.0;
      if (pct < threshold) {
        out.add(StudentAlert(
          student: s,
          average: pct,
          grade: schoolGrade(pct, s.classId),
          suggestedIntervention: 'Re-teach & practice on '
              '${_weakTopic(s) ?? 'core topics'}; reassess in 2 weeks',
        ));
      }
    }
    out.sort((a, b) => a.average.compareTo(b.average));
    return out;
  }

  String? _weakTopic(Student student) {
    final incorrect = <String, int>{};
    for (final sub in subs.where((x) => x.studentId == student.id)) {
      final a = _assessment(sub.assessmentId);
      if (a == null) continue;
      for (final q in a.questions) {
        final ans = (sub.answers[q.id] ?? '').trim().toLowerCase();
        final isCorrect = q.isObjective
            ? ans.isNotEmpty && ans == q.correctAnswer.trim().toLowerCase()
            : (sub.teacherMarks[q.id] ?? 0) >= q.marks * 0.8;
        if (!isCorrect) {
          incorrect[q.topic] = (incorrect[q.topic] ?? 0) + 1;
        }
      }
    }
    if (incorrect.isEmpty) return null;
    final worst = incorrect.entries.reduce((a, b) =>
        a.value >= b.value ? a : b);
    return worst.key;
  }
}