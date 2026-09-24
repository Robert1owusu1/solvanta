class LessonSlot {
  final String id;
  final String classId;
  final String weekday;
  final String start;
  final String end;
  final String subjectId;
  final String teacherId;

  const LessonSlot({
    required this.id,
    required this.classId,
    required this.weekday,
    required this.start,
    required this.end,
    required this.subjectId,
    required this.teacherId,
  });

  factory LessonSlot.fromJson(Map<String, dynamic> json) => LessonSlot(
        id: json['id'] as String,
        classId: json['classId'] as String,
        weekday: json['weekday'] as String,
        start: json['start'] as String,
        end: json['end'] as String,
        subjectId: json['subjectId'] as String,
        teacherId: (json['teacherId'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'classId': classId,
        'weekday': weekday,
        'start': start,
        'end': end,
        'subjectId': subjectId,
        'teacherId': teacherId,
      };

  String get blockLabel => '$start – $end';
}

class ContentResource {
  final String id;
  final String subjectId;
  final String classId;
  final String kind; // notes | video | worksheet | lessonPlan
  final String title;
  final String topic;
  final String body;
  final String addedBy;
  final String addedOn;

  const ContentResource({
    required this.id,
    required this.subjectId,
    required this.classId,
    required this.kind,
    required this.title,
    required this.topic,
    required this.body,
    required this.addedBy,
    required this.addedOn,
  });

  factory ContentResource.fromJson(Map<String, dynamic> json) =>
      ContentResource(
        id: json['id'] as String,
        subjectId: json['subjectId'] as String,
        classId: json['classId'] as String,
        kind: (json['kind'] ?? 'notes') as String,
        title: json['title'] as String,
        topic: (json['topic'] ?? '') as String,
        body: (json['body'] ?? '') as String,
        addedBy: (json['addedBy'] ?? '') as String,
        addedOn: (json['addedOn'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'subjectId': subjectId,
        'classId': classId,
        'kind': kind,
        'title': title,
        'topic': topic,
        'body': body,
        'addedBy': addedBy,
        'addedOn': addedOn,
      };
}

class SafetyModule {
  final String id;
  final String title;
  final String topic;
  final List<String> lessons; // bullet points / reading content
  final List<String> quizQuestions; // true/false statements
  final List<String> quizAnswers;

  const SafetyModule({
    required this.id,
    required this.title,
    required this.topic,
    required this.lessons,
    required this.quizQuestions,
    required this.quizAnswers,
  });

  factory SafetyModule.fromJson(Map<String, dynamic> json) => SafetyModule(
        id: json['id'] as String,
        title: json['title'] as String,
        topic: json['topic'] as String,
        lessons: ((json['lessons'] ?? const []) as List).cast<String>(),
        quizQuestions:
            ((json['quizQuestions'] ?? const []) as List).cast<String>(),
        quizAnswers: ((json['quizAnswers'] ?? const []) as List).cast<String>(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'topic': topic,
        'lessons': lessons,
        'quizQuestions': quizQuestions,
        'quizAnswers': quizAnswers,
      };
}