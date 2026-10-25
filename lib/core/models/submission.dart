import 'question.dart';

class AssessmentSubmission {
  final String id;
  final String assessmentId;
  final String studentId;
  final String classId;
  final String date;
  final Map<String, String> answers;
  final Map<String, double> teacherMarks;
  final double earned;
  final String? markingSchemeId;
  final int? markingSchemeVersion;

  const AssessmentSubmission({
    required this.id,
    required this.assessmentId,
    required this.studentId,
    required this.classId,
    required this.date,
    required this.answers,
    required this.teacherMarks,
    required this.earned,
    this.markingSchemeId,
    this.markingSchemeVersion,
  });

  static const empty = AssessmentSubmission(
    id: '',
    assessmentId: '',
    studentId: '',
    classId: '',
    date: '',
    answers: {},
    teacherMarks: {},
    earned: 0,
  );

  factory AssessmentSubmission.fromJson(Map<String, dynamic> json) =>
      AssessmentSubmission(
        id: json['id'] as String,
        assessmentId: json['assessmentId'] as String,
        studentId: json['studentId'] as String,
        classId: json['classId'] as String,
        date: (json['date'] ?? '') as String,
        answers: ((json['answers'] ?? const {}) as Map)
            .map((k, v) => MapEntry(k as String, v as String)),
        teacherMarks:
            ((json['teacherMarks'] ?? const {}) as Map).map(
          (k, v) => MapEntry(k as String, ((v as num).toDouble())),
        ),
        earned: ((json['earned'] ?? 0) as num).toDouble(),
        markingSchemeId: json['markingSchemeId'] as String?,
        markingSchemeVersion: (json['markingSchemeVersion'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'assessmentId': assessmentId,
        'studentId': studentId,
        'classId': classId,
        'date': date,
        'answers': answers,
        'teacherMarks': teacherMarks,
        'earned': earned,
        if (markingSchemeId != null) 'markingSchemeId': markingSchemeId,
        if (markingSchemeVersion != null) 'markingSchemeVersion': markingSchemeVersion,
      };
}

double computeEarned(
  List<Question> questions,
  Map<String, String> answers,
  Map<String, double> teacherMarks,
) {
  var total = 0.0;
  for (final q in questions) {
    if (q.isObjective) {
      final a = answers[q.id]?.trim().toLowerCase() ?? '';
      if (a.isNotEmpty && a == q.correctAnswer.trim().toLowerCase()) {
        total += q.marks;
      }
    } else {
      total += teacherMarks[q.id] ?? 0;
    }
  }
  return total;
}