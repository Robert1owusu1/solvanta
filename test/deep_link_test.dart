import 'package:flutter_test/flutter_test.dart';

import 'package:solvanta/core/models/app_notification.dart';
import 'package:solvanta/core/models/role.dart';
import 'package:solvanta/core/notifications/deep_link.dart';
import 'package:solvanta/features/home/dashboards.dart';

/// The deep-link resolver must always point at a module the role actually
/// has — and never at a module from another role's grid.
void main() {
  final roles = AppRole.values;

  String? resolve(NotificationKind kind, AppRole role) {
    final label = notificationDestination(kind, role);
    if (label == null) return null;
    final owned = modulesFor(role).map((m) => m.label);
    expect(owned, contains(label),
        reason: '$label must be a module of $role for kind $kind');
    return label;
  }

  test('announcements resolve for every role', () {
    for (final r in roles) {
      expect(resolve(NotificationKind.announcement, r), 'Announcements');
    }
  });

  test('gate reaches safety for staff, arrival view for parents', () {
    for (final r in roles) {
      final label = resolve(NotificationKind.gate, r);
      if (r.isSchoolStaff) {
        expect(label, 'Safety Gate');
      } else if (r.isParent) {
        expect(label, 'Arrival / Departure');
      } else {
        expect(label, isNull);
      }
    }
  });

  test('assessment updates land per role', () {
    for (final r in roles) {
      final label = resolve(NotificationKind.assessment, r);
      if (r.isSchoolStaff) {
        expect(label, 'Assessments');
      } else if (r.isParent) {
        expect(label, 'Results & Reports');
      } else if (r.isStudent) {
        expect(label, 'My Results');
      } else {
        expect(label, isNull);
      }
    }
  });

  test('messages land in the right inbox per role', () {
    for (final r in roles) {
      final label = resolve(NotificationKind.message, r);
      if (r.isTeacher) {
        expect(label, 'Parent Messages');
      } else if (r.isParent) {
        expect(label, 'Teacher Feedback');
      } else {
        expect(label, isNull);
      }
    }
  });

  test('teacher attendance maps to their lesson screen', () {
    expect(resolve(NotificationKind.attendance, AppRole.teacher),
        'Take Attendance');
    expect(resolve(NotificationKind.attendance, AppRole.schoolAdmin),
        'Attendance');
    expect(resolve(NotificationKind.attendance, AppRole.parent), 'Attendance');
    expect(resolve(NotificationKind.attendance, AppRole.student), isNull);
  });

  test('system notifications have no dedicated destination', () {
    for (final r in roles) {
      expect(notificationDestination(NotificationKind.system, r), isNull);
    }
  });
}