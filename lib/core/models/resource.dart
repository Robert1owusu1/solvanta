class ResourceItem {
  final String id;
  final String subjectId;
  final String classId;
  final String kind;
  final String title;
  final String body;

  const ResourceItem({
    required this.id,
    required this.subjectId,
    required this.classId,
    required this.kind,
    required this.title,
    required this.body,
  });

  factory ResourceItem.fromJson(Map<String, dynamic> json) => ResourceItem(
        id: json['id'] as String,
        subjectId: json['subjectId'] as String,
        classId: json['classId'] as String,
        kind: (json['kind'] ?? 'notes') as String,
        title: json['title'] as String,
        body: (json['body'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'subjectId': subjectId,
        'classId': classId,
        'kind': kind,
        'title': title,
        'body': body,
      };
}

// Tint per kind comes from the SOLVANTA navy ramp + gold accent
// (decorative category colors, never meaningful). Values mirror
// AppTheme.navy900 / navy700 / navy500 / gold — this file stays pure Dart,
// so the ramp is expressed as raw ARGB ints here.
const kResourceKinds = {
  'notes': ('Class notes', resourceIconNotes, 0xff1B3B6F),
  'video': ('Watch video', resourceIconVideo, 0xff2E5C9A),
  'worksheet': ('Practice worksheet', resourceIconWorksheet, 0xff47719C),
  'lessonPlan': ('Lesson plan', resourceIconLessonPlan, 0xffE3A008),
};

const resourceIconNotes = 1;
const resourceIconVideo = 2;
const resourceIconWorksheet = 3;
const resourceIconLessonPlan = 4;