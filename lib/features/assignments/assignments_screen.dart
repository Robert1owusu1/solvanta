import 'package:flutter/material.dart';

import '../../core/models/assignment.dart';
import '../../core/models/class_room.dart';
import '../../core/models/subjects.dart';
import '../../core/models/user.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../assessment/marking_scheme_editor_screen.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'assignment_capture_screen.dart';
import 'assignments_repository.dart';

class AssignmentsScreen extends StatefulWidget {
  const AssignmentsScreen({super.key});

  @override
  State<AssignmentsScreen> createState() => _AssignmentsScreenState();
}

class _AssignmentsScreenState extends State<AssignmentsScreen> {
  late Future<(List<Assignment>, List<ClassRoom>, User?)> _data;
  String _filter = 'All';

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(List<Assignment>, List<ClassRoom>, User?)> _load() async {
    final assignments = await AssignmentsRepository().all();
    final classes = await StudentsRepository().classes();
    final user = await AuthRepository().currentUser();
    return (assignments, classes, user);
  }

  void _refresh() => setState(() => _data = _load());

  List<Assignment> _visible(List<Assignment> all, User? user) {
    if (user == null) return all;
    if (user.role.isTeacher || user.role.isSchoolStaff) {
      return all.where((a) {
        if (_filter == 'Mine') return a.createdBy == user.name;
        if (_filter == 'My class') return a.classId == user.classId;
        return true;
      }).toList();
    }
    final classId = _studentClass(user);
    return all.where((a) => a.classId == classId).toList();
  }

  String? _studentClass(User user) {
    if (user.classId != null) return user.classId;
    return null;
  }

