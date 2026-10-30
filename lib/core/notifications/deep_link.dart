import '../models/app_notification.dart';
import '../models/role.dart';

/// Maps a tapped notification's [NotificationKind] to the dashboard *module
/// label* a user of [role] should land on, or null when that kind has no
/// dedicated destination for this role (the caller falls back to the Inbox).
///
/// Labels intentionally match the keys of `modulesFor(role)` in
/// `lib/features/home/dashboards.dart`, so the app can reuse the module
/// grid's screen builders instead of maintaining a second registry of
/// routes. Role-sensitive resolution keeps parents off staff screens and
/// pupils off management screens.
String? notificationDestination(NotificationKind kind, AppRole role) {
  switch (kind) {
    case NotificationKind.gate:
      if (role.isSchoolStaff) return 'Safety Gate';
      if (role.isParent) return 'Arrival / Departure';
      return null; // pupils: their profile shows pickup state directly
    case NotificationKind.attendance:
      if (role == AppRole.teacher) return 'Take Attendance';
      if (role.isSchoolStaff) return 'Attendance';
      if (role.isParent) return 'Attendance';
      return null;
    case NotificationKind.reportCard:
      // An approved card is released to the family's results screen.
      if (role.isParent) return 'Results & Reports';
      if (role.isStudent) return 'My Results';
      if (role.isTeacher) return 'Report Cards';
      if (role.isSchoolStaff) return 'Report Card Designer';
      return null;
    case NotificationKind.assessment:
    case NotificationKind.marking:
      if (role.isSchoolStaff) return 'Assessments';
      if (role.isParent) return 'Results & Reports';
      if (role.isStudent) return 'My Results';
      return null;
    case NotificationKind.message:
      if (role.isTeacher) return 'Parent Messages';
      if (role.isParent) return 'Teacher Feedback';
      return null;
    case NotificationKind.assignment:
      if (role.isSchoolStaff) return 'Assignments';
      if (role.isStudent) return 'Assignments';
      return null;
    case NotificationKind.intervention:
      if (role.canCreateAssessments) return 'Interventions';
      return null;
    case NotificationKind.announcement:
      // Every role has the Announcements module.
      return 'Announcements';
    case NotificationKind.system:
      return null;
  }
}