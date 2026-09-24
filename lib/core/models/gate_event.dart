enum GateEventType {
  arrival('Arrival verified'),
  departure('Departure verified'),
  pickupAuthorized('Pickup authorized'),
  unauthorizedPickup('Unauthorized pickup alert'),
  earlyDeparture('Early departure');

  const GateEventType(this.label);

  final String label;

  static GateEventType fromKey(String key) => GateEventType.values
      .firstWhere((e) => e.name == key, orElse: () => GateEventType.arrival);
}

class GateEvent {
  final String id;
  final String studentId;
  final GateEventType type;
  final String time;
  final String date;
  final String reporter;
  final String? person;
  final String detail;

  const GateEvent({
    required this.id,
    required this.studentId,
    required this.type,
    required this.time,
    required this.date,
    required this.reporter,
    required this.detail,
    this.person,
  });

  factory GateEvent.fromJson(Map<String, dynamic> json) => GateEvent(
        id: json['id'] as String,
        studentId: json['studentId'] as String,
        type: GateEventType.fromKey(json['type'] as String),
        time: (json['time'] ?? '') as String,
        date: (json['date'] ?? '') as String,
        reporter: (json['reporter'] ?? '') as String,
        person: json['person'] as String?,
        detail: (json['detail'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'studentId': studentId,
        'type': type.name,
        'time': time,
        'date': date,
        'reporter': reporter,
        'person': person,
        'detail': detail,
      };
}