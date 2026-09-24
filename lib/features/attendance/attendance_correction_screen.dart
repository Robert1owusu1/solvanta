import 'package:flutter/material.dart';

import '../../core/models/attendance.dart';
import '../../core/models/class_room.dart';
import '../../core/models/student.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../students/students_repository.dart';
import 'attendance_repository.dart';

class AttendanceCorrectionScreen extends StatefulWidget {
  const AttendanceCorrectionScreen({super.key});

  @override
  State<AttendanceCorrectionScreen> createState() =>
      _AttendanceCorrectionScreenState();
}

class _AttendanceCorrectionScreenState extends State<AttendanceCorrectionScreen> {
  late Future<(List<ClassRoom>, List<Student>)> _data;
  String? _classId;
  String? _date;
  List<String> _dates = const [];
  Map<String, AttendanceStatus> _statuses = {};
  final _reason = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _data = StudentsRepository().classes().then(
        (classes) async => (classes, await StudentsRepository().active()));
  }

  Future<void> _pickClass(String classId) async {
    final dates = await AttendanceRepository().datesForClass(classId);
    if (!mounted) return;
    setState(() {
      _classId = classId;
      _dates = dates;
      _date = null;
      _statuses = {};
    });
  }

  Future<void> _pickDate(String date) async {
    if (_classId == null) return;
    final students = (await _data).$2
        .where((s) => s.classId == _classId)
        .toList();
    final records = await AttendanceRepository().forClassDate(_classId!, date);
    final byStudent = <String, AttendanceStatus>{
      for (final s in students) s.id: AttendanceStatus.absent,
    };
    for (final r in records) {
      byStudent[r.studentId] = r.status;
    }
    if (!mounted) return;
    setState(() {
      _date = date;
      _statuses = byStudent;
    });
  }

  Future<void> _save() async {
    if (_classId == null || _date == null || _statuses.isEmpty) return;
    final reason = _reason.text.trim();
    if (reason.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('A reason is required for any correction'),
          behavior: .floating));
      return;
    }
    setState(() => _saving = true);
    await AttendanceRepository().saveDay(
      _classId!,
      _date!,
      _statuses,
      reason: reason,
      actor: 'School Admin',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Attendance Corrections & Audit'),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final classes = snap.data?.$1 ?? const <ClassRoom>[];
          final students = snap.data?.$2 ?? const <Student>[];
          final roll = students.where((s) => s.classId == _classId).toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Corrections are logged to the audit trail with a '
                  'reason, and parents are re-alerted for absent/late changes.',
                  style: TextStyle(fontSize: 13, color: AppColors.muted)),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _classId,
                decoration: const InputDecoration(labelText: '1. Class'),
                items: [
                  for (final c in classes)
                    DropdownMenuItem(value: c.id, child: Text(c.displayName)),
                ],
                onChanged: (v) {
                  if (v != null) _pickClass(v);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _date,
                decoration: const InputDecoration(labelText: '2. Date'),
                items: [
                  for (final d in _dates.reversed)
                    DropdownMenuItem(value: d, child: Text(d)),
                ],
                onChanged: (v) {
                  if (v != null) _pickDate(v);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _reason,
                decoration: const InputDecoration(
                  labelText: '3. Reason for correction (required)',
                  hintText: 'e.g. office visit, teacher error, late register',
                ),
              ),
              if (_statuses.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('4. Adjust the roll then save',
                    style: TextStyle(fontWeight: .w700)),
                const SizedBox(height: 8),
                for (final s in roll)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                              child: Text(s.fullName,
                                  style: const TextStyle(
                                      fontWeight: .w600))),
                          for (final st in AttendanceStatus.values)
                            IconButton(
                              tooltip: st.label,
                              isSelected: _statuses[s.id] == st,
                              onPressed: () => setState(
                                  () => _statuses[s.id] = st),
                              style: IconButton.styleFrom(
                                backgroundColor: _statuses[s.id] == st
                                    ? _statusColor(st).withValues(alpha: .15)
                                    : null,
                              ),
                              icon: Icon(_iconFor(st), size: 20),
                              color: _statuses[s.id] == st
                                  ? _statusColor(st)
                                  : AppColors.border,
                            ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Save correction'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  IconData _iconFor(AttendanceStatus s) => switch (s) {
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