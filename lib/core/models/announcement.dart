/// Who an announcement is aimed at (doc §40).
enum AnnouncementAudience {
  school('Whole school'),
  classes('Selected classes'),
  emergency('Emergency');

  const AnnouncementAudience(this.label);

  final String label;

  static AnnouncementAudience fromKey(String key) =>
      AnnouncementAudience.values.firstWhere(
        (a) => a.name == key,
        orElse: () => AnnouncementAudience.school,
      );
}

/// A school, class or emergency announcement (doc §40). Announcements are
/// published to the whole school or a single class and are threaded into
/// both the Messages view and the Notifications inbox.
class Announcement {
  final String id;
  final String title;
  final String body;
  final AnnouncementAudience audience;
  final String? targetClassId; // required when audience == classes
  final String authorId;
  final String authorName;
  final String timestamp; // 'yyyy-MM-dd HH:MM'

  const Announcement({
    required this.id,
    required this.title,
    required this.body,
    required this.audience,
    this.targetClassId,
    required this.authorId,
    required this.authorName,
    required this.timestamp,
  });

  factory Announcement.fromJson(Map<String, dynamic> json) => Announcement(
        id: json['id'] as String,
        title: json['title'] as String,
        body: (json['body'] ?? '') as String,
        audience: AnnouncementAudience.fromKey(json['audience'] as String),
        targetClassId: json['targetClassId'] as String?,
        authorId: (json['authorId'] ?? '') as String,
        authorName: (json['authorName'] ?? 'Unknown') as String,
        timestamp: (json['timestamp'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'audience': audience.name,
        'targetClassId': targetClassId,
        'authorId': authorId,
        'authorName': authorName,
        'timestamp': timestamp,
      };

  bool get isEmergency => audience == AnnouncementAudience.emergency;
}