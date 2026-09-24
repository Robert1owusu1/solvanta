class AuditEntry {
  final String id;
  final String action; // e.g. attendance.correction, mark.override, student.transfer
  final String actor;
  final String target; // student id or class/assessment reference
  final String detail;
  final String timestamp;
  final String? reason;

  const AuditEntry({
    required this.id,
    required this.action,
    required this.actor,
    required this.target,
    required this.detail,
    required this.timestamp,
    this.reason,
  });

  factory AuditEntry.fromJson(Map<String, dynamic> json) => AuditEntry(
        id: json['id'] as String,
        action: json['action'] as String,
        actor: (json['actor'] ?? '') as String,
        target: (json['target'] ?? '') as String,
        detail: (json['detail'] ?? '') as String,
        timestamp: (json['timestamp'] ?? '') as String,
        reason: json['reason'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'action': action,
        'actor': actor,
        'target': target,
        'detail': detail,
        'timestamp': timestamp,
        'reason': reason,
      };
}