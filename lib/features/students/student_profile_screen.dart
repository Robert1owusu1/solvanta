import 'package:flutter/material.dart';

import '../../core/models/attendance.dart';
import '../../core/models/assessment.dart';
import '../../core/models/gate_event.dart';
import '../../core/models/intervention.dart';
import '../../core/models/question.dart';
import '../../core/models/student.dart';
import '../../core/models/subjects.dart';
import '../../core/models/submission.dart';
import '../../core/theme/app_theme.dart';
import '../assessment/assessment_repository.dart';
import '../attendance/attendance_repository.dart';
import '../audit/audit_repository.dart';
import 'student_qr_screen.dart';
import '../interventions/interventions_repository.dart';
import '../prep/mock_take_screen.dart';
import '../safety/safety_repository.dart';
import 'student_editor_screen.dart';
import 'students_repository.dart';

typedef _Summary = ({int total, int present, int late, int absent, int excused});
typedef _Learning = ({
  List<({String subjectId, String topic, int correct, int total, double pct})>
      weakTopics,
  int vacationDone,
  int vacationTotal,
  bool hasBank,
});

class StudentProfileScreen extends StatefulWidget {
  const StudentProfileScreen({
    super.key,
    required this.studentId,
    this.showAdminActions = false,
    this.showAppBar = true,
  });

  final String studentId;
  final bool showAdminActions;
  final bool showAppBar;

  @override
  State<StudentProfileScreen> createState() => _StudentProfileScreenState();
}

class _StudentProfileScreenState extends State<StudentProfileScreen> {
  late Future<
      (Student?, _Summary, List<AttendanceRecord>, List<GateEvent>,
          List<Intervention>, _Learning, List<Question>)> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<
      (Student?, _Summary, List<AttendanceRecord>, List<GateEvent>,
          List<Intervention>, _Learning, List<Question>)> _load() async {
    final sid = widget.studentId;
    final student = await StudentsRepository().byId(sid);
    final summary = await AttendanceRepository().summaryForStudent(sid);
    final history = await AttendanceRepository().historyForStudent(sid);
    final recent = <AttendanceRecord>[];
    for (final list in history.values) {
      recent.add(list.first);
      if (recent.length == 5) break;
    }
    final events = await SafetyRepository().forStudent(sid);
    final interventions = await InterventionsRepository().forStudent(sid);
    final bank = await AssessmentRepository().bank();
    final assessments = await AssessmentRepository().assessments();
    final subs = await AssessmentRepository().submissions();
    return (
      student,
      summary,
      recent,
      events,
      interventions,
      _learning(sid, assessments, subs, bank),
      bank,
    );
  }

