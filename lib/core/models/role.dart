enum AppRole {
  superAdmin('Super Admin'),
  schoolAdmin('School Admin'),
  headteacher('Headteacher / Principal'),
  teacher('Teacher'),
  parent('Parent / Guardian'),
  student('Student'),
  staff('Authorized Staff'),
  educationAuthority('Education Authority');

  const AppRole(this.label);

  final String label;

  String get key => name;

  bool get isTeacher => this == AppRole.teacher;
  bool get isParent => this == AppRole.parent;
  bool get isStudent => this == AppRole.student;
  bool get isSchoolStaff =>
      this == AppRole.superAdmin ||
      this == AppRole.schoolAdmin ||
      this == AppRole.headteacher ||
      this == AppRole.teacher ||
      this == AppRole.staff;

  static AppRole fromKey(String key) =>
      AppRole.values.firstWhere((r) => r.name == key, orElse: () => AppRole.student);
}