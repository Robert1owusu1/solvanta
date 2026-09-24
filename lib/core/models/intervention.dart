enum InterventionStatus {
  open('Open'),
  inProgress('In progress'),
  completed('Completed'),
  cancelled('Cancelled');

  const InterventionStatus(this.label);

  final String label;

  static InterventionStatus fromKey(String key) => InterventionStatus.values
      .firstWhere((s) => s.name == key, orElse: () => InterventionStatus.open);
}

class Intervention {
  final String id;
  final String studentId;
  final String topic;
  final String action;
  final String assignedBy;
  final String createdDate;
  final InterventionStatus status;
  final String? reassessmentAssessmentId;

  const Intervention({
    required this.id,
    required this.studentId,
    required this.topic,
    required this.action,
    required this.assignedBy,
    required this.createdDate,
    this.status = InterventionStatus.open,
    this.reassessmentAssessmentId,
  });

  Intervention copyWith({
    InterventionStatus? status,
    String? reassessmentAssessmentId,
  }) =>
      Intervention(
        id: id,
        studentId: studentId,
        topic: topic,
        action: action,
        assignedBy: assignedBy,
        createdDate: createdDate,
        status: status ?? this.status,
        reassessmentAssessmentId:
            reassessmentAssessmentId ?? this.reassessmentAssessmentId,
      );

  factory Intervention.fromJson(Map<String, dynamic> json) => Intervention(
        id: json['id'] as String,
        studentId: json['studentId'] as String,
        topic: (json['topic'] ?? '') as String,
        action: (json['action'] ?? '') as String,
        assignedBy: (json['assignedBy'] ?? '') as String,
        createdDate: (json['createdDate'] ?? '') as String,
        status: InterventionStatus.fromKey(json['status'] as String),
        reassessmentAssessmentId:
            json['reassessmentAssessmentId'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'studentId': studentId,
        'topic': topic,
        'action': action,
        'assignedBy': assignedBy,
        'createdDate': createdDate,
        'status': status.name,
        'reassessmentAssessmentId': reassessmentAssessmentId,
      };
}