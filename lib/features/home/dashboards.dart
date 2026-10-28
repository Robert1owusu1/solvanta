import 'package:flutter/material.dart';

import '../../core/models/role.dart';
import '../../core/models/user.dart';
import '../admin/parent_linking_screen.dart';
import '../admin/school_admin_screen.dart';
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
  Module(Icons.people, 'Students', ModulePhase.live,
      subtitle: 'Enrol, edit, transfer, promote & graduate',
      builder: (_) => const StudentsScreen()),
  Module(Icons.verified_user, 'Staff & Teachers', ModulePhase.live,
      subtitle: 'Accounts, roles & class assignment',
      builder: (_) => const StaffScreen()),
  Module(Icons.school, 'School & Classes', ModulePhase.live,
      subtitle: 'School info, streams & class setup',
      builder: (_) => const SchoolAdminScreen()),
  Module(Icons.link, 'Parent Linking', ModulePhase.live,
      subtitle: 'Link parents to students',
      builder: (_) => const ParentLinkingScreen()),
  Module(Icons.fact_check, 'Attendance', ModulePhase.live,
      subtitle: 'Daily roll, check-in/out, trends',
      builder: (_) => const AttendanceScreen()),
  Module(Icons.mode_edit_outline, 'Corrections', ModulePhase.live,
      subtitle: 'Adjust rolls with a reason & audit',
      builder: (_) => const AttendanceCorrectionScreen()),
  Module(Icons.qr_code_scanner, 'Check-in', ModulePhase.live,
      subtitle: 'Gate arrivals & badge lookups',
      builder: (_) => const StudentCheckInScreen()),
  Module(Icons.security, 'Safety Gate', ModulePhase.live,
      subtitle: 'Pickup verification, gate audit',
      builder: (_) => const SafetyGateScreen()),
  Module(Icons.health_and_safety, 'Safety Training', ModulePhase.live,
      subtitle: 'Lessons & quizzes for staff',
      builder: (_) => const SafetyTrainingScreen()),
  Module(Icons.quiz, 'Assessments', ModulePhase.live,
      subtitle: 'Create, blueprint & capture results',
      builder: (_) => const AssessmentsScreen()),
  Module(Icons.shelves, 'Question Bank', ModulePhase.live,
      subtitle: 'Tagged questions & marking schemes',
      builder: (_) => const QuestionBankScreen()),
  Module(Icons.auto_awesome, 'AI Question Generator', ModulePhase.latest,
      subtitle: 'Request, review & publish AI drafts',
      builder: (_) => const QuestionGenScreen()),
  Module(Icons.badge, 'Mark Work', ModulePhase.live,
      subtitle: 'Scan, rule marking & paper-first scoring',
      builder: (_) => const MarkingDashboardScreen()),
  Module(Icons.insights, 'Analytics', ModulePhase.live,
      subtitle: 'Class average, gaps, at-risk alerts',
      builder: (_) => const AnalyticsScreen()),
  Module(Icons.support_agent, 'Interventions', ModulePhase.live,
      subtitle: 'Re-mediation plans & reassessment',
      builder: (_) => const InterventionsScreen()),
  Module(Icons.person_pin, 'Learning Profiles', ModulePhase.live,
      subtitle: 'Mastery, error patterns, next steps',
      builder: (_) => const LearningProfileScreen()),
  Module(Icons.calendar_month, 'Timetable', ModulePhase.live,
      subtitle: 'Class & lesson slots',
      builder: (_) => const TimetableScreen()),
  Module(Icons.library_books, 'Resources', ModulePhase.live,
      subtitle: 'Video, worksheet & PDF library',
      builder: (_) => const ResourcesScreen()),
  Module(Icons.assignment_turned_in, 'Assignments', ModulePhase.live,
      subtitle: 'Set & track homework',
      builder: (_) => const AssignmentsScreen()),
  Module(Icons.receipt_long, 'Reports & Export', ModulePhase.live,
      subtitle: 'Report cards, PDF/Excel & CSV export',
      builder: (_) => const ReportsScreen()),
  Module(Icons.fact_check_outlined, 'Marking Feedback', ModulePhase.latest,
      subtitle: 'Questions each class struggled with',
      builder: (_) => const MarkingFeedbackScreen()),
  Module(Icons.palette, 'Report Card Designer', ModulePhase.live,
      subtitle: 'Classic, modern & transcript PDF layouts',
      builder: (_) => const ReportCardScreen()),
  Module(Icons.history, 'Audit Log', ModulePhase.live,
      subtitle: 'Changes, corrections & access trail',
      builder: (_) => const AuditScreen()),
  Module(Icons.event_note, 'Academic Calendar', ModulePhase.live,
      subtitle: 'Term, assessments & deadlines',
      builder: (_) => const AcademicCalendarScreen()),
  Module(Icons.campaign, 'Announcements', ModulePhase.live,
      subtitle: 'School, class & emergency notices',
      builder: (_) => const AnnouncementsScreen()),
  Module(Icons.account_balance_wallet, FeesModule.adminLabel, ModulePhase.live,
      subtitle: 'Bills, payments & receipts',
      builder: FeesModule.adminBuilder),
];

