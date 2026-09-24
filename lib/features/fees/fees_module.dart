import 'package:flutter/material.dart';

import '../../core/models/student.dart';
import '../../core/models/user.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'fees_screen.dart';
import 'student_fees_screen.dart';

// ---------------------------------------------------------------------------
// Fees module entry points. The dashboard module lists in `dashboards.dart`
// hold no user in scope, so the builders below resolve the session user
// themselves (same pattern as StudentResultsScreen / StudentSelfViewScreen).
// ---------------------------------------------------------------------------

/// Entry points the lead wires into `dashboards.dart` (and elsewhere):
/// session-resolving [WidgetBuilder]s plus direct constructors for code
/// that already holds the [User].
class FeesModule {
  FeesModule._();

  /// Admin/teacher dashboard tile label.
  static const String adminLabel = 'Fees & Payments';

  /// Parent/student dashboard tile label.
  static const String portalLabel = 'My Fees';

  /// Admin screen for callers that already have the signed-in [user].
  static Widget adminScreen(User user) => FeesScreen(user: user);

  /// Portal screen for callers that already have the signed-in [user] and
  /// the [student] to show.
  static Widget studentFeesScreen(User user, Student student) =>
      StudentFeesScreen(user: user, student: student);

  /// `builder:` tear-off for the admin module list — resolves the session
  /// user, then opens the bursar dashboard (restricted state for non-staff).
  static Widget adminBuilder(BuildContext context) =>
      const _FeesGate(_FeesPortal.admin);

  /// `builder:` tear-off for the parent module list — one child goes
  /// straight to their fees, several children open the switcher wrapper.
  static Widget parentBuilder(BuildContext context) =>
      const _FeesGate(_FeesPortal.parent);

  /// `builder:` tear-off for the student module list — opens the signed-in
  /// student's own fees.
  static Widget studentBuilder(BuildContext context) =>
      const _FeesGate(_FeesPortal.student);
}

/// Which dashboard asked for the fees screen.
enum _FeesPortal { admin, parent, student }

/// Resolves the session user (and, for portals, the right child/student)
/// before handing off to a full screen. Loading shows a branded skeleton,
/// failures show [SvErrorState] with retry — it never throws.
class _FeesGate extends StatefulWidget {
  const _FeesGate(this.portal);

  final _FeesPortal portal;

  @override
  State<_FeesGate> createState() => _FeesGateState();
}

class _FeesGateState extends State<_FeesGate> {
  late Future<Widget> _page;

  @override
  void initState() {
    super.initState();
    _page = _resolve();
  }

  Future<void> _retry() async {
    final next = _resolve();
    setState(() => _page = next);
    await next;
  }

  Future<Widget> _resolve() async {
    final user = await AuthRepository().currentUser();
    if (user == null) {
      return const _GateMessage(
        icon: Icons.person_off,
        title: 'Not signed in',
        message: 'Sign in to see fees and payments.',
      );
    }
    if (user.isSchoolStaff) return FeesScreen(user: user);
    switch (widget.portal) {
      case _FeesPortal.admin:
        return const _GateMessage(
          icon: Icons.lock_outline,
          title: 'Restricted',
          message: 'Fee management is for the bursar and school admins.',
        );
      case _FeesPortal.parent:
        return _forParent(user);
      case _FeesPortal.student:
        return _forStudent(user);
    }
  }

  Future<Widget> _forParent(User user) async {
    if (!user.role.isParent) {
      return const _GateMessage(
        icon: Icons.lock_outline,
        title: 'Restricted',
        message: 'This portal is for linked parents and guardians.',
      );
    }
    final linked = await StudentsRepository().byParentUserAll(user.id);
    final extra = await StudentsRepository().byParentAll(user);
    final seen = <String>{};
    final children = <Student>[];
    for (final s in [...linked, ...extra]) {
      if (seen.add(s.id)) children.add(s);
    }
    if (children.isEmpty) {
      return const _GateMessage(
        icon: Icons.child_care,
        title: 'No child linked',
        message: 'Ask the school office to link your child so you can see '
            'their fees and payments.',
      );
    }
    if (children.length == 1) {
      return StudentFeesScreen(user: user, student: children.first);
    }
    return ChildFeesScreen(user: user);
  }

  Future<Widget> _forStudent(User user) async {
    if (!user.role.isStudent) {
      return const _GateMessage(
        icon: Icons.lock_outline,
        title: 'Restricted',
        message: 'This portal is for student accounts.',
      );
    }
    final student = await StudentsRepository().studentForUser(user);
    if (student == null) {
      return const _GateMessage(
        icon: Icons.error_outline,
        title: 'Student record not found',
        message: 'Your account is not linked to a student record yet. '
            'Ask the school office to finish your enrolment.',
      );
    }
    return StudentFeesScreen(user: user, student: student);
  }

  String get _title =>
      widget.portal == _FeesPortal.admin
          ? FeesModule.adminLabel
          : FeesModule.portalLabel;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _page,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Scaffold(
            appBar: SvScreenHeader(title: _title),
            body: ListView(
              children: [
                SvCardSkeleton(),
                SvListSkeleton(rows: 5),
              ],
            ),
          );
        }
        if (snap.hasError) {
          return Scaffold(
            appBar: SvScreenHeader(title: _title),
            body: SvErrorState(
              message: 'Could not open fees. Please try again.',
              onRetry: _retry,
            ),
          );
        }
        return snap.data ??
            Scaffold(
              appBar: SvScreenHeader(title: _title),
              body: const SvEmptyState(
                icon: Icons.account_balance_wallet,
                title: 'Nothing to show',
                message: 'Fees could not be opened for this account.',
              ),
            );
      },
    );
  }
}

/// Full-screen friendly notice used when the portal cannot serve content
/// (not signed in, restricted, missing record).
class _GateMessage extends StatelessWidget {
  const _GateMessage({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SvScreenHeader(title: 'Fees & Payments'),
      body: SvEmptyState(icon: icon, title: title, message: message),
    );
  }
}
