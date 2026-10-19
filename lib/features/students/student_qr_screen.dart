import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/models/student.dart';
import '../../core/models/user.dart';
import '../../core/platform/file_share.dart';
import '../../core/storage/local_store.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../attendance/student_check_in_screen.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'student_qr_card.dart';

// ---------------------------------------------------------------------------
// Full-screen student QR ID: role-gated (staff, linked parent, or the
// student themself), share as PNG through a RepaintBoundary (temp dir —
// never the gallery), and a Scan-mode stub that links to the gate
// check-in screen. The `StudentQr` facade is what other screens import.
// ---------------------------------------------------------------------------

/// Entry points for the student QR ID card. Parents can only reach their
/// own children; the screen re-checks [StudentQr.canView] defensively, so
/// even a mis-wired call cannot leak another student's QR code.
class StudentQr {
  const StudentQr._();

  /// Whether [user] may see [student]'s ID card: school staff always,
  /// parents only their linked children, students only themselves.
  static bool canView(User user, Student student) {
    if (user.isSchoolStaff) return true;
    if (user.role.isParent) {
      return user.studentIds.contains(student.id) ||
          student.parentUserId == user.id;
    }
    if (user.role.isStudent) {
      return user.id.replaceFirst('USR-', '') == student.id;
    }
    return false;
  }

  /// Builds the full-screen ID card for callers that already hold both
  /// [user] and [student] — drop-in for `student_profile_screen.dart`.
  static Widget profileQrScreen(User user, Student student) =>
      StudentQrScreen(user: user, student: student);

  /// Session-resolving `WidgetBuilder` for dashboard module wiring: opens
  /// the signed-in student's own ID card (or a friendly notice).
  static Widget qrBuilder(BuildContext context) => const _QrSessionGate();

  /// Pushes the ID card for [studentId] from a profile screen; resolves
  /// the session user itself and never throws to the caller.
  static Future<void> openFromProfile(
    BuildContext context,
    String studentId,
  ) async {
    try {
      final user = await AuthRepository().currentUser();
      if (!context.mounted) return;
      if (user == null) {
        svSnack(context, 'Sign in to view student ID cards.', error: true);
        return;
      }
      final student = await StudentsRepository().byId(studentId);
      if (!context.mounted) return;
      if (student == null) {
        svSnack(
          context,
          'That student record could not be found.',
          error: true,
        );
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => StudentQrScreen(user: user, student: student),
        ),
      );
    } catch (e) {
      debugPrint('[StudentQr] open from profile failed: $e');
      if (context.mounted) {
        svSnack(context, 'Could not open the ID card.', error: true);
      }
    }
  }
}

/// Full-screen student identity card: the premium [StudentQrCard] plus
/// **Share ID card (PNG)** (RepaintBoundary → temp file → share sheet) and
/// **Scan mode**, which links to the gate check-in screen. Loading shows a
/// skeleton; a failed school lookup shows an error with retry; restricted
/// roles get a locked state instead of the card.
class StudentQrScreen extends StatefulWidget {
  const StudentQrScreen({
    super.key,
    required this.user,
    required this.student,
  });

  /// Signed-in user (role-gated through [StudentQr.canView]).
  final User user;

  /// Student whose ID card is shown.
  final Student student;

  @override
  State<StudentQrScreen> createState() => _StudentQrScreenState();
}

