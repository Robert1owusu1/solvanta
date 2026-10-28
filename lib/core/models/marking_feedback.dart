// Feedback reports from finalized AI-assisted marking (Phase 7). The server
// builds them only from marks a teacher reviewed and finalized; these are
// read-only views of that.

double _d(Object? v) => (v as num?)?.toDouble() ?? 0;
int _i(Object? v) => (v as num?)?.toInt() ?? 0;
String _s(Object? v) => (v as String?) ?? '';
List<Map<String, dynamic>> _list(Object? v) =>
    ((v ?? const []) as List).cast<Map<String, dynamic>>();

/// A misconception and how many times it was seen.
class CauseCount {
  const CauseCount(this.cause, this.count);
  final String cause;
  final int count;

  factory CauseCount.fromJson(Map<String, dynamic> j) => CauseCount(_s(j['cause']), _i(j['count']));
}

/// One question a student did not get full marks on.
class FeedbackQuestion {
  const FeedbackQuestion({
    required this.questionNumber,
    required this.topic,
    required this.studentAnswer,
    required this.marks,
    required this.totalMarks,
    required this.blank,
    required this.likelyMisconception,
    required this.nextStep,
    required this.nextStepSource,
    required this.teacherNote,
  });

  final int questionNumber;
  final String topic;
  final String studentAnswer;
  final double marks;
  final double totalMarks;
  final bool blank;

  /// The scheme's cause for this wrong answer; empty when it isn't known.
  final String likelyMisconception;
  final String nextStep;

  /// blank, misconception, topic or general.
  final String nextStepSource;

  /// The marker's note — sent to staff only.
  final String teacherNote;

  factory FeedbackQuestion.fromJson(Map<String, dynamic> j) => FeedbackQuestion(
        questionNumber: _i(j['questionNumber']),
        topic: _s(j['topic']),
        studentAnswer: _s(j['studentAnswer']),
        marks: _d(j['marks']),
        totalMarks: _d(j['totalMarks']),
        blank: j['blank'] == true,
        likelyMisconception: _s(j['likelyMisconception']),
        nextStep: _s(j['nextStep']),
        nextStepSource: _s(j['nextStepSource']),
        teacherNote: _s(j['teacherNote']),
      );
}

/// One finalized paper in a student's feedback.
class FeedbackPaper {
  const FeedbackPaper({
    required this.draftId,
    required this.title,
    required this.subjectId,
    required this.targetKind,
    required this.finalizedAt,
    required this.marks,
    required this.total,
    required this.percent,
    required this.grade,
    required this.questionCount,
    required this.fullMarks,
    required this.wrong,
  });

  final String draftId;
  final String title;
  final String subjectId;
  final String targetKind;
  final String finalizedAt;
  final double marks;
  final double total;
  final double percent;
  final String grade;
  final int questionCount;
  final int fullMarks;
  final List<FeedbackQuestion> wrong;

  factory FeedbackPaper.fromJson(Map<String, dynamic> j) => FeedbackPaper(
        draftId: _s(j['draftId']),
        title: _s(j['title']),
        subjectId: _s(j['subjectId']),
        targetKind: _s(j['targetKind']),
        finalizedAt: _s(j['finalizedAt']),
        marks: _d(j['marks']),
        total: _d(j['total']),
        percent: _d(j['percent']),
        grade: _s(j['grade']),
        questionCount: _i(j['questionCount']),
        fullMarks: _i(j['fullMarks']),
        wrong: _list(j['wrong']).map(FeedbackQuestion.fromJson).toList(),
      );
}

/// The per-student report.
class StudentFeedback {
  const StudentFeedback({
    required this.studentId,
    required this.studentName,
    required this.papers,
    required this.wrongQuestions,
    required this.misconceptions,
  });

  final String studentId;
  final String studentName;
  final List<FeedbackPaper> papers;
  final int wrongQuestions;
  final List<CauseCount> misconceptions;

  factory StudentFeedback.fromJson(Map<String, dynamic> j) {
    final student = (j['student'] as Map?)?.cast<String, dynamic>() ?? const {};
    final summary = (j['summary'] as Map?)?.cast<String, dynamic>() ?? const {};
    return StudentFeedback(
      studentId: _s(student['id']),
      studentName: _s(student['name']),
      papers: _list(j['papers']).map(FeedbackPaper.fromJson).toList(),
      wrongQuestions: _i(summary['wrongQuestions']),
      misconceptions: _list(summary['misconceptions']).map(CauseCount.fromJson).toList(),
    );
  }
}

