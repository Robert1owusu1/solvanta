import 'question.dart';

/// Status of an AI question-generation request (doc §43).
enum QGenStatus {
  pending('Pending'),
  generated('Drafts ready'),
  published('Published'),
  rejected('Rejected');

  const QGenStatus(this.label);

  final String label;

  static QGenStatus fromKey(String key) => QGenStatus.values
      .firstWhere((s) => s.name == key, orElse: () => QGenStatus.pending);
}

/// A teacher's request to have the AI question engine produce draft
/// questions; drafts are reviewed and approved before entering the bank.
class QuestionGenRequest {
  final String id;
  final String requesterId;
  final String requesterName;
  final String subjectId;
  final String topic;
  final QuestionType type;
  final int count;
  final String priority;
  final String classId;
  final String createdAt;
  final String? publishedAt;
  final QGenStatus status;
  final List<Question> drafts;

  const QuestionGenRequest({
    required this.id,
    required this.requesterId,
    required this.requesterName,
    required this.subjectId,
    required this.topic,
    required this.type,
    required this.count,
    required this.priority,
    required this.classId,
    required this.createdAt,
    this.publishedAt,
    this.status = QGenStatus.pending,
    this.drafts = const [],
  });

  QuestionGenRequest copyWith({
    QGenStatus? status,
    List<Question>? drafts,
    String? publishedAt,
  }) =>
      QuestionGenRequest(
        id: id,
        requesterId: requesterId,
        requesterName: requesterName,
        subjectId: subjectId,
        topic: topic,
        type: type,
        count: count,
        priority: priority,
        classId: classId,
        createdAt: createdAt,
        publishedAt: publishedAt ?? this.publishedAt,
        status: status ?? this.status,
        drafts: drafts ?? this.drafts,
      );

  factory QuestionGenRequest.fromJson(Map<String, dynamic> json) =>
      QuestionGenRequest(
        id: json['id'] as String,
        requesterId: json['requesterId'] as String,
        requesterName: json['requesterName'] as String,
        subjectId: json['subjectId'] as String,
        topic: json['topic'] as String,
        type: QuestionType.fromKey(json['type'] as String),
        count: (json['count'] ?? 5) as int,
        priority: (json['priority'] ?? 'Normal') as String,
        classId: (json['classId'] ?? '') as String,
        createdAt: json['createdAt'] as String,
        publishedAt: json['publishedAt'] as String?,
        status: QGenStatus.fromKey(json['status'] as String),
        drafts: ((json['drafts'] ?? const []) as List)
            .map((e) => Question.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'requesterId': requesterId,
        'requesterName': requesterName,
        'subjectId': subjectId,
        'topic': topic,
        'type': type.name,
        'count': count,
        'priority': priority,
        'classId': classId,
        'createdAt': createdAt,
        'publishedAt': publishedAt,
        'status': status.name,
        'drafts': drafts.map((e) => e.toJson()).toList(),
      };
}