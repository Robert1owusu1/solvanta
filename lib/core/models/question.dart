enum QuestionType {
  mcq('Multiple choice'),
  trueFalse('True / False'),
  fillBlank('Fill in the blank'),
  shortAnswer('Short answer'),
  structured('Structured'),
  math('Mathematics'),
  essay('Essay'),
  practical('Practical / Scenario');

  const QuestionType(this.label);

  final String label;

  static QuestionType fromKey(String key) => QuestionType.values
      .firstWhere((t) => t.name == key, orElse: () => QuestionType.shortAnswer);
}

class Question {
  final String id;
  final QuestionType type;
  final String subjectId;
  final String classId;
  final String topic;
  final int difficulty;
  final String cognitiveLevel;
  final double marks;
  final String stem;
  final List<String> options;
  final String correctAnswer;
  final String explanation;
  final String markingScheme;

  const Question({
    required this.id,
    required this.type,
    required this.subjectId,
    required this.classId,
    required this.topic,
    required this.difficulty,
    required this.cognitiveLevel,
    required this.marks,
    required this.stem,
    this.options = const [],
    this.correctAnswer = '',
    this.explanation = '',
    this.markingScheme = '',
  });

  bool get isObjective =>
      type == QuestionType.mcq || type == QuestionType.trueFalse;

  factory Question.fromJson(Map<String, dynamic> json) => Question(
        id: json['id'] as String,
        type: QuestionType.fromKey(json['type'] as String),
        subjectId: json['subjectId'] as String,
        classId: json['classId'] as String,
        topic: (json['topic'] ?? '') as String,
        difficulty: (json['difficulty'] ?? 1) as int,
        cognitiveLevel: (json['cognitiveLevel'] ?? 'Knowledge') as String,
        marks: ((json['marks'] ?? 1) as num).toDouble(),
        stem: json['stem'] as String,
        options: ((json['options'] ?? const []) as List).cast<String>(),
        correctAnswer: (json['correctAnswer'] ?? '') as String,
        explanation: (json['explanation'] ?? '') as String,
        markingScheme: (json['markingScheme'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'subjectId': subjectId,
        'classId': classId,
        'topic': topic,
        'difficulty': difficulty,
        'cognitiveLevel': cognitiveLevel,
        'marks': marks,
        'stem': stem,
        'options': options,
        'correctAnswer': correctAnswer,
        'explanation': explanation,
        'markingScheme': markingScheme,
      };
}