final _teacherModules = [
  Module(Icons.people, 'My Students', ModulePhase.live,
      subtitle: 'Class roll & learning profiles',
      builder: (_) => const StudentsScreen()),
  Module(Icons.check_circle_outline, 'Take Attendance', ModulePhase.live,
      subtitle: 'Mark the class present, late, absent',
      builder: (_) => const AttendanceScreen()),
  Module(Icons.mode_edit_outline, 'Corrections', ModulePhase.live,
      subtitle: 'Adjust rolls with a reason',
      builder: (_) => const AttendanceCorrectionScreen()),
  Module(Icons.qr_code_scanner, 'Check-in', ModulePhase.beta,
      subtitle: 'Gate arrivals & ID lookups',
      builder: (_) => const StudentCheckInScreen()),
  Module(Icons.security, 'Safety Gate', ModulePhase.beta,
      subtitle: 'Verify arrivals & pickups',
      builder: (_) => const SafetyGateScreen()),
  Module(Icons.assignment, 'Assessments', ModulePhase.live,
      subtitle: 'Create, blueprint & capture results',
      builder: (_) => const AssessmentsScreen()),
  Module(Icons.shelves, 'Question Bank', ModulePhase.live,
      subtitle: 'Tagged, curriculum-aligned questions',
      builder: (_) => const QuestionBankScreen()),
  Module(Icons.auto_awesome, 'AI Question Generator', ModulePhase.latest,
      subtitle: 'Request, review & publish AI drafts',
      builder: (_) => const QuestionGenScreen()),
  Module(Icons.document_scanner, 'Mark Work', ModulePhase.live,
      subtitle: 'Rule & AI-assisted marking',
      builder: (_) => const MarkingDashboardScreen()),
  Module(Icons.document_scanner_outlined, 'OCR Review', ModulePhase.latest,
      subtitle: 'Read photographed work, then confirm it yourself',
      builder: (_) => const OcrReviewScreen()),
  Module(Icons.fact_check_outlined, 'Marking Feedback', ModulePhase.latest,
      subtitle: 'Per-student & class feedback from marking',
      builder: (_) => const MarkingFeedbackScreen()),
  Module(Icons.data_exploration, 'Learning Gaps', ModulePhase.live,
      subtitle: 'Class weaknesses & interventions',
      builder: (_) => const AnalyticsScreen()),
  Module(Icons.support_agent, 'Interventions', ModulePhase.live,
      subtitle: 'Re-mediation plans',
      builder: (_) => const InterventionsScreen()),
  Module(Icons.calendar_month, 'Timetable', ModulePhase.live,
      subtitle: 'Class & lesson slots',
      builder: (_) => const TimetableScreen()),
  Module(Icons.library_books, 'Resources', ModulePhase.live,
      subtitle: 'Video, worksheet & PDF library',
      builder: (_) => const ResourcesScreen()),
  Module(Icons.assignment_turned_in, 'Assignments', ModulePhase.live,
      subtitle: 'Homework you set',
      builder: (_) => const AssignmentsScreen()),
  Module(Icons.forum, 'Parent Messages', ModulePhase.live,
      subtitle: 'Feedback & communication',
      builder: (_) => const MessagesScreen()),
  Module(Icons.campaign, 'Announcements', ModulePhase.live,
      subtitle: 'School, class & emergency notices',
      builder: (_) => const AnnouncementsScreen()),
  Module(Icons.event_note, 'Academic Calendar', ModulePhase.live,
      subtitle: 'Term, assessments & deadlines',
      builder: (_) => const AcademicCalendarScreen()),
];

