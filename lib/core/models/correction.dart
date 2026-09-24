/// A recorded correction in the Write → Mark → Feedback → Correction →
/// Practice → Reassessment cycle (doc §33).
class Correction {
  final String id;
  final String studentId;
  final String assessmentId;
  final String questionId;
  final String beforeAnswer;
  final String afterAnswer;
  final String note;
  final String date;
  final bool completed;

  const Correction({
    required this.id,
    required this.studentId,
    required this.assessmentId,
    required this.questionId,
    required this.beforeAnswer,
    required this.afterAnswer,
    required this.note,
    required this.date,
    this.completed = true,
  });

  factory Correction.fromJson(Map<String, dynamic> json) => Correction(
        id: json['id'] as String,
        studentId: json['studentId'] as String,
        assessmentId: json['assessmentId'] as String,
        questionId: json['questionId'] as String,
        beforeAnswer: (json['beforeAnswer'] ?? '') as String,
        afterAnswer: (json['afterAnswer'] ?? '') as String,
        note: (json['note'] ?? '') as String,
        date: (json['date'] ?? '') as String,
        completed: (json['completed'] ?? true) as bool,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'studentId': studentId,
        'assessmentId': assessmentId,
        'questionId': questionId,
        'beforeAnswer': beforeAnswer,
        'afterAnswer': afterAnswer,
        'note': note,
        'date': date,
        'completed': completed,
      };
}