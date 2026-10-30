import 'package:flutter/material.dart';

import '../../core/models/role.dart';
import '../../core/models/user.dart';
import '../admin/parent_linking_screen.dart';
import '../admin/school_admin_screen.dart';
import '../admin/schools_screen.dart';
import '../admin/sms_screen.dart';
import '../admin/staff_screen.dart';
import '../assessment/assessments_screen.dart';
import '../assessment/question_bank_screen.dart';
import '../assignments/assignments_screen.dart';
import '../attendance/attendance_correction_screen.dart';
import '../attendance/attendance_screen.dart';
import '../attendance/student_check_in_screen.dart';
import '../analytics/analytics_screen.dart';
import '../analytics/learning_profile_screen.dart';
import '../audit/audit_screen.dart';
import '../calendar/academic_calendar_screen.dart';
import '../communication/announcements_screen.dart';
import '../communication/messages_screen.dart';
import '../fees/fees_module.dart';
import '../interventions/interventions_screen.dart';
import '../marking/marking_dashboard_screen.dart';
import '../ocr/ocr_review_screen.dart';
import '../prep/prep_screen.dart';
import '../prep/study_hub_screen.dart';
import '../questions/question_gen_screen.dart';
import '../reports/marking_feedback_screen.dart';
import '../reports/parent_meetings_screen.dart';
import '../reports/report_card_screen.dart';
import '../reports/reports_screen.dart';
import '../resources/resources_screen.dart';
import '../safety/safety_gate_screen.dart';
import '../safety/safety_training_screen.dart';
import '../students/student_qr_screen.dart';
import '../students/students_screen.dart';
import '../timetable/timetable_screen.dart';
import 'child_view_screen.dart';
import 'widgets/dashboard_scaffold.dart';

final _adminModules = [
  Module(Icons.people, 'Students', NavSection.people,
      subtitle: 'Enrol, edit, transfer, promote & graduate',
      builder: (_) => const StudentsScreen()),
  Module(Icons.verified_user, 'Staff & Teachers', NavSection.people,
      subtitle: 'Accounts, roles & class assignment',
      builder: (_) => const StaffScreen()),
  Module(Icons.school, 'School & Classes', NavSection.people,
      subtitle: 'School info, streams & class setup',
      builder: (_) => const SchoolAdminScreen()),
  Module(Icons.link, 'Parent Linking', NavSection.people,
      subtitle: 'Link parents to students',
      builder: (_) => const ParentLinkingScreen()),
  Module(Icons.fact_check, 'Attendance', NavSection.daily,
      subtitle: 'Daily roll, check-in/out, trends',
      builder: (_) => const AttendanceScreen()),
  Module(Icons.mode_edit_outline, 'Corrections', NavSection.daily,
      subtitle: 'Adjust rolls with a reason & audit',
      builder: (_) => const AttendanceCorrectionScreen()),
  Module(Icons.qr_code_scanner, 'Check-in', NavSection.daily,
      subtitle: 'Gate arrivals & badge lookups',
      builder: (_) => const StudentCheckInScreen()),
  Module(Icons.security, 'Safety Gate', NavSection.daily,
      subtitle: 'Pickup verification, gate audit',
      builder: (_) => const SafetyGateScreen()),
  Module(Icons.health_and_safety, 'Safety Training', NavSection.daily,
      subtitle: 'Lessons & quizzes for staff',
      builder: (_) => const SafetyTrainingScreen()),
  Module(Icons.quiz, 'Assessments', NavSection.teaching,
      subtitle: 'Create, blueprint & capture results',
      builder: (_) => const AssessmentsScreen()),
  Module(Icons.shelves, 'Question Bank', NavSection.teaching,
      subtitle: 'Tagged questions & marking schemes',
      builder: (_) => const QuestionBankScreen()),
  Module(Icons.auto_awesome, 'AI Question Generator', NavSection.teaching,
      subtitle: 'Request, review & publish AI drafts',
      builder: (_) => const QuestionGenScreen()),
  Module(Icons.badge, 'Mark Work', NavSection.marking,
      subtitle: 'Scan, rule marking & paper-first scoring',
      builder: (_) => const MarkingDashboardScreen()),
  Module(Icons.insights, 'Analytics', NavSection.marking,
      subtitle: 'Class average, gaps, at-risk alerts',
      builder: (_) => const AnalyticsScreen()),
  Module(Icons.support_agent, 'Interventions', NavSection.marking,
      subtitle: 'Re-mediation plans & reassessment',
      builder: (_) => const InterventionsScreen()),
  Module(Icons.person_pin, 'Learning Profiles', NavSection.marking,
      subtitle: 'Mastery, error patterns, next steps',
      builder: (_) => const LearningProfileScreen()),
  Module(Icons.calendar_month, 'Timetable', NavSection.teaching,
      subtitle: 'Class & lesson slots',
      builder: (_) => const TimetableScreen()),
  Module(Icons.library_books, 'Resources', NavSection.teaching,
      subtitle: 'Video, worksheet & PDF library',
      builder: (_) => const ResourcesScreen()),
  Module(Icons.assignment_turned_in, 'Assignments', NavSection.teaching,
      subtitle: 'Set & track homework',
      builder: (_) => const AssignmentsScreen()),
  Module(Icons.receipt_long, 'Reports & Export', NavSection.records,
      subtitle: 'Report cards, PDF/Excel & CSV export',
      builder: (_) => const ReportsScreen()),
  Module(Icons.fact_check_outlined, 'Marking Feedback', NavSection.marking,
      subtitle: 'Questions each class struggled with',
      builder: (_) => const MarkingFeedbackScreen()),
  Module(Icons.palette, 'Report Card Designer', NavSection.records,
      subtitle: 'Terminal report, modern & transcript PDFs',
      builder: (_) => const ReportCardScreen()),
  Module(Icons.event_available_outlined, 'Parent Meetings', NavSection.comms,
      subtitle: 'Follow up with families',
      builder: (_) => const ParentMeetingsScreen()),
  Module(Icons.sms_outlined, 'SMS to Parents', NavSection.comms,
      subtitle: 'Texts for families without the app',
      builder: (_) => const SmsScreen()),
  Module(Icons.history, 'Audit Log', NavSection.records,
      subtitle: 'Changes, corrections & access trail',
      builder: (_) => const AuditScreen()),
  Module(Icons.event_note, 'Academic Calendar', NavSection.comms,
      subtitle: 'Term, assessments & deadlines',
      builder: (_) => const AcademicCalendarScreen()),
  Module(Icons.campaign, 'Announcements', NavSection.comms,
      subtitle: 'School, class & emergency notices',
      builder: (_) => const AnnouncementsScreen()),
  Module(Icons.account_balance_wallet, FeesModule.adminLabel, NavSection.finance,
      subtitle: 'Bills, payments & receipts',
      builder: FeesModule.adminBuilder),
];