  _Learning _learning(String studentId, List<Assessment> assessments,
      List<AssessmentSubmission> subs, List<Question> bank) {
    final counters = <String, List<int>>{};
    var vacationDone = 0, vacationTotal = 0;
    final vacationIds = <String>{
      for (final a in assessments)
        if (a.type == AssessmentType.vacation) a.id,
    };
    vacationTotal = vacationIds.length;
    final submittedIds = <String>{};
    for (final s in subs.where((x) => x.studentId == studentId)) {
      if (vacationIds.contains(s.assessmentId)) {
        submittedIds.add(s.assessmentId);
      }
      for (final a in assessments) {
        if (a.id != s.assessmentId) continue;
        for (final q in a.questions.where((x) => x.isObjective)) {
          final c =
              counters.putIfAbsent('${a.subjectId}|${q.topic}', () => [0, 0]);
          c[1] += 1;
          final got = s.answers[q.id]?.trim().toLowerCase() ?? '';
          if (got.isNotEmpty &&
              got == q.correctAnswer.trim().toLowerCase()) {
            c[0] += 1;
          }
        }
      }
    }
    vacationDone = submittedIds.length;
    final weak =
        <({String subjectId, String topic, int correct, int total, double pct})>[];
    for (final e in counters.entries) {
      final parts = e.key.split('|');
      final pct = 100 * e.value[0] / e.value[1];
      if (pct < 60) {
        weak.add((
          subjectId: parts[0],
          topic: parts[1],
          correct: e.value[0],
          total: e.value[1],
          pct: pct,
        ));
      }
    }
    weak.sort((a, b) => a.pct.compareTo(b.pct));
    return (
      weakTopics: weak,
      vacationDone: vacationDone,
      vacationTotal: vacationTotal,
      hasBank: bank.isNotEmpty,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.showAppBar
          ? AppBar(title: const Text('Student Profile'))
          : null,
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data;
          if (data == null || data.$1 == null) {
            return const Center(child: Text('Student not found'));
          }
          final student = data.$1!;
          final summary = data.$2;
          final recent = data.$3;
          final events = data.$4;
          final interventions = data.$5;
          final learning = data.$6;
          final bank = data.$7;
          final attendance =
              summary.present + summary.late + summary.absent + summary.excused;
          final pct = attendance == 0
              ? 0
              : ((summary.present + summary.late) * 100 ~/ attendance);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (widget.showAdminActions) ...[
                _adminActions(student),
                const SizedBox(height: 12),
              ],
              _header(student, pct),
              const SizedBox(height: 16),
              // Digital ID card — `openFromProfile` re-checks `canView`, so
              // this is safe to show for every role.
              OutlinedButton.icon(
                onPressed: () =>
                    StudentQr.openFromProfile(context, student.id),
                icon: const Icon(Icons.qr_code),
                label: const Text('Show student ID card'),
              ),
              const SizedBox(height: 16),
              _section('Attendance - last 5 school days', [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _chip('${summary.present} Present', AppTheme.brand),
                      _chip('${summary.late} Late', AppColors.warning),
                      _chip('${summary.absent} Absent', AppColors.danger),
                      _chip('${summary.excused} Excused',
                          AppColors.notAttempted),
                    ],
                  ),
                ),
                for (final r in recent)
                  ListTile(
                    dense: true,
                    leading: _statusIcon(r.status),
                    title: Text(r.date),
                    subtitle: Text('${r.status.label}'
                        '${r.checkIn != null ? ' · in ${r.checkIn}' : ''}'),
                  ),
              ]),
              _learningProgress(student, learning, bank, interventions),
              if (interventions.isNotEmpty)
                _section('Interventions', [
                  for (final it in interventions.where(
                      (i) => i.status != InterventionStatus.cancelled))
                    _interventionRow(it),
                ]),
              _section('Guardians', [
                for (final g in student.guardians)
                  _personRow(Icons.contact_page_outlined, g.name, g.phone,
                      g.relation),
              ]),
              _section('Emergency Contacts', [
                for (final e in student.emergencyContacts)
                  _personRow(Icons.emergency_outlined, e.name, e.phone,
                      e.relation, emergency: true),
              ]),
              _section('Authorized Pickup Persons', [
                for (final p in student.authorizedPickup)
                  _personRow(Icons.shield_outlined, p.name, p.phone, p.relation),
              ]),
              if (events.isNotEmpty)
                _section('Recent Gate Activity', [
                  for (final e in events.take(4))
                    _personRow(
                        _iconFor(e.type),
                        e.person ?? student.fullName,
                        e.date,
                        '${e.type.label} · ${e.time}'),
                ]),
            ],
          );
        },
      ),
    );
  }

  Widget _learningProgress(Student student, _Learning l, List<Question> bank,
      List<Intervention> interventions) {
    final activeInterventions = interventions
        .where((i) => i.status != InterventionStatus.cancelled)
        .toList();
    final cards = <Widget>[
      ListTile(
        leading: const Icon(Icons.auto_stories, color: AppTheme.brand),
        title: const Text('Vacation progress'),
        subtitle: Text(
            '${l.vacationDone} of ${l.vacationTotal} vacation pack(s) '
            '${l.vacationTotal == 0 ? 'planned — none published yet' : 'attempted'}'),
        trailing: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                value: l.vacationTotal == 0 ? 0 : l.vacationDone / l.vacationTotal,
                strokeWidth: 4,
                backgroundColor: AppTheme.brand.withValues(alpha: .12),
              ),
            ),
            Text(
                '${l.vacationTotal == 0 ? 0 : (l.vacationDone * 100 ~/ l.vacationTotal)}%',
                style:
                    const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
      if (activeInterventions.isEmpty)
        ListTile(
          leading: Icon(Icons.health_and_safety, color: AppColors.success),
          title: Text('Intervention status'),
          subtitle: Text('No active interventions'),
        )
      else
        ListTile(
          leading: Icon(Icons.support_agent, color: AppColors.warning),
          title: const Text('Intervention status'),
          subtitle: Text(
              '${activeInterventions.length} active intervention(s) '
              '— see below'),
        ),
      if (l.weakTopics.isEmpty)
        ListTile(
          leading: Icon(Icons.check_circle, color: AppColors.success),
          title: Text('Recommended practice'),
          subtitle: Text(
              'No weak topics right now — accuracy above 60% everywhere.'),
        )
      else
        for (final t in l.weakTopics.take(3))
          ListTile(
            dense: true,
            leading:
                Icon(Icons.priority_high, color: AppColors.warning),
            title: Text('Practise ${t.topic} — ${t.pct.toStringAsFixed(0)}%'),
            subtitle:
                Text('${subjectName(t.subjectId)} · ${t.correct}/${t.total} correct'),
            trailing: FilledButton.tonalIcon(
              onPressed: () => _practiceTopic(student, t.topic, t.subjectId, bank),
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('Go'),
            ),
          ),
    ];
    return _section('Learning & Progress', cards);
  }

  Future<void> _practiceTopic(Student student, String topic, String subjectId,
      List<Question> bank) async {
    final picked = AssessmentRepository().blueprintPick(
        from: bank, topic: topic, subjectId: subjectId, count: 5);
    if (picked.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No bank questions for that topic yet')));
      return;
    }
    final d = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    final assessment = Assessment(
      id: 'PRAC-${DateTime.now().millisecondsSinceEpoch}',
      title: 'Practice — $topic',
      type: AssessmentType.exercise,
      subjectId: subjectId,
      classId: student.classId,
      date: '${d.year}-${p(d.month)}-${p(d.day)}',
      createdBy: 'Learning Profile',
      questions: picked,
    );
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          MockTakeScreen(assessment: assessment, studentId: student.id),
    ));
    if (mounted) setState(() => _data = _load());
  }

  Widget _interventionRow(Intervention it) {
    final color = switch (it.status) {
      InterventionStatus.open => AppColors.warning,
      InterventionStatus.inProgress => AppTheme.brand,
      InterventionStatus.completed => AppColors.success,
      InterventionStatus.cancelled => AppColors.notAttempted,
    };
    return ListTile(
      dense: true,
      leading: Icon(Icons.support_agent, color: color),
      title: Text('${it.topic} — ${it.status.label}'),
      subtitle: Text('${it.action}\nby ${it.assignedBy} · ${it.createdDate}'),
      isThreeLine: true,
    );
  }

  Widget _adminActions(Student s) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ActionChip(
              avatar: const Icon(Icons.edit, size: 16),
              label: const Text('Edit'),
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => StudentEditorScreen(initial: s),
                ));
                if (mounted) setState(() => _data = _load());
              },
            ),
            ActionChip(
              avatar: const Icon(Icons.swap_horiz, size: 16),
              label: const Text('Transfer'),
              onPressed: () => _transferStudent(s),
            ),
            ActionChip(
              avatar: const Icon(Icons.trending_up, size: 16),
              label: const Text('Promote'),
              onPressed: s.promotedToClass() == null ? null : () => _promoteStudent(s),
            ),
            ActionChip(
              avatar: const Icon(Icons.school, size: 16),
              label: const Text('Graduate'),
              onPressed: s.status == 'Active' ? () => _graduateStudent(s) : null,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _transferStudent(Student s) async {
    final classes = await StudentsRepository().classes();
    if (!mounted) return;
    String? chosen;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Transfer ${s.fullName}'),
        content: DropdownButtonFormField<String>(
          initialValue: s.classId,
          decoration: const InputDecoration(labelText: 'Target class'),
          items: [
            for (final c in classes)
              DropdownMenuItem(value: c.id, child: Text(c.displayName)),
          ],
          onChanged: (v) => chosen = v,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (chosen != null && chosen != s.classId) {
                await StudentsRepository()
                    .saveStudent(s.copyWith(classId: chosen));
                await AuditRepository().log(
                  action: 'student.transfer',
                  actor: 'Admin',
                  target: s.id,
                  detail: '${s.fullName} moved to $chosen',
                  reason: 'Class transfer',
                );
              }
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) setState(() => _data = _load());
            },
            child: const Text('Transfer'),
          ),
        ],
      ),
    );
  }

  Future<void> _promoteStudent(Student s) async {
    final next = s.promotedToClass();
    if (next == null) return;
    await StudentsRepository().saveStudent(s.copyWith(classId: next));
    await AuditRepository().log(
      action: 'student.promote',
      actor: 'Admin',
      target: s.id,
      detail: '${s.fullName} promoted to $next',
      reason: 'End of term promotion',
    );
    if (mounted) setState(() => _data = _load());
  }

  Future<void> _graduateStudent(Student s) async {
    await StudentsRepository().saveStudent(s.copyWith(status: 'Graduated'));
    await AuditRepository().log(
      action: 'student.graduate',
      actor: 'Admin',
      target: s.id,
      detail: '${s.fullName} graduated',
      reason: 'Graduation',
    );
    if (mounted) setState(() => _data = _load());
  }

  Widget _statusIcon(AttendanceStatus s) => switch (s) {
        AttendanceStatus.present =>
          const Icon(Icons.check_circle, color: AppTheme.brand),
        AttendanceStatus.late => Icon(Icons.schedule, color: AppColors.warning),
        AttendanceStatus.absent => Icon(Icons.cancel, color: AppColors.danger),
        AttendanceStatus.excused =>
          Icon(Icons.verified_outlined, color: AppColors.notAttempted),
      };

  IconData _iconFor(GateEventType t) => switch (t) {
        GateEventType.arrival => Icons.login,
        GateEventType.departure => Icons.logout,
        GateEventType.pickupAuthorized => Icons.check_circle_outline,
        GateEventType.unauthorizedPickup => Icons.error_outline,
        GateEventType.earlyDeparture => Icons.schedule,
      };

  Widget _header(Student s, int pct) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: AppTheme.brand.withValues(alpha: .14),
              child: Text(s.initials,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: .w800, color: AppTheme.brand)),
            ),
            const SizedBox(height: 10),
            Text(s.fullName,
                style: const TextStyle(fontSize: 20, fontWeight: .w700)),
            const SizedBox(height: 4),
            Text('${s.admissionNo} · ${s.classId} · ${s.gender}',
                style: TextStyle(color: AppColors.muted)),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: .center,
              children: [
                Text('Attendance ', style: TextStyle(color: AppColors.muted)),
                Text('$pct%',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: .w800, color: AppTheme.brand)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label, style: TextStyle(color: color, fontWeight: .w600)),
      );

  Widget _section(String title, List<Widget> children) => Column(
        crossAxisAlignment: .start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(title,
                style: const TextStyle(fontSize: 15, fontWeight: .w700)),
          ),
          Card(
            child: Column(children: children),
          ),
          const SizedBox(height: 16),
        ],
      );

  Widget _personRow(IconData icon, String name, String phone, String detail,
      {bool emergency = false}) {
    return ListTile(
      dense: true,
      leading: Icon(
        icon,
        color: emergency
            ? AppColors.danger
            : phone == 'Check'
                ? (name == 'Verified'
                    ? AppColors.success
                    : AppTheme.brand)
                : AppTheme.brand,
      ),
      title: Text(name),
      subtitle: Text(detail.isEmpty ? phone : '$phone · $detail'),
    );
  }
}