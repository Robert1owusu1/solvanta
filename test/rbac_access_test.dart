import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solvanta/core/models/assessment.dart';
import 'package:solvanta/core/models/role.dart';
import 'package:solvanta/core/models/user.dart';
import 'package:solvanta/features/auth/register_screen.dart';
import 'package:solvanta/features/home/dashboards.dart';

/// Golden RBAC matrix for the client.
///
/// This locks in the "who may reach which module / capability" contract that
/// mirror the backend's per-route role gates in
/// `backend/internal/httpapi/rbac_test.go`. If the module grid, role routing
/// or a capability flag drifts, this test fails on purpose.
void main() {
  User userWith(AppRole role) => User(
        id: 'USR-${role.name}',
        name: role.label,
        email: 'x@school.gh',
        phone: '',
        password: 'x',
        role: role,
      );

  group('modulesFor(role) — module grids', () {
    List<String> labels(AppRole role) =>
        modulesFor(role).map((m) => m.label).toList();

    test('admin sees the full school-management grid', () {
      expect(labels(AppRole.superAdmin), labels(AppRole.schoolAdmin));
      expect(labels(AppRole.schoolAdmin), labels(AppRole.headteacher));
      expect(labels(AppRole.schoolAdmin), containsAll(<String>[
        'Students',
        'Staff & Teachers',
        'Parent Linking',
        'Safety Training',
        'Mark Work',
        'Analytics',
        'Interventions',
        'Reports & Export',
        'Report Card Designer',
        'Audit Log',
        'Academic Calendar',
        'Announcements',
        'Fees & Payments',
      ]));
      // Admin-only surfaces that no lower role may reach.
      expect(labels(AppRole.schoolAdmin), containsAll(<String>[
        'Audit Log',
        'Staff & Teachers',
        'Parent Linking',
        'Safety Training',
        'Reports & Export',
      ]));
    });

    test('teacher sees classroom modules but no admin surfaces', () {
      final teacher = labels(AppRole.teacher);
      expect(teacher, containsAll(<String>[
        'My Students',
        'Take Attendance',
        'Assessments',
        'Question Bank',
        'AI Question Generator',
        'Mark Work',
        'Learning Gaps',
        'Interventions',
        'Assignments',
        'Parent Messages',
        'Announcements',
        'Academic Calendar',
      ]));
      expect(teacher, isNot(contains('Audit Log')));
      expect(teacher, isNot(contains('Staff & Teachers')));
      expect(teacher, isNot(contains('Parent Linking')));
      expect(teacher, isNot(contains('Reports & Export')));
      expect(teacher, isNot(contains('Safety Training')));
      expect(teacher, isNot(contains('Enroll')));
    });

    test('parent only sees their children surfaces', () {
      final parent = labels(AppRole.parent);
      expect(parent, ['Arrival / Departure', 'Results & Reports',
        'Attendance', 'Teacher Feedback', 'Announcements', 'My Fees']);
      expect(parent, isNot(contains('Audit Log')));
      expect(parent, isNot(contains('Question Bank')));
      expect(parent, isNot(contains('Assignments')));
      expect(parent, isNot(contains('Assessments')));
    });

    test('student only sees their own learning surfaces', () {
      final student = labels(AppRole.student);
      expect(student, ['My Profile', 'My Results', 'Announcements',
        'Academic Calendar', 'Assignments', 'Study Hub',
        if (kBecePrepEnabled) 'BECE / WASSCE',
        'My Fees', 'My ID']);
      expect(student, isNot(contains('Audit Log')));
      expect(student, isNot(contains('Question Bank')));
      expect(student, isNot(contains('Fees & Payments')));
      expect(student, isNot(contains('Teacher Feedback')));
    });

    test('staff sees supporting duties only — no marking/admin', () {
      final staff = labels(AppRole.staff);
      expect(staff, containsAll(<String>[
        'Attendance', 'Check-in', 'Safety Gate', 'Assessments',
        'Question Bank', 'Announcements',
      ]));
      expect(staff, isNot(contains('Mark Work')));
      expect(staff, isNot(contains('Audit Log')));
      expect(staff, isNot(contains('My Students')));
    });

    test('education authority routes like staff', () {
      expect(labels(AppRole.educationAuthority), labels(AppRole.staff));
    });
  });

  group('dashboardFor(user) — role routing', () {
    test('leaders route to the admin dashboard', () {
      expect(dashboardFor(userWith(AppRole.superAdmin)),
          isA<AdminDashboard>());
      expect(dashboardFor(userWith(AppRole.schoolAdmin)),
          isA<AdminDashboard>());
      expect(dashboardFor(userWith(AppRole.headteacher)),
          isA<AdminDashboard>());
    });
    test('teacher / parent / student / staff route to their own dashboards',
        () {
      expect(dashboardFor(userWith(AppRole.teacher)), isA<TeacherDashboard>());
      expect(dashboardFor(userWith(AppRole.parent)), isA<ParentDashboard>());
      expect(dashboardFor(userWith(AppRole.student)), isA<StudentDashboard>());
      expect(dashboardFor(userWith(AppRole.staff)), isA<StaffDashboard>());
      expect(dashboardFor(userWith(AppRole.educationAuthority)),
          isA<StaffDashboard>());
    });
  });

  group('role capabilities', () {
    test('student lifecycle is admin-only', () {
      for (final r in AppRole.values) {
        final expected = r == AppRole.superAdmin ||
            r == AppRole.schoolAdmin ||
            r == AppRole.headteacher;
        expect(r.canAdministerStudents, expected, reason: '$r');
      }
    });

    test('assessment/assignment/question creation is teacher+', () {
      for (final r in AppRole.values) {
        final expected = r == AppRole.superAdmin ||
            r == AppRole.schoolAdmin ||
            r == AppRole.headteacher ||
            r == AppRole.teacher;
        expect(r.canCreateAssessments, expected, reason: '$r');
        expect(r.canManageQuestionBank, expected, reason: '$r');
        expect(r.canCreateAssignments, expected, reason: '$r');
      }
    });

    test('exam-type assessment creation is school leaders only', () {
      for (final r in AppRole.values) {
        final leader = r == AppRole.superAdmin ||
            r == AppRole.schoolAdmin ||
            r == AppRole.headteacher;
        expect(r.canCreateExams, leader, reason: '$r');
        // Mid-Term / End-of-Term / Mock / Diagnostic / Remedial: leaders only.
        for (final t in AppRole.examRestrictedTypes) {
          expect(r.canCreateAssessmentOf(t), leader, reason: '$r x $t');
        }
        // Classroom work stays teacher+.
        const teacherWork = {
          AssessmentType.exercise,
          AssessmentType.homework,
          AssessmentType.quiz,
          AssessmentType.classTest,
          AssessmentType.vacation,
        };
        for (final t in teacherWork) {
          expect(r.canCreateAssessmentOf(t), r.canCreateAssessments,
              reason: '$r x $t');
        }
      }
    });

    test('attendance saving and announcements are staff+', () {
      for (final r in AppRole.values) {
        expect(r.canSaveAttendance, r.isSchoolStaff, reason: '$r');
        expect(r.canPostAnnouncements, r.isSchoolStaff, reason: '$r');
      }
      expect(AppRole.staff.isSchoolStaff, isTrue);
      expect(AppRole.teacher.isSchoolStaff, isTrue);
    });

    test('audit visibility is leaders only', () {
      for (final r in AppRole.values) {
        final expected = r == AppRole.superAdmin ||
            r == AppRole.schoolAdmin ||
            r == AppRole.headteacher;
        expect(r.canViewAudit, expected, reason: '$r');
      }
    });
  });

  group('registration', () {
    testWidgets('lets a user self-register only as teacher/parent/student',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Teacher'), findsOneWidget);
      expect(find.text('Parent'), findsOneWidget);
      expect(find.text('Student'), findsOneWidget);

      // Roles that must never be self-served (segments render the first word
      // of the role label: Super Admin → "Super", Headteacher / Principal →
      // "Headteacher", Authorized Staff → "Authorized", Education Authority →
      // "Education", School Admin → "School").
      expect(find.text('School'), findsNothing);
      expect(find.text('Headteacher'), findsNothing);
      expect(find.text('Super'), findsNothing);
      expect(find.text('Authorized'), findsNothing);
      expect(find.text('Education'), findsNothing);
    });
  });
}