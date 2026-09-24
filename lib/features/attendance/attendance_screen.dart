import 'package:flutter/material.dart';

import '../../core/models/attendance.dart';
import '../../core/models/class_room.dart';
import '../../core/models/student.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'attendance_repository.dart';

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  late Future<(List<ClassRoom>, List<Student>, String?)> _data;
  late String _date;
  String? _classId;
  Map<String, AttendanceStatus> _statuses = {};
  final Set<String> _touched = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final d = DateTime.now();
    _date =
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    _data = _load();
  }

  Future<(List<ClassRoom>, List<Student>, String?)> _load() async {
    final repo = StudentsRepository();
    final classes = await repo.classes();
    final students = await repo.all();
    String? defaultClass;
    final user = await AuthRepository().currentUser();
    if (user != null && user.isSchoolStaff) {
      defaultClass =
          user.classId ?? (classes.isNotEmpty ? classes.first.id : null);
    }
    return (classes, students, defaultClass);
  }

  Future<void> _initRoll() async {
    final (_, students, defaultClass) = await _data;
    final classId = _classId ?? defaultClass;
    if (classId == null) return;
    final records =
        await AttendanceRepository().forClassDate(classId, _date);
    // Seed from records only — untouched students are not assumed absent.
    final byStudent = <String, AttendanceStatus>{
      for (final r in records) r.studentId: r.status,
    };
    if (mounted) {
      setState(() {
        _statuses = byStudent;
        _touched
          ..clear()
          ..addAll(records.map((r) => r.studentId));
        _classId = classId;
      });
    }
  }

  Future<void> _save() async {
    if (_classId == null) return;
    if (_touched.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: const Text('Nothing changed — no records saved.'),
            backgroundColor: AppTheme.brand.withValues(alpha: .9)),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final toSave = <String, AttendanceStatus>{
        for (final id in _touched) id: _statuses[id] ?? AttendanceStatus.absent,
      };
      await AttendanceRepository().saveDay(_classId!, _date, toSave);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Attendance saved for $_date')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Couldn\'t save attendance — please try again.'),
          backgroundColor: AppColors.danger,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Attendance'),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final (classes, students, defaultClass) =
              snap.data ?? (<ClassRoom>[], <Student>[], null);
          if (_classId == null && defaultClass != null && _statuses.isEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _initRoll());
          }
          final classId = _classId ?? defaultClass;
          final rollUsers =
              students.where((s) => s.classId == classId).toList();
          final counts = <AttendanceStatus, int>{};
          for (final s in _statuses.values) {
            counts[s] = (counts[s] ?? 0) + 1;
          }
          return Column(
            children: [
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: .horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final c in classes)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(c.displayName),
                          selected: classId == c.id,
                          onSelected: (_) async {
                            _classId = c.id;
                            _statuses = {};
                            await _initRoll();
                          },
                        ),
                      ),
                  ],
                ),
              ),
              _statusBar(counts),
              Expanded(
                child: classId == null
                    ? Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Select a class to begin the roll.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.muted),
                          ),
                        ),
                      )
                    : rollUsers.isEmpty
                        ? Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                'No students in this class yet.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: AppColors.muted),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 24),
                            itemCount: rollUsers.length,
                            itemBuilder: (context, i) {
                              final s = rollUsers[i];
                              return SvEntrance(
                                delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
                                child: SvPressScale(
                                  child: _rollTile(
                                s,
                                _statuses[s.id],
                                (status) => setState(() {
                                  _statuses[s.id] = status;
                                  _touched.add(s.id);
                                }),
                              ),
                                ),
                              );
                            },
                          ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _saving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Save attendance'),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _statusBar(Map<AttendanceStatus, int> counts) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          for (final s in AttendanceStatus.values)
            if ((counts[s] ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Row(
                  children: [
                    Icon(_statusIcon(s), size: 16, color: _statusColor(s)),
                    const SizedBox(width: 4),
                    Text('${counts[s]}',
                        style: const TextStyle(fontWeight: .w700)),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _rollTile(Student s, AttendanceStatus? status, ValueChanged<AttendanceStatus> onChanged) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppTheme.brand, AppTheme.brandLight],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Text(s.initials,
                  style: const TextStyle(
                      fontWeight: .w700, color: Colors.white, fontSize: 15)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.fullName,
                      style: const TextStyle(fontWeight: .w600)),
                  Text(
                    status == null ? 'Not marked' : status.label,
                    style: TextStyle(
                        fontSize: 11,
                        color: status == null
                            ? AppColors.muted
                            : _statusColor(status)),
                  ),
                ],
              ),
            ),
            for (final st in AttendanceStatus.values)
              IconButton(
                tooltip: st.label,
                isSelected: status == st,
                onPressed: () => onChanged(st),
                style: IconButton.styleFrom(
                  backgroundColor: status == st
                      ? _statusColor(st).withValues(alpha: .15)
                      : null,
                ),
                icon: Icon(_statusIcon(st), size: 20),
                color: status == st ? _statusColor(st) : AppColors.border,
              ),
          ],
        ),
      ),
    );
  }

  IconData _statusIcon(AttendanceStatus s) => switch (s) {
        AttendanceStatus.present => Icons.check_circle_outline,
        AttendanceStatus.late => Icons.schedule,
        AttendanceStatus.absent => Icons.cancel_outlined,
        AttendanceStatus.excused => Icons.verified_outlined,
      };

  Color _statusColor(AttendanceStatus s) => switch (s) {
        AttendanceStatus.present => AppTheme.brand,
        AttendanceStatus.late => AppColors.warning,
        AttendanceStatus.absent => AppColors.danger,
        AttendanceStatus.excused => AppColors.notAttempted,
      };
}