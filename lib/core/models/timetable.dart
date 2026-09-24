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

const kWeekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'];
