import 'role.dart';

class User {
  final String id;
  final String name;
  final String email;
  final String phone;
  final String password;
  final AppRole role;
  final String? schoolId;
  final String? classId;
  final List<String> studentIds;

  const User({
    required this.id,
    required this.name,
    required this.email,
    required this.phone,
    required this.password,
    required this.role,
    this.schoolId,
    this.classId,
    this.studentIds = const [],
  });

  bool get isSchoolStaff =>
      role == AppRole.superAdmin ||
      role == AppRole.schoolAdmin ||
      role == AppRole.headteacher ||
      role == AppRole.teacher ||
      role == AppRole.staff;

  bool get isSchoolLeader =>
      role == AppRole.schoolAdmin || role == AppRole.headteacher;

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        name: json['name'] as String,
        email: json['email'] as String,
        phone: (json['phone'] ?? '') as String,
        password: (json['password'] ?? '') as String,
        role: AppRole.fromKey(json['role'] as String),
        schoolId: json['schoolId'] as String?,
        classId: json['classId'] as String?,
        studentIds: ((json['studentIds'] ?? const []) as List)
            .cast<String>(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'phone': phone,
        'password': password,
        'role': role.key,
        'schoolId': schoolId,
        'classId': classId,
        'studentIds': studentIds,
      };

  User copyWith({String? name, String? phone}) => User(
        id: id,
        name: name ?? this.name,
        email: email,
        phone: phone ?? this.phone,
        password: password,
        role: role,
        schoolId: schoolId,
        classId: classId,
        studentIds: studentIds,
      );
}