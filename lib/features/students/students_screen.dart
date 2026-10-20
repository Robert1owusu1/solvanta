import 'package:flutter/material.dart';

import '../../../core/models/class_room.dart';
import '../../../core/models/student.dart';
import '../../../core/models/user.dart';
import '../../../core/responsive.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../audit/audit_repository.dart';
import 'student_editor_screen.dart';
import 'student_profile_screen.dart';
import 'students_repository.dart';

class StudentsScreen extends StatefulWidget {
  const StudentsScreen({super.key});

  @override
  State<StudentsScreen> createState() => _StudentsScreenState();
}

class _StudentsScreenState extends State<StudentsScreen> {
  late Future<(List<Student>, List<ClassRoom>, User?)> _data;
  String _query = '';
  String _classFilter = '';
  String _statusFilter = 'Active';
  bool _canManage = false;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(List<Student>, List<ClassRoom>, User?)> _load() async {
    final user = await AuthRepository().currentUser();
    final students = await StudentsRepository().visibleToUser(user);
    final classes = await StudentsRepository().classes();
    // Enrolling/transferring/promoting is admin work (doc §10); teachers and
    // staff get a read-only class roll here.
    _canManage = user?.role.canAdministerStudents ?? false;
    return (students, classes, user);
  }

  void _refresh() => setState(() => _data = _load());

  List<Student> _filtered(List<Student> students) {
    final q = _query.trim().toLowerCase();
    return students.where((s) {
      if (_classFilter.isNotEmpty && s.classId != _classFilter) return false;
      if (_statusFilter.isNotEmpty && s.status != _statusFilter) return false;
      if (q.isEmpty) return true;
      return s.fullName.toLowerCase().contains(q) ||
          s.admissionNo.toLowerCase().contains(q) ||
          s.id.toLowerCase().contains(q);
    }).toList()
      ..sort((a, b) => a.fullName.compareTo(b.fullName));
  }

  Future<void> _enroll() async {
    final result = await Navigator.of(context)
        .push<Student>(MaterialPageRoute(
      builder: (_) => const StudentEditorScreen(),
    ));
    if (result != null) _refresh();
  }

