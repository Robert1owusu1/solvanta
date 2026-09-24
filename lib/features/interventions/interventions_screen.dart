import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/intervention.dart';
import '../../core/models/student.dart';
import '../../core/models/submission.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../assessment/assessment_builder_screen.dart';
import '../assessment/assessment_repository.dart';
import '../audit/audit_repository.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'interventions_repository.dart';

class InterventionsScreen extends StatefulWidget {
  const InterventionsScreen({super.key});

  @override
  State<InterventionsScreen> createState() => _InterventionsScreenState();
}

class _InterventionsScreenState extends State<InterventionsScreen> {
  late Future<
      (List<Intervention>, List<Student>, List<AssessmentSubmission>)> _data;
  String _filter = 'All';

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(List<Intervention>, List<Student>, List<AssessmentSubmission>)>
      _load() async {
    final interventions = await InterventionsRepository().all();
    final students = await StudentsRepository().active();
    final subs = await AssessmentRepository().submissions();
    return (interventions, students, subs);
  }

  Future<void> _create() async {
    final students = (await _data).$2;
    if (!mounted) return;
    final student = await showModalBottomSheet<Student>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _StudentPicker(students: students),
    );
    if (student == null) return;
    final topic = TextEditingController();
    final action = TextEditingController();
    final user = await AuthRepository().currentUser();
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Intervention: ${student.fullName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: topic,
                decoration: const InputDecoration(
                    labelText: 'Weak topic',
                    hintText: 'e.g. Equivalent fractions')),
            const SizedBox(height: 12),
            TextField(
                controller: action,
                minLines: 3,
                maxLines: 4,
                decoration: const InputDecoration(
                    labelText: 'Intervention action',
                    hintText: 'e.g. Re-teach; 3 practice sessions; reassess in 2 weeks')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (topic.text.trim().isEmpty) return;
              await InterventionsRepository().create(
                student: student,
                topic: topic.text.trim(),
                action: action.text.trim().isEmpty
                    ? 'Targeted support on ${topic.text.trim()}'
                    : action.text.trim(),
                assignedBy: user?.name ?? 'Teacher',
              );
              await AuditRepository().log(
                action: 'intervention.create',
                actor: user?.name ?? 'Teacher',
                target: student.id,
                detail: '${topic.text.trim()} — ${student.fullName}',
                reason: 'Learning support',
              );
              if (ctx.mounted) Navigator.pop(ctx);
              setState(() => _data = _load());
            },
            child: const Text('Assign'),
          ),
        ],
      ),
    );
  }

  Future<void> _setStatus(Intervention i, InterventionStatus status) async {
    await InterventionsRepository().updateStatus(i.id, status);
    final user = await AuthRepository().currentUser();
    await AuditRepository().log(
      action: 'intervention.status',
      actor: user?.name ?? 'Teacher',
      target: i.studentId,
      detail: '${i.topic} → ${status.label}',
      reason: 'Intervention tracking',
    );
    if (mounted) setState(() => _data = _load());
  }

  Future<void> _reassess(Intervention i) async {
    final user = await AuthRepository().currentUser();
    if (user != null && !user.role.canCreateAssessmentOf(AssessmentType.remedial)) {
      if (!mounted) return;
      svSnack(
        context,
        'Remedial assessments are created by your school admin or '
        'headteacher.',
        error: true,
      );
      return;
    }
    if (!mounted) return;
    final created = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => AssessmentBuilderScreen(
        presets: AssessmentBuilderPresets(
          topicTitle: 'Reassessment — ${i.topic}',
          type: AssessmentType.remedial,
        ),
      ),
    ));
    if (created != true) return;
    final assessments = await AssessmentRepository().assessments();
    final createdAssessment = assessments.isNotEmpty
        ? assessments.last
        : null;
    if (createdAssessment == null) return;
    await InterventionsRepository().attachReassessment(
        i.id, createdAssessment.id);
    await AuditRepository().log(
      action: 'intervention.reassess',
      actor: 'Teacher',
      target: i.studentId,
      detail: 'Reassessment attached: ${createdAssessment.id}',
      reason: 'Reassess after intervention',
    );
    if (mounted) setState(() => _data = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Interventions'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add_task),
        label: const Text('New intervention'),
      ),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final (list, students, subs) =
              snap.data ?? (<Intervention>[], <Student>[], <AssessmentSubmission>[]);
          final names = {for (final s in students) s.id: s.fullName};
          final filtered = _filter == 'All'
              ? list
              : list
                  .where((i) => i.status == InterventionStatus.fromKey(_filter))
                  .toList();
          return Column(
            children: [
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  children: [
                    for (final f in [
                      'All',
                      ...InterventionStatus.values.map((s) => s.label),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(f),
                          selected: _filter == f ||
                              _filter ==
                                  InterventionStatus.values
                                      .where((s) => s.label == f)
                                      .map((s) => s.name)
                                      .firstOrNull,
                          onSelected: (_) => setState(() {
                            _filter = f == 'All'
                                ? 'All'
                                : InterventionStatus.values
                                    .where((s) => s.label == f)
                                    .first
                                    .name;
                          }),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? const Center(child: Text('No interventions match'))
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: filtered.length,
                        itemBuilder: (context, i) {
                          final it = filtered[i];
                          return SvEntrance(
                            delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
                            child: SvPressScale(
                              child: _InterventionCard(
                                intervention: it,
                                studentName: names[it.studentId] ?? it.studentId,
                                subs: subs,
                                onStatus: (s) => _setStatus(it, s),
                                onReassess: () => _reassess(it),
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

class _InterventionCard extends StatelessWidget {
  const _InterventionCard({
    required this.intervention,
    required this.studentName,
    required this.subs,
    required this.onStatus,
    required this.onReassess,
  });

  final Intervention intervention;
  final String studentName;
  final List<AssessmentSubmission> subs;
  final ValueChanged<InterventionStatus> onStatus;
  final VoidCallback onReassess;

  Color _statusColor(InterventionStatus s) => switch (s) {
        InterventionStatus.open => AppColors.warning,
        InterventionStatus.inProgress => AppTheme.brand,
        InterventionStatus.completed => AppColors.success,
        InterventionStatus.cancelled => AppColors.notAttempted,
      };

  @override
  Widget build(BuildContext context) {
    final it = intervention;
    final score = InterventionsRepository()
        .improvement(interventionId: it.id, subs: subs);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: ExpansionTile(
        leading: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                _statusColor(it.status),
                _statusColor(it.status).withValues(alpha: .58),
              ],
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            switch (it.status) {
              InterventionStatus.open => Icons.not_started_outlined,
              InterventionStatus.inProgress => Icons.rocket_launch_outlined,
              InterventionStatus.completed => Icons.task_alt,
              InterventionStatus.cancelled => Icons.cancel_outlined,
            },
            color: Colors.white,
            size: 22,
          ),
        ),
        title: Text('$studentName — ${it.topic}',
            style: const TextStyle(fontWeight: .w700)),
        subtitle: Text(
            '${it.status.label} · by ${it.assignedBy} · created ${it.createdDate}'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        childrenPadding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          const Divider(height: 1),
          ListTile(
            title: const Text('Action'),
            subtitle: Text(it.action),
          ),
          ListTile(
            title: const Text('Progress'),
            subtitle: FutureBuilder<(double?, double?)>(
              future: score,
              builder: (context, snap) {
                final data = snap.data ?? (null, null);
                final b = data.$1;
                final a = data.$2;
                final hasAfter = a != null;
                final beforeText = b == null
                    ? 'No prior result recorded'
                    : 'Before: ${b.toStringAsFixed(1)} marks';
                if (!hasAfter) {
                  return Text(
                      '$beforeText\nNo reassessment taken yet — '
                      'create one after support.');
                }
                final improved = a > (b ?? 0);
                return Text(
                    '$beforeText · After: ${a.toStringAsFixed(1)}'
                    '${improved ? ' ↑ improved' : ''}',
                    style: TextStyle(
                        color: improved
                            ? AppColors.success
                            : AppColors.danger,
                        fontWeight: FontWeight.w600));
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.replay, size: 16),
                  label: const Text('Create reassessment'),
                  onPressed: onReassess,
                ),
                for (final s in [
                  InterventionStatus.inProgress,
                  InterventionStatus.completed,
                ])
                  if (it.status != s)
                    ActionChip(
                      label: Text('Mark ${s.label.toLowerCase()}'),
                      onPressed: () => onStatus(s),
                    ),
                if (it.status == InterventionStatus.open)
                  ActionChip(
                    label: const Text('Cancel'),
                    onPressed: () =>
                        onStatus(InterventionStatus.cancelled),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StudentPicker extends StatelessWidget {
  const _StudentPicker({required this.students});

  final List<Student> students;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Select student',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.brand)),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: students.length,
                itemBuilder: (context, i) {
                  final s = students[i];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppTheme.brand.withValues(alpha: .12),
                      child: Text(s.initials),
                    ),
                    title: Text(s.fullName),
                    subtitle: Text('${s.id} · ${s.classId}'),
                    onTap: () => Navigator.pop(context, s),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}