  Future<void> _create() async {
    final classes = (await _data).$2;
    if (!mounted) return;
    final title = TextEditingController();
    final instructions = TextEditingController();
    final deadline = TextEditingController(text: '2026-10-01');
    String subjectId = 'MATH';
    String classId = classes.isNotEmpty ? classes.first.id : 'JHS2A';
    final user = await AuthRepository().currentUser();
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AlertDialog(
          title: const Text('New assignment'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: title,
                    decoration: const InputDecoration(labelText: 'Title')),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: subjectId,
                  decoration: const InputDecoration(labelText: 'Subject'),
                  items: [
                    for (final s in subjects)
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (v) => setSheet(() => subjectId = v ?? 'MATH'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: classId,
                  decoration: const InputDecoration(labelText: 'Class'),
                  items: [
                    for (final c in classes)
                      DropdownMenuItem(value: c.id, child: Text(c.displayName)),
                  ],
                  onChanged: (v) => setSheet(() => classId = v ?? classId),
                ),
                const SizedBox(height: 12),
                _DeadlineField(deadline: deadline),
                const SizedBox(height: 12),
                TextField(
                    controller: instructions,
                    minLines: 3,
                    maxLines: 5,
                    decoration: const InputDecoration(
                        labelText: 'Instructions')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (title.text.trim().isEmpty) return;
                await AssignmentsRepository().create(
                  classId: classId,
                  subjectId: subjectId,
                  title: title.text.trim(),
                  instructions: instructions.text.trim(),
                  deadline: deadline.text.trim(),
                  createdBy: user?.name ?? 'Teacher',
                );
                if (ctx.mounted) Navigator.pop(ctx);
                _refresh();
              },
              child: const Text('Assign'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleDone(Assignment a, User user) async {
    final studentId = user.role.isStudent
        ? user.id.replaceFirst('USR-', '')
        : null;
    if (studentId == null) return;
    final student = await StudentsRepository().byId(studentId);
    if (student == null) return;
    await AssignmentsRepository().setCompleted(
      a.id,
      student,
      !a.completedBy.contains(studentId),
    );
    _refresh();
  }

  Future<void> _delete(Assignment a) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Delete assignment?'),
        content: const Text(
            'This removes the assignment for every student. Completed work '
            'already submitted stays on record.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await AssignmentsRepository().delete(a.id);
    if (!mounted) return;
    svSnack(context, 'Assignment deleted');
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Assignments'),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return SvErrorState(
              title: "Couldn't load assignments",
              message: 'We couldn\'t load the assignment list. '
                  'Please try again.',
              onRetry: _refresh,
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const SvLoading(message: 'Loading assignments…');
          }
          final (all, classes, user) =
              snap.data ?? (<Assignment>[], <ClassRoom>[], null);
          final isStaff = user != null && user.isSchoolStaff;
          final list = _visible(all, user);
          return Column(
            children: [
              if (isStaff)
                SizedBox(
                  height: 52,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    children: [
                      for (final f in const ['All', 'Mine', 'My class'])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(f),
                            selected: _filter == f,
                            onSelected: (_) =>
                                setState(() => _filter = f),
                          ),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: list.isEmpty
                    ? SvEmptyState(
                        icon: Icons.assignment_outlined,
                        title: isStaff
                            ? 'No assignments yet'
                            : 'Nothing assigned right now',
                        message: isStaff
                            ? 'Assign homework with a subject, class and '
                                'deadline so students know what to do and '
                                'when.'
                            : 'When a teacher assigns homework it will '
                                'appear here for you to complete.',
                        actionLabel: isStaff ? 'Create an assignment' : null,
                        onAction: isStaff ? _create : null,
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final a = list[i];
                          final overdue = _isOverdue(a);
                          return SvEntrance(
                            delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
                            child: SvPressScale(
                              child: SvAvatarTile(
                              title: a.title,
                              meta:
                                  '${subjectName(a.subjectId)} · ${a.classId} · due ${svFormatDate(a.deadline)}'
                                  '\n${a.instructions}'
                                  '\nby ${a.createdBy} · ${a.completedBy.length} completed',
                              icon: Icons.assignment_outlined,
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (overdue && isStaff)
                                    Padding(
                                      padding: EdgeInsets.only(right: 6),
                                      child: SvStatusBadge(
                                        label: 'Overdue',
                                        icon: Icons.schedule,
                                        color: AppColors.danger,
                                      ),
                                    ),
                                  if (isStaff)
                                    IconButton(
                                      icon: const Icon(
                                          Icons.photo_camera_outlined,
                                          size: 20),
                                      color: AppTheme.brand,
                                      tooltip: 'Submit photos of work',
                                      onPressed: () async {
                                        final changed = await Navigator.of(
                                                context)
                                            .push<bool>(
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                AssignmentStudentPickerScreen(
                                                    assignment: a),
                                          ),
                                        );
                                        if (changed == true && mounted) {
                                          _refresh();
                                        }
                                      },
                                    ),
                                  if (isStaff)
                                    IconButton(
                                      icon: const Icon(
                                          Icons.assignment_turned_in_outlined,
                                          size: 20),
                                      color: AppTheme.brand,
                                      tooltip: 'Marking scheme',
                                      onPressed: () => Navigator.of(context)
                                          .push(
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              MarkingSchemeEditorScreen(
                                                  assignment: a),
                                        ),
                                      ),
                                    ),
                                  if (isStaff)
                                    IconButton(
                                      tooltip: 'Delete assignment',
                                      icon: Icon(
                                          Icons.delete_outline,
                                          color: AppColors.danger),
                                      onPressed: () => _delete(a),
                                    ),
                                ],
                              ),
                              onTap: isStaff
                                  ? null
                                  : () => _toggleDone(a, user!),
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
      floatingActionButton: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          final user = snap.data?.$3;
          // Assignment creation is teacher+ (doc §41); general staff,
          // parents and students are read-only.
          if (user == null || !user.role.canCreateAssignments) {
            return const SizedBox.shrink();
          }
          return FloatingActionButton.extended(
            onPressed: _create,
            icon: const Icon(Icons.add),
            label: const Text('New assignment'),
          );
        },
      ),
    );
  }
}

class _DeadlineField extends StatelessWidget {
  const _DeadlineField({required this.deadline});

  final TextEditingController deadline;

  Future<void> _pick(BuildContext context) async {
    final current = DateTime.tryParse(deadline.text);
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime(2026, 10, 1),
      firstDate: DateTime(2026, 1, 1),
      lastDate: DateTime(2030, 12, 31),
    );
    if (picked == null) return;
    deadline.text =
        '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: deadline,
      readOnly: true,
      onTap: () => _pick(context),
      decoration: InputDecoration(
        labelText: 'Deadline',
        hintText: 'Pick a due date',
        suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
      ),
    );
  }
}

bool _isOverdue(Assignment a) {
  final d = DateTime.tryParse(a.deadline.trim());
  if (d == null) return false;
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day)
      .isAfter(DateTime(d.year, d.month, d.day));
}