/// The platform owner: onboarding schools, then any school's management.
final _superAdminModules = [
  Module(Icons.domain_add_outlined, 'Schools', NavSection.people,
      subtitle: 'Onboard schools & their admins',
      builder: (_) => const SchoolsScreen()),
  ..._adminModules,
];

final _teacherModules = [
  Module(Icons.people, 'My Students', NavSection.people,
      subtitle: 'Class roll & learning profiles',
      builder: (_) => const StudentsScreen()),
  Module(Icons.check_circle_outline, 'Take Attendance', NavSection.daily,
      subtitle: 'Mark the class present, late, absent',
      builder: (_) => const AttendanceScreen()),
  Module(Icons.mode_edit_outline, 'Corrections', NavSection.daily,
      subtitle: 'Adjust rolls with a reason',
      builder: (_) => const AttendanceCorrectionScreen()),
  Module(Icons.qr_code_scanner, 'Check-in', NavSection.daily,
      subtitle: 'Gate arrivals & ID lookups',
      builder: (_) => const StudentCheckInScreen()),
  Module(Icons.security, 'Safety Gate', NavSection.daily,
      subtitle: 'Verify arrivals & pickups',
      builder: (_) => const SafetyGateScreen()),
  Module(Icons.assignment, 'Assessments', NavSection.teaching,
      subtitle: 'Create, blueprint & capture results',
      builder: (_) => const AssessmentsScreen()),
  Module(Icons.shelves, 'Question Bank', NavSection.teaching,
      subtitle: 'Tagged, curriculum-aligned questions',
      builder: (_) => const QuestionBankScreen()),
  Module(Icons.auto_awesome, 'AI Question Generator', NavSection.teaching,
      subtitle: 'Request, review & publish AI drafts',
      builder: (_) => const QuestionGenScreen()),
  Module(Icons.document_scanner, 'Mark Work', NavSection.marking,
      subtitle: 'Rule & AI-assisted marking',
      builder: (_) => const MarkingDashboardScreen()),
  Module(Icons.document_scanner_outlined, 'OCR Review', NavSection.marking,
      subtitle: 'Read photographed work, then confirm it yourself',
      builder: (_) => const OcrReviewScreen()),
  Module(Icons.fact_check_outlined, 'Marking Feedback', NavSection.marking,
      subtitle: 'Per-student & class feedback from marking',
      builder: (_) => const MarkingFeedbackScreen()),
  Module(Icons.workspace_premium_outlined, 'Report Cards', NavSection.marking,
      subtitle: "Your class's remarks & terminal reports",
      builder: (_) => const ReportCardScreen()),
  Module(Icons.event_available_outlined, 'Parent Meetings', NavSection.comms,
      subtitle: 'Follow up with families',
      builder: (_) => const ParentMeetingsScreen()),
  Module(Icons.data_exploration, 'Learning Gaps', NavSection.marking,
      subtitle: 'Class weaknesses & interventions',
      builder: (_) => const AnalyticsScreen()),
  Module(Icons.support_agent, 'Interventions', NavSection.marking,
      subtitle: 'Re-mediation plans',
      builder: (_) => const InterventionsScreen()),
  Module(Icons.calendar_month, 'Timetable', NavSection.teaching,
      subtitle: 'Class & lesson slots',
      builder: (_) => const TimetableScreen()),
  Module(Icons.library_books, 'Resources', NavSection.teaching,
      subtitle: 'Video, worksheet & PDF library',
      builder: (_) => const ResourcesScreen()),
  Module(Icons.assignment_turned_in, 'Assignments', NavSection.teaching,
      subtitle: 'Homework you set',
      builder: (_) => const AssignmentsScreen()),
  Module(Icons.forum, 'Parent Messages', NavSection.comms,
      subtitle: 'Feedback & communication',
      builder: (_) => const MessagesScreen()),
  Module(Icons.campaign, 'Announcements', NavSection.comms,
      subtitle: 'School, class & emergency notices',
      builder: (_) => const AnnouncementsScreen()),
  Module(Icons.event_note, 'Academic Calendar', NavSection.comms,
      subtitle: 'Term, assessments & deadlines',
      builder: (_) => const AcademicCalendarScreen()),
];

