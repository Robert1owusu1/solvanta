enum NotificationKind {
  gate('Gate'),
  attendance('Attendance'),
  assessment('Assessment'),
  marking('Marking'),
  intervention('Intervention'),
  message('Message'),
  assignment('Assignment'),
  announcement('Announcement'),
  system('System');

  const NotificationKind(this.label);

  final String label;

  static NotificationKind fromKey(String key) => NotificationKind.values
      .firstWhere((k) => k.name == key, orElse: () => NotificationKind.system);
}

class AppNotification {
  final String id;
  final NotificationKind kind;
  final String title;
  final String body;
  final String timestamp;
  final String? studentId;
  final String? userId; // direct target; null = school-wide
  final bool read;

  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.timestamp,
    this.studentId,
    this.userId,
    this.read = false,
  });

  AppNotification copyWith({bool? read}) => AppNotification(
        id: id,
        kind: kind,
        title: title,
        body: body,
        timestamp: timestamp,
        studentId: studentId,
        userId: userId,
        read: read ?? this.read,
      );

  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      AppNotification(
        id: json['id'] as String,
        kind: NotificationKind.fromKey(json['kind'] as String),
        title: json['title'] as String,
        body: (json['body'] ?? '') as String,
        timestamp: (json['timestamp'] ?? '') as String,
        studentId: json['studentId'] as String?,
        userId: json['userId'] as String?,
        read: (json['read'] ?? false) as bool,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'body': body,
        'timestamp': timestamp,
        'studentId': studentId,
        'userId': userId,
        'read': read,
      };
}