class _StudentQrScreenState extends State<StudentQrScreen> {
  final GlobalKey _cardKey = GlobalKey();
  String? _schoolName;
  bool _schoolFailed = false;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _loadSchool();
  }

  Future<void> _loadSchool() async {
    try {
      final school = await LocalStore().loadSchool();
      if (!mounted) return;
      setState(() {
        _schoolFailed = false;
        _schoolName = (school == null || school.name.isEmpty)
            ? 'School ID'
            : school.name;
      });
    } catch (e) {
      debugPrint('[StudentQr] school lookup failed: $e');
      if (!mounted) return;
      setState(() {
        _schoolFailed = true;
        _schoolName = null;
      });
    }
  }

  void _retry() {
    setState(() {
      _schoolName = null;
      _schoolFailed = false;
    });
    _loadSchool();
  }

  /// Renders the card off-screen to a PNG and opens the share sheet.
  /// Everything stays in the temp directory — the gallery is never touched.
  Future<void> _sharePng() async {
    if (_sharing) return;
    final student = widget.student;
    final fileName = 'SOLVANTA-ID-${student.id}.png';
    setState(() => _sharing = true);
    try {
      // Give the repaint boundary one frame so it is guaranteed painted.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final boundary = _cardKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) {
        throw StateError('ID card has not painted yet');
      }
      final image = await boundary.toImage(pixelRatio: 3);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) {
        throw StateError('PNG encoding failed');
      }
      await saveAndShareFile(
          byteData.buffer.asUint8List(), fileName, 'image/png');
      svHaptic(SvHaptic.medium);
    } catch (e) {
      debugPrint('[StudentQr] share failed: $e');
      if (mounted) {
        svSnack(context, 'Could not share the ID card image.', error: true);
      }
    }
    if (mounted) setState(() => _sharing = false);
  }

  Future<void> _openScanMode() async {
    svHaptic(SvHaptic.light);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const StudentCheckInScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!StudentQr.canView(widget.user, widget.student)) {
      return Scaffold(
        appBar: const SvScreenHeader(title: 'Student ID'),
        body: const SvEmptyState(
          icon: Icons.lock_outline,
          title: 'Access restricted',
          message: 'Student ID cards are visible to school staff, the '
              'linked parent and the student themself.',
        ),
      );
    }
    final student = widget.student;
    final schoolName = _schoolName;
    Widget body;
    if (_schoolFailed) {
      body = SvErrorState(
        message: 'Could not load the school details for this ID card.',
        onRetry: _retry,
      );
    } else if (schoolName == null) {
      body = ListView(
        children: [
          SvCardSkeleton(lines: 5),
          SvCardSkeleton(lines: 3),
        ],
      );
    } else {
      body = SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SvEntrance(
              child: RepaintBoundary(
                key: _cardKey,
                child: StudentQrCard(
                  student: student,
                  schoolName: schoolName,
                ),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _sharing ? null : _sharePng,
              icon: _sharing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.share),
              label: Text(_sharing ? 'Preparing…' : 'Share ID card (PNG)'),
            ),
            // Staff-only. This screen is also shown to a student viewing their
            // own card and to a linked parent, and "Scan mode" pushes straight
            // into the gate check-in screen — so it must not be offered here.
            // The check-in screen refuses on its own now too; this just stops
            // the button existing for accounts that can't use it.
            if (widget.user.isSchoolStaff) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _openScanMode,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan mode'),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Scan at the school gate to check in or verify this identity. '
              'The image is generated on this device and never saved to '
              'your gallery.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: AppColors.muted,
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: SvScreenHeader(
        title: 'Student ID',
        subtitle: student.fullName,
      ),
      body: body,
    );
  }
}

/// Session-resolving gate for [StudentQr.qrBuilder]: loads the signed-in
/// user, maps them to their student record and hands off to the screen.
/// Failures surface as [SvErrorState] with retry, never as a crash.
class _QrSessionGate extends StatefulWidget {
  const _QrSessionGate();

  @override
  State<_QrSessionGate> createState() => _QrSessionGateState();
}

class _QrSessionGateState extends State<_QrSessionGate> {
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
      return const _QrMessage(
        icon: Icons.person_off,
        title: 'Not signed in',
        message: 'Sign in to open your student ID card.',
      );
    }
    final student = await StudentsRepository().studentForUser(user);
    if (student == null) {
      return const _QrMessage(
        icon: Icons.error_outline,
        title: 'No student record',
        message: 'Your account is not linked to a student yet. Ask the '
            'school office to finish your enrolment.',
      );
    }
    return StudentQrScreen(user: user, student: student);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _page,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Scaffold(
            appBar: const SvScreenHeader(title: 'Student ID'),
            body: ListView(
              children: [
                SvCardSkeleton(lines: 5),
                SvCardSkeleton(lines: 3),
              ],
            ),
          );
        }
        if (snap.hasError) {
          return Scaffold(
            appBar: const SvScreenHeader(title: 'Student ID'),
            body: SvErrorState(
              message: 'Could not open the ID card. Please try again.',
              onRetry: _retry,
            ),
          );
        }
        return snap.data ??
            const Scaffold(
              appBar: SvScreenHeader(title: 'Student ID'),
              body: SvEmptyState(
                icon: Icons.qr_code,
                title: 'Nothing to show',
                message: 'The ID card could not be opened for this account.',
              ),
            );
      },
    );
  }
}

/// Friendly full-screen notice used by the session gate.
class _QrMessage extends StatelessWidget {
  const _QrMessage({
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
      appBar: const SvScreenHeader(title: 'Student ID'),
      body: SvEmptyState(icon: icon, title: title, message: message),
    );
  }
}
