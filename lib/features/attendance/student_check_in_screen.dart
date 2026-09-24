import 'package:flutter/material.dart';

import '../../core/models/attendance.dart';
import '../../core/models/gate_event.dart';
import '../../core/models/student.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'attendance_repository.dart';
import '../safety/safety_repository.dart';

class StudentCheckInScreen extends StatefulWidget {
  const StudentCheckInScreen({super.key});

  @override
  State<StudentCheckInScreen> createState() => _StudentCheckInScreenState();
}

class _StudentCheckInScreenState extends State<StudentCheckInScreen> {
  late Future<(List<Student>, List<String>)> _data;
  final _query = TextEditingController();
  List<Student> _results = const [];
  String _outcome = '';

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(List<Student>, List<String>)> _load() async {
    final students = await StudentsRepository().active();
    final roles = (await AuthRepository().currentUser())?.role.key ?? 'staff';
    return (students, [roles]);
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

  Future<void> _recordCheckIn(Student s) async {
    final reporter =
        (await AuthRepository().currentUser())?.name ?? 'School Staff';
    await SafetyRepository().record(
      studentId: s.id,
      type: GateEventType.arrival,
      reporter: reporter,
      detail: 'ID check-in verified at gate',
    );

    // Reflect arrival on today's class roll when possible.
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
    } catch (_) {}

    if (!mounted) return;
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    setState(() => _outcome = '${s.fullName} checked in today at $hh:$mm');
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
                        prefixIcon: const Icon(Icons.qr_code_scanner),
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