/// A student who lost marks on a question.
class StudentMark {
  const StudentMark(this.studentId, this.name, this.marks);
  final String studentId;
  final String name;
  final double marks;

  factory StudentMark.fromJson(Map<String, dynamic> j) =>
      StudentMark(_s(j['studentId']), _s(j['name']), _d(j['marks']));
}

/// How the class did on one question.
class ClassQuestionStat {
  const ClassQuestionStat({
    required this.questionNumber,
    required this.topic,
    required this.totalMarks,
    required this.papers,
    required this.averageMarks,
    required this.averagePercent,
    required this.fullMarks,
    required this.zero,
    required this.blank,
    required this.struggled,
    required this.misconceptions,
    required this.belowFull,
  });

  final int questionNumber;
  final String topic;
  final double totalMarks;
  final int papers;
  final double averageMarks;
  final double averagePercent;
  final int fullMarks;
  final int zero;
  final int blank;
  final bool struggled;
  final List<CauseCount> misconceptions;
  final List<StudentMark> belowFull;

  factory ClassQuestionStat.fromJson(Map<String, dynamic> j) => ClassQuestionStat(
        questionNumber: _i(j['questionNumber']),
        topic: _s(j['topic']),
        totalMarks: _d(j['totalMarks']),
        papers: _i(j['papers']),
        averageMarks: _d(j['averageMarks']),
        averagePercent: _d(j['averagePercent']),
        fullMarks: _i(j['fullMarks']),
        zero: _i(j['zero']),
        blank: _i(j['blank']),
        struggled: j['struggled'] == true,
        misconceptions: _list(j['misconceptions']).map(CauseCount.fromJson).toList(),
        belowFull: _list(j['belowFull']).map(StudentMark.fromJson).toList(),
      );
}

/// The class aggregate for one marking scheme.
class ClassPaperReport {
  const ClassPaperReport({
    required this.schemeId,
    required this.schemeVersion,
    required this.title,
    required this.subjectId,
    required this.targetKind,
    required this.papers,
    required this.awaitingReview,
    required this.averagePercent,
    required this.questions,
    required this.hardest,
    required this.lastMarkedAt,
  });

  final String schemeId;
  final int schemeVersion;
  final String title;
  final String subjectId;
  final String targetKind;
  final int papers;
  final int awaitingReview;
  final double averagePercent;
  final List<ClassQuestionStat> questions;

  /// Question numbers the class struggled with, worst first.
  final List<int> hardest;
  final String lastMarkedAt;

  factory ClassPaperReport.fromJson(Map<String, dynamic> j) => ClassPaperReport(
        schemeId: _s(j['schemeId']),
        schemeVersion: _i(j['schemeVersion']),
        title: _s(j['title']),
        subjectId: _s(j['subjectId']),
        targetKind: _s(j['targetKind']),
        papers: _i(j['papers']),
        awaitingReview: _i(j['awaitingReview']),
        averagePercent: _d(j['averagePercent']),
        questions: _list(j['questions']).map(ClassQuestionStat.fromJson).toList(),
        hardest: ((j['hardest'] ?? const []) as List).map((e) => (e as num).toInt()).toList(),
        lastMarkedAt: _s(j['lastMarkedAt']),
      );

  ClassQuestionStat? question(int n) =>
      questions.where((q) => q.questionNumber == n).firstOrNull;
}

/// The per-class report.
class ClassFeedback {
  const ClassFeedback({
    required this.classId,
    required this.struggleThreshold,
    required this.reports,
    required this.awaitingReview,
  });

  final String classId;
  final double struggleThreshold;
  final List<ClassPaperReport> reports;

  /// Papers drafted but not yet finalized — not in any report.
  final int awaitingReview;

  factory ClassFeedback.fromJson(Map<String, dynamic> j) => ClassFeedback(
        classId: _s(j['classId']),
        struggleThreshold: _d(j['struggleThreshold']),
        reports: _list(j['reports']).map(ClassPaperReport.fromJson).toList(),
        awaitingReview: _i(j['awaitingReview']),
      );
}
