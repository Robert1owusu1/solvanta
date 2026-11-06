import 'class_ladder.dart';
import 'class_room.dart';

class Person {
  final String name;
  final String phone;
  final String relation;

  const Person({required this.name, required this.phone, this.relation = ''});

  factory Person.fromJson(Map<String, dynamic> json) => Person(
        name: json['name'] as String,
        phone: (json['phone'] ?? '') as String,
        relation: (json['relation'] ?? '') as String,
      );

  Map<String, dynamic> toJson() =>
      {'name': name, 'phone': phone, 'relation': relation};
}

/// A pupil's optional emergency medical record.
class StudentHealth {
  final String bloodGroup;
  final List<String> allergies;
  final List<String> conditions;
  final List<String> medications;
  final List<String> immunizations;
  final String notes;

  const StudentHealth({
    this.bloodGroup = '',
    this.allergies = const [],
    this.conditions = const [],
    this.medications = const [],
    this.immunizations = const [],
    this.notes = '',
  });

  bool get isEmpty =>
      bloodGroup.isEmpty &&
      allergies.isEmpty &&
      conditions.isEmpty &&
      medications.isEmpty &&
      immunizations.isEmpty &&
      notes.isEmpty;

  static List<String> _list(dynamic v) =>
      [for (final e in (v ?? const []) as List) e as String];

  factory StudentHealth.fromJson(Map<String, dynamic> j) => StudentHealth(
        bloodGroup: (j['bloodGroup'] ?? '') as String,
        allergies: _list(j['allergies']),
        conditions: _list(j['conditions']),
        medications: _list(j['medications']),
        immunizations: _list(j['immunizations']),
        notes: (j['notes'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        if (bloodGroup.isNotEmpty) 'bloodGroup': bloodGroup,
        if (allergies.isNotEmpty) 'allergies': allergies,
        if (conditions.isNotEmpty) 'conditions': conditions,
        if (medications.isNotEmpty) 'medications': medications,
        if (immunizations.isNotEmpty) 'immunizations': immunizations,
        if (notes.isNotEmpty) 'notes': notes,
      };
}

class Student {
  final String id;
  final String firstName;
  final String lastName;
  final String gender;
  final String dateOfBirth;
  final String admissionDate;
  final String admissionNo;
  final String classId;
  final String schoolId;
  final String status; // Active | Transferred | Graduated | Leaver
  final String? parentUserId;

  /// Passport photo for the ID card and report card. Holds a data URI
  /// (`data:image/jpeg;base64,...`) or an http(s) URL; empty when none.
  final String photoUrl;

  final List<Person> guardians;
  final List<Person> emergencyContacts;
  final List<Person> authorizedPickup;
  final StudentHealth? health;

  const Student({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.gender,
    required this.dateOfBirth,
    required this.admissionDate,
    required this.admissionNo,
    required this.classId,
    required this.schoolId,
    this.status = 'Active',
    this.parentUserId,
    this.photoUrl = '',
    this.guardians = const [],
    this.emergencyContacts = const [],
    this.authorizedPickup = const [],
    this.health,
  });

  String get fullName => '$firstName $lastName';
  String get initials => firstName.isNotEmpty
      ? '${firstName[0]}${lastName.isNotEmpty ? lastName[0] : ''}'
      : '?';

  /// The class this student moves up to (same stream: JHS1A → JHS2A), or
  /// null in the final class. Pass the school's [classes] to land on a class
  /// that exists — see [nextClassId].
  String? promotedToClass([List<ClassRoom> classes = const []]) =>
      nextClassId(classId, classes);

  factory Student.fromJson(Map<String, dynamic> json) => Student(
        id: json['id'] as String,
        firstName: json['firstName'] as String,
        lastName: json['lastName'] as String,
        gender: (json['gender'] ?? '') as String,
        dateOfBirth: (json['dateOfBirth'] ?? '') as String,
        admissionDate: (json['admissionDate'] ?? '') as String,
        admissionNo: (json['admissionNo'] ?? '') as String,
        classId: json['classId'] as String,
        schoolId: (json['schoolId'] ?? 'SCH-001') as String,
        status: (json['status'] ?? 'Active') as String,
        parentUserId: json['parentUserId'] as String?,
        photoUrl: (json['photoUrl'] ?? '') as String,
        guardians: ((json['guardians'] ?? const []) as List)
            .map((e) => Person.fromJson(e as Map<String, dynamic>))
            .toList(),
        emergencyContacts: ((json['emergencyContacts'] ?? const []) as List)
            .map((e) => Person.fromJson(e as Map<String, dynamic>))
            .toList(),
        authorizedPickup: ((json['authorizedPickup'] ?? const []) as List)
            .map((e) => Person.fromJson(e as Map<String, dynamic>))
            .toList(),
        health: json['health'] is Map<String, dynamic>
            ? StudentHealth.fromJson(json['health'] as Map<String, dynamic>)
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'firstName': firstName,
        'lastName': lastName,
        'gender': gender,
        'dateOfBirth': dateOfBirth,
        'admissionDate': admissionDate,
        'admissionNo': admissionNo,
        'classId': classId,
        'schoolId': schoolId,
        'status': status,
        'parentUserId': parentUserId,
        if (photoUrl.isNotEmpty) 'photoUrl': photoUrl,
        'guardians': guardians.map((e) => e.toJson()).toList(),
        'emergencyContacts': emergencyContacts.map((e) => e.toJson()).toList(),
        'authorizedPickup': authorizedPickup.map((e) => e.toJson()).toList(),
        if (health != null && !health!.isEmpty) 'health': health!.toJson(),
      };

  Student copyWith({
    String? firstName,
    String? lastName,
    String? gender,
    String? dateOfBirth,
    String? admissionDate,
    String? admissionNo,
    String? classId,
    String? schoolId,
    String? status,
    String? parentUserId,
    String? photoUrl,
    List<Person>? guardians,
    List<Person>? emergencyContacts,
    List<Person>? authorizedPickup,
    StudentHealth? health,
  }) =>
      Student(
        id: id,
        firstName: firstName ?? this.firstName,
        lastName: lastName ?? this.lastName,
        gender: gender ?? this.gender,
        dateOfBirth: dateOfBirth ?? this.dateOfBirth,
        admissionDate: admissionDate ?? this.admissionDate,
        admissionNo: admissionNo ?? this.admissionNo,
        classId: classId ?? this.classId,
        schoolId: schoolId ?? this.schoolId,
        status: status ?? this.status,
        parentUserId: parentUserId ?? this.parentUserId,
        photoUrl: photoUrl ?? this.photoUrl,
        guardians: guardians ?? this.guardians,
        emergencyContacts: emergencyContacts ?? this.emergencyContacts,
        authorizedPickup: authorizedPickup ?? this.authorizedPickup,
        health: health ?? this.health,
      );
}