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

  // ---- Capability checks (single source of truth for UI affordances) ----
  // Each helper mirrors the backend's per-route allow-list in
  // backend/internal/httpapi/server.go so the client never offers an action
  // the API would refuse (and never hides one it would allow).

  /// School administrators (not teachers/staff): student lifecycle —
  /// enroll, edit, transfer, promote, graduate.
  bool get canAdministerStudents =>
      this == AppRole.superAdmin ||
      this == AppRole.schoolAdmin ||
      this == AppRole.headteacher;

  /// View the whole school's student/class dataset (scope in
  /// `StudentsRepository.visibleToUser` matches backend `listStudents`).
  bool get canViewAllStudents => isSchoolStaff;

  /// Teachers and above (not staff): create/edit/delete bank questions,
  /// create assignments, apply assessment verdicts.
  bool get canCreateAssessments =>
      this == AppRole.superAdmin ||
      this == AppRole.schoolAdmin ||
      this == AppRole.headteacher ||
      this == AppRole.teacher;

  bool get canManageQuestionBank => canCreateAssessments;
  bool get canCreateAssignments => canCreateAssessments;

  /// Record the daily roll / gate check-ins (staff + teachers + admins).
  bool get canSaveAttendance => isSchoolStaff;

  /// Post school/class/emergency announcements (matches backend: staff+).
  bool get canPostAnnouncements => isSchoolStaff;

  /// Read the audit trail — admins only (matches backend /api/audit).
  bool get canViewAudit =>
      this == AppRole.superAdmin ||
      this == AppRole.schoolAdmin ||
      this == AppRole.headteacher;

  static AppRole fromKey(String key) =>
      AppRole.values.firstWhere((r) => r.name == key, orElse: () => AppRole.student);
}