  Future<void> _transfer(Student s) async {
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
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (chosen == null || chosen == s.classId) {
                Navigator.pop(ctx);
                return;
              }
              await StudentsRepository()
                  .saveStudent(s.copyWith(classId: chosen));
              await AuditRepository().log(
                action: 'student.transfer',
                actor: 'Admin',
                target: s.id,
                detail: '${s.fullName} moved to $chosen',
                reason: 'Class transfer',
              );
              if (ctx.mounted) Navigator.pop(ctx);
          _refresh();
            },
            child: const Text('Transfer'),
          ),
        ],
      ),
    );
  }

  Future<void> _promote(Student s) async {
    final next = s.promotedToClass();
    if (next == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('This student is already in the highest class'),
          behavior: .floating));
      return;
    }
    await StudentsRepository().saveStudent(s.copyWith(classId: next));
    await AuditRepository().log(
      action: 'student.promote',
      actor: 'Admin',
      target: s.id,
      detail: '${s.fullName} promoted to $next',
      reason: 'End of term promotion',
    );
    _refresh();
  }

  Future<void> _graduate(Student s) async {
    await StudentsRepository().saveStudent(s.copyWith(status: 'Graduated'));
    await AuditRepository().log(
      action: 'student.graduate',
      actor: 'Admin',
      target: s.id,
      detail: '${s.fullName} graduated',
      reason: 'Graduation',
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Students'),
      floatingActionButton: _canManage
          ? FloatingActionButton.extended(
              onPressed: _enroll,
              icon: const Icon(Icons.person_add),
              label: const Text('Enroll'),
            )
          : null,
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SvLoading();
          }
          if (snap.hasError) {
            return SvErrorState(
              message: 'Could not load students',
              onRetry: _refresh,
            );
          }
          final students = snap.data?.$1 ?? const <Student>[];
          final classes = snap.data?.$2 ?? const <ClassRoom>[];
          final filtered = _filtered(students);
          return Column(
            children: [
              SvSearchField(
                hint: 'Search by name or admission number',
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 10),
              SvFilterChips(
                options: [
                  SvFilterOption('All',
                      selected: _classFilter.isEmpty),
                  for (final c in classes)
                    SvFilterOption(c.displayName,
                        selected: _classFilter == c.id, value: c.id),
                ],
                onSelected: (i) => setState(() {
                  _classFilter =
                      i == 0 ? '' : classes[i - 1].id;
                }),
              ),
              const SizedBox(height: 10),
              SvFilterChips(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                options: [
                  for (final st in const [
                    'Active', 'Graduated', 'Transferred'
                  ])
                    SvFilterOption(st, selected: _statusFilter == st),
                ],
                onSelected: (i) => setState(() {
                  _statusFilter =
                      const ['Active', 'Graduated', 'Transferred'][i];
                }),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: filtered.isEmpty
                    ? (students.isEmpty
                        ? const SvEmptyState(
                            icon: Icons.person_add_alt_outlined,
                            title: 'No students yet',
                            message:
                                'Enroll the first student to start tracking attendance and marks.',
                          )
                        : const SvEmptyState(
                            icon: Icons.search_off_outlined,
                            title: 'No students match',
                            message:
                                'Try a different search term, class, or status filter.',
                          ))
                    : ResponsiveBuilder(
                        phone: (context) => ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (context, i) {
                            final s = filtered[i];
                            return SvEntrance(
                              delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
                              child: SvPressScale(
                                child: _studentTile(s, _canManage),
                              ),
                            );
                          },
                        ),
                        tablet: (context) => _StudentGrid(students: filtered, canManage: _canManage),
                        desktop: (context) => _StudentGrid(students: filtered, canManage: _canManage, minItemWidth: 340),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _studentTile(Student s, bool canManage) {
    final badge = switch (s.status) {
      'Graduated' => svStatus('Graduated', Icons.workspace_premium,
          AppColors.info),
      'Transferred' =>
        svStatus('Transferred', Icons.swap_horiz, AppColors.muted),
      'Leaver' => svStatus('Leaver', Icons.person_off, AppColors.muted),
      _ => svStatus('Active', Icons.check_circle, AppColors.success),
    };
    final menu = PopupMenuButton<String>(
      tooltip: 'Manage ${s.fullName}',
      onSelected: (v) => switch (v) {
        'edit' => Navigator.of(context)
            .push(MaterialPageRoute(
              builder: (_) => StudentEditorScreen(initial: s),
            ))
            .then((_) => _refresh()),
        'profile' => Navigator.of(context)
            .push(MaterialPageRoute(
              builder: (_) => StudentProfileScreen(
                  studentId: s.id, showAdminActions: true),
            ))
            .then((_) => _refresh()),
        'transfer' => _transfer(s),
        'promote' => _promote(s),
        'graduate' => _graduate(s),
        _ => null,
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'edit', child: Text('Edit student')),
        PopupMenuItem(
            value: 'profile', child: Text('Open profile')),
        PopupMenuItem(
            value: 'transfer', child: Text('Transfer class')),
        PopupMenuItem(
            value: 'promote', child: Text('Promote class')),
        PopupMenuItem(
            value: 'graduate', child: Text('Mark graduated')),
      ],
    );
    return SvAvatarTile(
      title: s.fullName,
      meta: '${s.id} · ${s.admissionNo} · ${s.classId}',
      initials: s.initials,
      chip: canManage ? null : badge,
      trailing: canManage
          ? Row(mainAxisSize: MainAxisSize.min, children: [badge, menu])
          : null,
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(
            builder: (_) => StudentProfileScreen(
                studentId: s.id, showAdminActions: canManage),
          ))
          .then((_) => _refresh()),
    );
  }
}

class _StudentGrid extends StatelessWidget {
  const _StudentGrid({required this.students, required this.canManage, this.minItemWidth = 300});

  final List<Student> students;
  final bool canManage;
  final double minItemWidth;

  @override
  Widget build(BuildContext context) {
    return ResponsiveGridView(
      minItemWidth: minItemWidth,
      maxColumns: 4,
      minColumns: 2,
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      padding: const EdgeInsets.all(16),
      baseAspectRatio: 1.4,
      children: [
        for (var i = 0; i < students.length; i++)
          SvEntrance(
            delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
            child: _StudentGridCard(student: students[i], canManage: canManage),
          ),
      ],
    );
  }
}

class _StudentGridCard extends StatelessWidget {
  const _StudentGridCard({required this.student, required this.canManage});

  final Student student;
  final bool canManage;

  @override
  Widget build(BuildContext context) {
    final badge = switch (student.status) {
      'Graduated' => svStatus('Graduated', Icons.workspace_premium, AppColors.info),
      'Transferred' => svStatus('Transferred', Icons.swap_horiz, AppColors.muted),
      'Leaver' => svStatus('Leaver', Icons.person_off, AppColors.muted),
      _ => svStatus('Active', Icons.check_circle, AppColors.success),
    };

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => StudentProfileScreen(
              studentId: student.id,
              showAdminActions: canManage,
            ),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [AppTheme.navy900, AppTheme.navy700],
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Center(
                      child: Text(
                        student.initials,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          student.fullName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: AppColors.ink,
                          ),
                        ),
                        Text(
                          student.admissionNo,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  badge,
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  Icon(Icons.class_outlined, size: 14, color: AppColors.muted),
                  const SizedBox(width: 4),
                  Text(
                    student.classId,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.muted,
                    ),
                  ),
                  if (canManage) ...[
                    const Spacer(),
                    IconButton(
                      onPressed: () {
                        // Show context menu
                      },
                      icon: Icon(Icons.more_vert, color: AppColors.muted, size: 20),
                      tooltip: 'More options',
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}