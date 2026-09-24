class Assignment {
  final String id;
  final String classId;
  final String subjectId;
  final String title;
  final String instructions;
  final String deadline;
  final String createdBy;
  final String createdAt;
  final List<String> completedBy;

  const Assignment({
    required this.id,
    required this.classId,
    required this.subjectId,
    required this.title,
    required this.instructions,
    required this.deadline,
    required this.createdBy,
    required this.createdAt,
    this.completedBy = const [],
  });

  Assignment copyWith({List<String>? completedBy}) => Assignment(
        id: id,
        classId: classId,
        subjectId: subjectId,
        title: title,
        instructions: instructions,
        deadline: deadline,
        createdBy: createdBy,
        createdAt: createdAt,
        completedBy: completedBy ?? this.completedBy,
      );

  factory Assignment.fromJson(Map<String, dynamic> json) => Assignment(
        id: json['id'] as String,
        classId: json['classId'] as String,
        subjectId: json['subjectId'] as String,
        title: json['title'] as String,
        instructions: (json['instructions'] ?? '') as String,
        deadline: (json['deadline'] ?? '') as String,
        createdBy: (json['createdBy'] ?? '') as String,
        createdAt: (json['createdAt'] ?? '') as String,
        completedBy: ((json['completedBy'] ?? const []) as List).cast<String>(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'classId': classId,
        'subjectId': subjectId,
        'title': title,
        'instructions': instructions,
        'deadline': deadline,
        'createdBy': createdBy,
        'createdAt': createdAt,
        'completedBy': completedBy,
      };
}