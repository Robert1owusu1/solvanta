import 'question.dart';

enum AssessmentType {
  exercise('Exercise'),
  homework('Homework'),
  quiz('Quiz'),
  classTest('Class Test'),
  midTerm('Mid-Term Examination'),
  endTerm('End-of-Term Examination'),
  mock('Mock Examination'),
  diagnostic('Diagnostic Assessment'),
  remedial('Remedial Assessment'),
  vacation('Vacation Exercise');

  const AssessmentType(this.label);

  final String label;

  static AssessmentType fromKey(String key) => AssessmentType.values
      .firstWhere((t) => t.name == key, orElse: () => AssessmentType.exercise);
}

class Assessment {
  final String id;
  final String title;
  final AssessmentType type;
  final String subjectId;
  final String classId;
  final String date;
  final String createdBy;
  final List<Question> questions;

  const Assessment({
    required this.id,
    required this.title,
    required this.type,
    required this.subjectId,
    required this.classId,
    required this.date,
    required this.createdBy,
    required this.questions,
  });

  double get totalMarks =>
      questions.fold(0, (sum, q) => sum + q.marks);

  factory Assessment.fromJson(Map<String, dynamic> json) => Assessment(
        id: json['id'] as String,
        title: json['title'] as String,
        type: AssessmentType.fromKey(json['type'] as String),
        subjectId: json['subjectId'] as String,
        classId: json['classId'] as String,
        date: (json['date'] ?? '') as String,
        createdBy: (json['createdBy'] ?? '') as String,
        questions: ((json['questions'] ?? const []) as List)
            .map((e) => Question.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'type': type.name,
        'subjectId': subjectId,
        'classId': classId,
        'date': date,
        'createdBy': createdBy,
        'questions': questions.map((e) => e.toJson()).toList(),
      };
}