final _parentModules = [
  Module(Icons.directions_walk, 'Arrival / Departure', NavSection.daily,
      subtitle: 'My children at the gate',
      builder: (_) => const ParentChildViewScreen()),
  Module(Icons.read_more, 'Results & Reports', NavSection.marking,
      subtitle: 'Assessment outcomes',
      builder: (_) => const ParentResultsScreen()),
  Module(Icons.event_available, 'Attendance', NavSection.daily,
      subtitle: 'Days present & absence',
      builder: (_) => const ParentChildViewScreen()),
  Module(Icons.forum, 'Teacher Feedback', NavSection.comms,
      subtitle: 'Messages & updates',
      builder: (_) => const MessagesScreen()),
  Module(Icons.campaign, 'Announcements', NavSection.comms,
      subtitle: 'School, class & emergency notices',
      builder: (_) => const AnnouncementsScreen()),
  Module(Icons.receipt_long, FeesModule.portalLabel, NavSection.finance,
      subtitle: 'Balances, charges & receipts',
      builder: FeesModule.parentBuilder),
];

/// BECE / WASSCE prep: on the school's own grading for the student's class.
/// Set false to pause it (hidden from every menu).
const kBecePrepEnabled = true;

final _studentModules = [
  Module(Icons.person, 'My Profile', NavSection.people,
      subtitle: 'My records, attendance & pickup list',
      builder: (_) => const StudentSelfViewScreen()),
  Module(Icons.emoji_events, 'My Results', NavSection.marking,
      subtitle: 'Scores & grades',
      builder: (_) => const StudentResultsScreen()),
  Module(Icons.campaign, 'Announcements', NavSection.comms,
      subtitle: 'School & class notices',
      builder: (_) => const AnnouncementsScreen()),
  Module(Icons.event_note, 'Academic Calendar', NavSection.comms,
      subtitle: 'Assessments & deadlines',
      builder: (_) => const AcademicCalendarScreen()),
  Module(Icons.assignment_turned_in, 'Assignments', NavSection.teaching,
      subtitle: "What's due & submit",
      builder: (_) => const AssignmentsScreen()),
  Module(Icons.auto_stories, 'Study Hub', NavSection.teaching,
      subtitle: 'Corrections, practice, quizzes & vacation',
      builder: (_) => const StudyHubScreen()),
  if (kBecePrepEnabled)
    Module(Icons.menu_book, 'BECE / WASSCE', NavSection.teaching,
        subtitle: 'Prep & mocks',
        builder: (_) => const PrepScreen()),
  Module(Icons.account_balance_wallet, 'My Fees', NavSection.finance,
      subtitle: 'Charges, balances & receipts',
      builder: FeesModule.studentBuilder),
  Module(Icons.qr_code, 'My ID', NavSection.people,
      subtitle: 'Digital student ID card',
      builder: StudentQr.qrBuilder),
];

