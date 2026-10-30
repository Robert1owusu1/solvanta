/// A meeting with a pupil's family, usually because their report card asked
/// for one (mirrors the server's `parent_meetings` records).
enum MeetingStatus {
  requested('Requested'),
  scheduled('Booked'),
  held('Held'),
  cancelled('Cancelled');

  const MeetingStatus(this.label);

  final String label;

  bool get open => this == requested || this == scheduled;
}

class ParentMeeting {
  final String id;
  final String studentId;
  final String classId;
  final String year;
  final String term;

  /// Why the school wants to meet (`Year average 41.2, below 45`).
  final String reason;
  final MeetingStatus status;

  /// `yyyy-MM-dd HH:mm` once booked.
  final String scheduledFor;
  final String place;

  /// What was agreed, once held.
  final String outcome;
  final String requestedBy;

  const ParentMeeting({
    required this.id,
    required this.studentId,
    required this.classId,
    required this.year,
    required this.term,
    required this.reason,
    this.status = MeetingStatus.requested,
    this.scheduledFor = '',
    this.place = '',
    this.outcome = '',
    this.requestedBy = '',
  });

  factory ParentMeeting.fromJson(Map<String, dynamic> j) => ParentMeeting(
        id: j['id'] as String,
        studentId: (j['studentId'] ?? '') as String,
        classId: (j['classId'] ?? '') as String,
        year: (j['year'] ?? '') as String,
        term: (j['term'] ?? '') as String,
        reason: (j['reason'] ?? '') as String,
        status: MeetingStatus.values.firstWhere((s) => s.name == j['status'],
            orElse: () => MeetingStatus.requested),
        scheduledFor: (j['scheduledFor'] ?? '') as String,
        place: (j['place'] ?? '') as String,
        outcome: (j['outcome'] ?? '') as String,
        requestedBy: (j['requestedBy'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'studentId': studentId,
        'classId': classId,
        'year': year,
        'term': term,
        'reason': reason,
        'status': status.name,
        'scheduledFor': scheduledFor,
        'place': place,
        'outcome': outcome,
        'requestedBy': requestedBy,
      };

  ParentMeeting copyWith({
    MeetingStatus? status,
    String? scheduledFor,
    String? place,
    String? outcome,
  }) =>
      ParentMeeting(
        id: id,
        studentId: studentId,
        classId: classId,
        year: year,
        term: term,
        reason: reason,
        status: status ?? this.status,
        scheduledFor: scheduledFor ?? this.scheduledFor,
        place: place ?? this.place,
        outcome: outcome ?? this.outcome,
        requestedBy: requestedBy,
      );
}
