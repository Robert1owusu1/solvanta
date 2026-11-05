/// One cover/substitution decision: on [date], the absent teacher's timetabled
/// lesson is either assigned to a substitute or left open for one to be found.
class CoverAssignment {
  final String id;
  final String date; // yyyy-MM-dd
  final String weekday; // Monday..Friday, derived from the date
  final String lessonId; // the LessonSlot being covered
  final String classId;
  final String subjectId;
  final String start;
  final String end;
  final String absentTeacherId;
  final String absentTeacherName;
  final String substituteTeacherId;
  final String substituteTeacherName;
  final String reason;
  final String status; // 'open' (needs a substitute) or 'assigned'

  const CoverAssignment({
    required this.id,
    required this.date,
    required this.weekday,
    required this.lessonId,
    required this.classId,
    required this.subjectId,
    required this.start,
    required this.end,
    required this.absentTeacherId,
    required this.absentTeacherName,
    this.substituteTeacherId = '',
    this.substituteTeacherName = '',
    this.reason = '',
    this.status = 'open',
  });

  bool get isAssigned =>
      status == 'assigned' && substituteTeacherId.isNotEmpty;

  factory CoverAssignment.fromJson(Map<String, dynamic> j) => CoverAssignment(
        id: j['id'] as String,
        date: (j['date'] ?? '') as String,
        weekday: (j['weekday'] ?? '') as String,
        lessonId: (j['lessonId'] ?? '') as String,
        classId: (j['classId'] ?? '') as String,
        subjectId: (j['subjectId'] ?? '') as String,
        start: (j['start'] ?? '') as String,
        end: (j['end'] ?? '') as String,
        absentTeacherId: (j['absentTeacherId'] ?? '') as String,
        absentTeacherName: (j['absentTeacherName'] ?? '') as String,
        substituteTeacherId: (j['substituteTeacherId'] ?? '') as String,
        substituteTeacherName: (j['substituteTeacherName'] ?? '') as String,
        reason: (j['reason'] ?? '') as String,
        status: (j['status'] ?? 'open') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date,
        'weekday': weekday,
        'lessonId': lessonId,
        'classId': classId,
        'subjectId': subjectId,
        'start': start,
        'end': end,
        'absentTeacherId': absentTeacherId,
        'absentTeacherName': absentTeacherName,
        'substituteTeacherId': substituteTeacherId,
        'substituteTeacherName': substituteTeacherName,
        'reason': reason,
        'status': status,
      };

  CoverAssignment copyWith({
    String? substituteTeacherId,
    String? substituteTeacherName,
    String? reason,
    String? status,
  }) =>
      CoverAssignment(
        id: id,
        date: date,
        weekday: weekday,
        lessonId: lessonId,
        classId: classId,
        subjectId: subjectId,
        start: start,
        end: end,
        absentTeacherId: absentTeacherId,
        absentTeacherName: absentTeacherName,
        substituteTeacherId: substituteTeacherId ?? this.substituteTeacherId,
        substituteTeacherName:
            substituteTeacherName ?? this.substituteTeacherName,
        reason: reason ?? this.reason,
        status: status ?? this.status,
      );
}
