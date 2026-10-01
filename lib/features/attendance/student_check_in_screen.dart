import 'package:flutter/material.dart';

import '../../core/models/attendance.dart';
import '../../core/models/gate_event.dart';
import '../../core/models/student.dart';
import '../../core/models/user.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'attendance_repository.dart';
import 'student_id_scanner_screen.dart';
import '../safety/safety_repository.dart';

class StudentCheckInScreen extends StatefulWidget {
  const StudentCheckInScreen({super.key, this.openScanner});

  /// Test seam / forward-compatibility: how the camera scanner is launched.
  /// Defaults to pushing the real [StudentIdScannerScreen]; tests inject a
  /// fake that returns a student id without touching the camera.
  final Future<String?> Function(BuildContext)? openScanner;

  @override
  State<StudentCheckInScreen> createState() => _StudentCheckInScreenState();
}

class _StudentCheckInScreenState extends State<StudentCheckInScreen> {
  late Future<(List<Student>, User?)> _data;
  final _query = TextEditingController();
  List<Student> _results = const [];
  String _outcome = '';

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// (students this account may see, the signed-in account).
  ///
  /// The account rides along so both the build and the write path can check
  /// it directly. It used to be discarded in favour of a role *string* that
  /// defaulted to `'staff'` — so a signed-out caller was treated as holding
  /// the most permissive role rather than the least.
  Future<(List<Student>, User?)> _load() async {
    final user = await AuthRepository().currentUser();
    // Scoped exactly as the Students screen scopes its roll (visibleToUser):
    // this screen must not become a whole-school directory lookup for whoever
    // manages to reach it.
    final students = await StudentsRepository().visibleToUser(user);
    return (students, user);
  }

  void _onQuery(String q) {
    final needle = q.trim().toLowerCase();
    setState(() {
      if (needle.isEmpty) {
        _results = const [];
      } else {
        _results = all.where((s) =>
            s.id.toLowerCase().contains(needle) ||
            s.admissionNo.toLowerCase().contains(needle) ||
            s.fullName.toLowerCase().contains(needle)).take(8).toList();
      }
    });
  }

  List<Student> all = const [];

  /// Opens the camera scanner; a successful scan resolves the student and
  /// surfaces the standard confirm → check-in tile (a scan never records an
  /// arrival by itself).
  Future<void> _openScanner() async {
    final scannedId = await (widget.openScanner?.call(context) ??
        Navigator.of(context).push<String>(
          MaterialPageRoute(builder: (_) => const StudentIdScannerScreen()),
        ));
    if (scannedId == null || !mounted) return;
    final match = all.where((s) => s.id == scannedId).firstOrNull;
    if (match == null) {
      svSnack(context, 'No student on this roll with ID "$scannedId"',
          error: true);
      return;
    }
    _query.text = match.admissionNo;
    _onQuery(match.admissionNo);
    svSnack(context, 'Scanned ${match.fullName} — confirm to check in');
  }

  Future<void> _recordCheckIn(Student s) async {
    final me = await AuthRepository().currentUser();
    // Second gate, on the write itself. build() already refuses the screen,
    // but the record path must not simply trust that it was reached through
    // build(). Note there is no `?? 'School Staff'` fallback any more — that
    // attributed arrivals to staff even when nobody was signed in.
    if (me == null || !me.role.canSaveAttendance) {
      if (!mounted) return;
      svSnack(context, 'Your account cannot record gate check-ins',
          error: true);
      return;
    }
    final reporter = me.name;
    try {
      await SafetyRepository().record(
        studentId: s.id,
        type: GateEventType.arrival,
        reporter: reporter,
        detail: 'ID check-in verified at gate',
      );
    } catch (e) {
      // Previously this await was unguarded, so a gate-store failure escaped
      // into the button's onPressed and left the user with no feedback.
      debugPrint('[CheckIn] gate record failed: $e');
      if (!mounted) return;
      svSnack(context, 'Could not record the arrival at the gate', error: true);
      return;
    }

    // Reflect arrival on today's class roll when possible.
    var rollUpdated = true;
    try {
      final records =
          await AttendanceRepository().forClassDate(s.classId, _today());
      if (records.isNotEmpty) {
        final statuses = {
          for (final r in records) r.studentId: r.status,
        }
          ..[s.id] = AttendanceStatus.present;
        await AttendanceRepository().saveDay(s.classId, _today(), statuses);
      }
    } catch (e) {
      // An empty catch here meant a roll update that never landed still
      // reported a clean check-in.
      rollUpdated = false;
      debugPrint('[CheckIn] attendance roll update failed: $e');
    }

    if (!mounted) return;
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    setState(() => _outcome = rollUpdated
        ? '${s.fullName} checked in today at $hh:$mm'
        : '${s.fullName} recorded at $hh:$mm — attendance roll not updated');
    _query.clear();
    _results = const [];

    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && _outcome.isNotEmpty) setState(() => _outcome = '');
    });
  }

  String _today() {
    final d = DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Student ID Check-in'),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SvLoading();
          }
          all = snap.data?.$1 ?? const <Student>[];
          final user = snap.data?.$2;
          // S6: recording a gate arrival is staff work. The dashboard module
          // lists keep this screen off students' and parents' home screens,
          // but a module list is not an authorization boundary — the Student
          // ID card's "Scan mode" pushed straight into here, and any deep link
          // or future navigation change would do the same. Refuse here, at the
          // screen that actually performs the write.
          if (user == null || !user.role.canSaveAttendance) {
            return const SvEmptyState(
              icon: Icons.lock_outline,
              title: 'Access restricted',
              message: 'Gate check-in is for school staff, teachers and '
                  'admins. Ask your administrator if you need access.',
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _query,
                      autofocus: true,
                      onChanged: _onQuery,
                      decoration: InputDecoration(
                        hintText: 'Scan or type ID (STU-002, admission no, name)',
                        prefixIcon: IconButton(
                          tooltip: 'Scan ID card',
                          icon: const Icon(Icons.qr_code_scanner),
                          onPressed: _openScanner,
                        ),
                        suffixIcon: _query.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear search',
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _query.clear();
                                  _onQuery('');
                                }),
                      ),
                    ),
                    if (_outcome.isNotEmpty)
                      Card(
                        color: AppColors.successBg,
                        margin: const EdgeInsets.only(top: 12),
                        child: ListTile(
                          leading: Icon(Icons.check_circle,
                              color: AppColors.success),
                          title: Text(_outcome,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: _results.isEmpty
                    ? Center(
                        child: Text(
                          _query.text.trim().isEmpty
                              ? 'Type an ID to check a student in'
                              : 'No student found for '
                                  '"${_query.text.trim()}"',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.muted),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _results.length,
                        itemBuilder: (context, i) {
                          final s = _results[i];
                          return SvEntrance(
                            delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
                            child: SvPressScale(
                              child: SvAvatarTile(
                              title: s.fullName,
                              meta:
                                  '${s.id} · ${s.admissionNo} · ${s.classId}',
                              initials: s.initials,
                              trailing: FilledButton.icon(
                                onPressed: () => _recordCheckIn(s),
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppTheme.brand,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 10),
                                  textStyle: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700),
                                ),
                                icon: const Icon(Icons.login, size: 18),
                                label: const Text('Check in'),
                              ),
                            ),
                          ),
                          );
                        },
                        ),
              ),
            ],
          );
        },
      ),
    );
  }
}