final _parentModules = [
  Module(Icons.directions_walk, 'Arrival / Departure', ModulePhase.live,
      subtitle: 'My children at the gate',
      builder: (_) => const ParentChildViewScreen()),
  Module(Icons.read_more, 'Results & Reports', ModulePhase.live,
      subtitle: 'Assessment outcomes',
      builder: (_) => const ParentResultsScreen()),
  Module(Icons.event_available, 'Attendance', ModulePhase.live,
      subtitle: 'Days present & absence',
      builder: (_) => const ParentChildViewScreen()),
  Module(Icons.forum, 'Teacher Feedback', ModulePhase.live,
      subtitle: 'Messages & updates',
      builder: (_) => const MessagesScreen()),
  Module(Icons.campaign, 'Announcements', ModulePhase.live,
      subtitle: 'School, class & emergency notices',
      builder: (_) => const AnnouncementsScreen()),
  Module(Icons.receipt_long, FeesModule.portalLabel, ModulePhase.live,
      subtitle: 'Balances, charges & receipts',
      builder: FeesModule.parentBuilder),
];

final _studentModules = [
  Module(Icons.person, 'My Profile', ModulePhase.live,
      subtitle: 'My records, attendance & pickup list',
      builder: (_) => const StudentSelfViewScreen()),
  Module(Icons.emoji_events, 'My Results', ModulePhase.live,
      subtitle: 'Scores & grades',
      builder: (_) => const StudentResultsScreen()),
  Module(Icons.campaign, 'Announcements', ModulePhase.live,
      subtitle: 'School & class notices',
      builder: (_) => const AnnouncementsScreen()),
  Module(Icons.event_note, 'Academic Calendar', ModulePhase.live,
      subtitle: 'Assessments & deadlines',
      builder: (_) => const AcademicCalendarScreen()),
  Module(Icons.assignment_turned_in, 'Assignments', ModulePhase.live,
      subtitle: "What's due & submit",
      builder: (_) => const AssignmentsScreen()),
  Module(Icons.auto_stories, 'Study Hub', ModulePhase.live,
      subtitle: 'Corrections, practice, quizzes & vacation',
      builder: (_) => const StudyHubScreen()),
  Module(Icons.menu_book, 'BECE / WASSCE', ModulePhase.live,
      subtitle: 'Prep & mocks',
      builder: (_) => const PrepScreen()),
  Module(Icons.account_balance_wallet, 'My Fees', ModulePhase.live,
      subtitle: 'Charges, balances & receipts',
      builder: FeesModule.studentBuilder),
  Module(Icons.qr_code, 'My ID', ModulePhase.live,
      subtitle: 'Digital student ID card',
      builder: StudentQr.qrBuilder),
];

final _staffModules = [
  Module(Icons.fact_check, 'Attendance', ModulePhase.live,
      subtitle: 'Class & gate recording',
      builder: (_) => const AttendanceScreen()),
  Module(Icons.qr_code_scanner, 'Check-in', ModulePhase.live,
      subtitle: 'Gate arrivals & ID lookups',
      builder: (_) => const StudentCheckInScreen()),
  Module(Icons.security, 'Safety Gate', ModulePhase.live,
      subtitle: 'Gate monitoring',
      builder: (_) => const SafetyGateScreen()),
  Module(Icons.assignment, 'Assessments', ModulePhase.live,
      subtitle: 'Exam administration',
      builder: (_) => const AssessmentsScreen()),
  Module(Icons.shelves, 'Question Bank', ModulePhase.live,
      subtitle: 'Curriculum-aligned questions',
      builder: (_) => const QuestionBankScreen()),
  Module(Icons.auto_awesome, 'AI Question Generator', ModulePhase.latest,
      subtitle: 'Request, review & publish AI drafts',
      builder: (_) => const QuestionGenScreen()),
  Module(Icons.campaign, 'Announcements', ModulePhase.live,
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
      modules: _adminModules,
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
      AppRole.superAdmin ||
      AppRole.schoolAdmin ||
      AppRole.headteacher =>
        _adminModules,
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