final _staffModules = [
  Module(Icons.fact_check, 'Attendance', NavSection.daily,
      subtitle: 'Class & gate recording',
      builder: (_) => const AttendanceScreen()),
  Module(Icons.qr_code_scanner, 'Check-in', NavSection.daily,
      subtitle: 'Gate arrivals & ID lookups',
      builder: (_) => const StudentCheckInScreen()),
  Module(Icons.security, 'Safety Gate', NavSection.daily,
      subtitle: 'Gate monitoring',
      builder: (_) => const SafetyGateScreen()),
  Module(Icons.assignment, 'Assessments', NavSection.teaching,
      subtitle: 'Exam administration',
      builder: (_) => const AssessmentsScreen()),
  Module(Icons.shelves, 'Question Bank', NavSection.teaching,
      subtitle: 'Curriculum-aligned questions',
      builder: (_) => const QuestionBankScreen()),
  Module(Icons.auto_awesome, 'AI Question Generator', NavSection.teaching,
      subtitle: 'Request, review & publish AI drafts',
      builder: (_) => const QuestionGenScreen()),
  Module(Icons.campaign, 'Announcements', NavSection.comms,
      subtitle: 'School, class & emergency notices',
      builder: (_) => const AnnouncementsScreen()),
];

class AdminDashboard extends StatelessWidget {
  const AdminDashboard({super.key, required this.user});

  final User user;

  @override
  Widget build(BuildContext context) {
    return DashboardScaffold(
      user: user,
      listTitle: 'School Management',
      modules: modulesFor(user.role),
    );
  }
}

class TeacherDashboard extends StatelessWidget {
  const TeacherDashboard({super.key, required this.user});

  final User user;

  @override
  Widget build(BuildContext context) {
    return DashboardScaffold(
      user: user,
      listTitle: 'My teaching day',
      modules: _teacherModules,
    );
  }
}

class ParentDashboard extends StatelessWidget {
  const ParentDashboard({super.key, required this.user});

  final User user;

  @override
  Widget build(BuildContext context) {
    return DashboardScaffold(
      user: user,
      listTitle: 'My children',
      modules: _parentModules,
    );
  }
}

class StudentDashboard extends StatelessWidget {
  const StudentDashboard({super.key, required this.user});

  final User user;

  @override
  Widget build(BuildContext context) {
    return DashboardScaffold(
      user: user,
      listTitle: 'My learning',
      modules: _studentModules,
    );
  }
}

class StaffDashboard extends StatelessWidget {
  const StaffDashboard({super.key, required this.user});

  final User user;

  @override
  Widget build(BuildContext context) {
    return DashboardScaffold(
      user: user,
      listTitle: 'My duties',
      modules: _staffModules,
    );
  }
}

/// The module set a role may reach — the single source of truth that
/// [`dashboardFor`] uses. Mirrors the backend's per-route role gates.
List<Module> modulesFor(AppRole role) => switch (role) {
      AppRole.superAdmin => _superAdminModules,
      AppRole.schoolAdmin || AppRole.headteacher => _adminModules,
      AppRole.teacher => _teacherModules,
      AppRole.parent => _parentModules,
      AppRole.student => _studentModules,
      AppRole.staff || AppRole.educationAuthority => _staffModules,
    };

/// The dashboard widget for a signed-in [user].
Widget dashboardFor(User user) => switch (user.role) {
      AppRole.superAdmin ||
      AppRole.schoolAdmin ||
      AppRole.headteacher =>
        AdminDashboard(user: user),
      AppRole.teacher => TeacherDashboard(user: user),
      AppRole.parent => ParentDashboard(user: user),
      AppRole.student => StudentDashboard(user: user),
      AppRole.staff || AppRole.educationAuthority => StaffDashboard(user: user),
    };