class SafetyPack {
  final String id;
  final String title;
  final String topic;
  final String audience; // STUDENT | PARENT | TEACHER | STAFF
  final List<String> lessons;
  final List<String> quizQuestions; // true/false statements
  final List<String> quizAnswers;   // parallel bool strings

  const SafetyPack({
    required this.id,
    required this.title,
    required this.topic,
    required this.audience,
    required this.lessons,
    required this.quizQuestions,
    required this.quizAnswers,
  });

  factory SafetyPack.fromJson(Map<String, dynamic> json) => SafetyPack(
        id: json['id'] as String,
        title: json['title'] as String,
        topic: json['topic'] as String,
        audience: (json['audience'] ?? 'STUDENT') as String,
        lessons: ((json['lessons'] ?? const []) as List).cast<String>(),
        quizQuestions:
            ((json['quizQuestions'] ?? const []) as List).cast<String>(),
        quizAnswers:
            ((json['quizAnswers'] ?? const []) as List).cast<String>(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'topic': topic,
        'audience': audience,
        'lessons': lessons,
        'quizQuestions': quizQuestions,
        'quizAnswers': quizAnswers,
      };
}

class TrainingCompletion {
  final String packId;
  final String studentId;
  final String completedOn;
  final int score;
  final int total;

  const TrainingCompletion({
    required this.packId,
    required this.studentId,
    required this.completedOn,
    required this.score,
    required this.total,
  });

  factory TrainingCompletion.fromJson(Map<String, dynamic> json) =>
      TrainingCompletion(
        packId: json['packId'] as String,
        studentId: json['studentId'] as String,
        completedOn: (json['completedOn'] ?? '') as String,
        score: (json['score'] ?? 0) as int,
        total: (json['total'] ?? 0) as int,
      );

  Map<String, dynamic> toJson() => {
        'packId': packId,
        'studentId': studentId,
        'completedOn': completedOn,
        'score': score,
        'total': total,
      };
}

const kSafetyAudienceLabels = {
  'STUDENT': 'Students',
  'PARENT': 'Parents',
  'TEACHER': 'Teachers',
  'STAFF': 'Staff',
};