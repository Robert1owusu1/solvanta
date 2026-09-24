import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:solvanta/main.dart' as app;
import 'package:solvanta/core/models/role.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/features/home/dashboards.dart';

/// On-device acceptance gate: each seeded role logs into the real app and sees
/// exactly the dashboard modules meant for it — and never another role's.
///
/// Run with the device connected:
///   flutter test integration_test/rbac_on_device_test.dart -d R8YL30E37XH
///
/// Verifies against the real app on the device:
///  1. real login maps to the correct role (offline local store by default;
///     live API when the backend is bridged via `adb reverse`);
///  2. the dashboard header shows the role;
///  3. the role's module grid renders every module it is entitled to, and none
///     from any other role (assertions are scoped to the module GridView so
///     overview stat-cards that share words never interfere);
///  4. the exact grid equals `modulesFor(role)` — checked from the real session
///     user inside the running app.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Finder homeList() => find.byType(Scrollable).first;

  /// The module dashboard grid: a shrink-wrapped, non-scrollable GridView whose
  /// children are all built once it is attached, so absence is meaningful.
  Finder moduleGrid() => find.byWidgetPredicate((w) =>
      w is GridView &&
      w.shrinkWrap == true &&
      w.physics is NeverScrollableScrollPhysics);

  /// [label] as it appears inside the module grid only.
  Finder inGrid(String label) =>
      find.descendant(of: moduleGrid(), matching: find.text(label));

  /// Pumps until [finder] matches, or [timeout] elapses (slow-device safe).
  Future<void> waitFor(WidgetTester tester, Finder finder,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 250));
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('timed out waiting for ${finder.toString()}');
  }

  Future<void> signIn(WidgetTester tester, String email, String password) async {
    await waitFor(tester, find.text('Sign in'));
    await tester.enterText(find.byType(TextField).at(0), email);
    await tester.enterText(find.byType(TextField).at(1), password);
    await tester.tap(find.text('Sign in'));
    // Dashboard entrance animations.
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
  }

  Future<void> signOut(WidgetTester tester) async {
    // Bring the header (with the sign-out button) back into view first.
    final signOutBtn = find.byTooltip('Sign out');
    if (signOutBtn.evaluate().isEmpty) {
      await tester.scrollUntilVisible(signOutBtn, -300,
          scrollable: homeList(), maxScrolls: 40);
    }
    await tester.tap(signOutBtn);
    await tester.pumpAndSettle();
    await waitFor(tester, find.text('Sign in'));
  }

  /// Verifies the signed-in session maps to [role] with exactly the module
  /// grid that role is entitled to (source of truth: modulesFor(role)).
  Future<void> expectExactGrid(
      WidgetTester tester, AppRole role, List<String> labels) async {
    final store = LocalStore();
    final users = await store.loadUsers();
    final uid = await store.getSessionUserId();
    expect(uid, isNotNull, reason: 'a session must be active');
    final user = users.firstWhere((u) => u.id == uid);
    expect(user.role, role, reason: 'session user must carry the role');
    final got = modulesFor(user.role).map((m) => m.label).toSet();
    expect(got, labels.toSet(),
        reason: '$role module grid must be exactly $labels');
  }

  Future<void> verifyRole(WidgetTester tester,
      {required AppRole role,
      required String email,
      required String password,
      required List<String> labels,
      required List<String> absentRendered}) async {
    await signIn(tester, email, password);

    // Header subtitle shows the role label once the dashboard is up.
    await waitFor(tester, find.text(role.label));

    // Bring the module grid into view: once the GridView child is attached,
    // all of its (shrink-wrapped) children are built, so every remaining
    // assertion below is complete without further scrolling.
    final firstModule = inGrid(labels.first);
    if (firstModule.evaluate().isEmpty) {
      await tester.scrollUntilVisible(firstModule, 300,
          scrollable: homeList(), maxScrolls: 60);
    }

    for (final l in labels) {
      expect(inGrid(l), findsWidgets,
          reason: '$role must render module "$l" in its grid');
    }
    for (final l in absentRendered) {
      expect(inGrid(l), findsNothing,
          reason: '$role must NOT render module "$l" in its grid');
    }
    await expectExactGrid(tester, role, labels);

    await tester.fling(homeList(), const Offset(0, 3000), 3000);
    await tester.pumpAndSettle();
    await signOut(tester);
  }

  testWidgets('RBAC on device: each role sees only its own modules',
      (tester) async {
    app.main();
    await tester.pump(const Duration(seconds: 1));
    await waitFor(tester, find.text('Sign in'),
        timeout: const Duration(seconds: 30));
    expect(find.text('Email'), findsOneWidget,
        reason: 'fresh install starts at the login screen');

    const adminLabels = <String>[
      'Students', 'Staff & Teachers', 'School & Classes', 'Parent Linking',
      'Attendance', 'Corrections', 'Check-in', 'Safety Gate',
      'Safety Training', 'Assessments', 'Question Bank',
      'AI Question Generator', 'Mark Work', 'Analytics', 'Interventions',
      'Learning Profiles', 'Timetable', 'Resources', 'Assignments',
      'Reports & Export', 'Report Card Designer', 'Audit Log',
      'Academic Calendar', 'Announcements', 'Fees & Payments',
    ];

    // --- Super admin (operator): the full admin grid, but never learner
    //     self-space tiles.
    await verifyRole(tester,
        role: AppRole.superAdmin,
        email: 'super@solvanta.app',
        password: 'super123',
        labels: adminLabels,
        absentRendered: const <String>[
          'My Students', 'Take Attendance', 'Arrival / Departure', 'My Profile'
        ]);

    // --- School admin: same management grid.
    await verifyRole(tester,
        role: AppRole.schoolAdmin,
        email: 'admin@solvanta.app',
        password: 'admin123',
        labels: adminLabels,
        absentRendered: const <String>[
          'My Students', 'My Profile', 'Arrival / Departure'
        ]);

    // --- Teacher: classroom tools, no admin/learner surfaces.
    await verifyRole(tester,
        role: AppRole.teacher,
        email: 'efua.mensah@school.gh',
        password: 'teacher123',
        labels: const <String>[
          'My Students', 'Take Attendance', 'Corrections', 'Check-in',
          'Safety Gate', 'Assessments', 'Question Bank',
          'AI Question Generator', 'Mark Work', 'Learning Gaps',
          'Interventions', 'Timetable', 'Resources', 'Assignments',
          'Parent Messages', 'Announcements', 'Academic Calendar',
        ],
        absentRendered: const <String>[
          'Students', 'Staff & Teachers', 'Parent Linking', 'My Profile'
        ]);

    // --- Parent: only their children's view.
    await verifyRole(tester,
        role: AppRole.parent,
        email: 'ama.owusu@school.gh',
        password: 'parent123',
        labels: const <String>[
          'Arrival / Departure', 'Results & Reports', 'Attendance',
          'Teacher Feedback', 'Announcements', 'My Fees',
        ],
        absentRendered: const <String>[
          'Students', 'Staff & Teachers', 'My Students', 'Question Bank',
          'My Profile', 'Audit Log',
        ]);

    // --- Student: only self.
    await verifyRole(tester,
        role: AppRole.student,
        email: 'kojo.owusu@school.gh',
        password: 'student123',
        labels: const <String>[
          'My Profile', 'My Results', 'Announcements', 'Academic Calendar',
          'Assignments', 'Study Hub', 'BECE / WASSCE', 'My Fees', 'My ID',
        ],
        absentRendered: const <String>[
          'Students', 'Staff & Teachers', 'Question Bank',
          'Teacher Feedback', 'Arrival / Departure', 'Audit Log',
        ]);
  });
}