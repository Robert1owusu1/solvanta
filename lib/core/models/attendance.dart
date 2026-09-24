enum AttendanceStatus {
  present('Present'),
  late('Late'),
  absent('Absent'),
  excused('Excused');

  const AttendanceStatus(this.label);

  final String label;

  static AttendanceStatus fromKey(String key) => AttendanceStatus.values
      .firstWhere((s) => s.name == key,
          orElse: () => AttendanceStatus.absent);
}

class AttendanceRecord {
  final String id;
  final String studentId;
  final String classId;
  final String date;
  final AttendanceStatus status;
  final String? checkIn;
  final String? checkOut;

  const AttendanceRecord({
    required this.id,
    required this.studentId,
    required this.classId,
    required this.date,
    required this.status,
    this.checkIn,
    this.checkOut,
  });

  factory AttendanceRecord.fromJson(Map<String, dynamic> json) =>
      AttendanceRecord(
        id: json['id'] as String,
        studentId: json['studentId'] as String,
        classId: json['classId'] as String,
        date: json['date'] as String,
        status: AttendanceStatus.fromKey(json['status'] as String),
        checkIn: json['checkIn'] as String?,
        checkOut: json['checkOut'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'studentId': studentId,
        'classId': classId,
        'date': date,
        'status': status.name,
        'checkIn': checkIn,
        'checkOut': checkOut,
      };
}