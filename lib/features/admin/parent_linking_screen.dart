import 'package:flutter/material.dart';

import '../../core/models/student.dart';
import '../../core/models/user.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../audit/audit_repository.dart';
import '../students/students_repository.dart';
import 'admin_repository.dart';
import 'reset_password_dialog.dart';

class ParentLinkingScreen extends StatefulWidget {
  const ParentLinkingScreen({super.key});

  @override
  State<ParentLinkingScreen> createState() => _ParentLinkingScreenState();
}

class _ParentLinkingScreenState extends State<ParentLinkingScreen> {
  late Future<(List<User>, List<Student>)> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(List<User>, List<Student>)> _load() async {
    final parents = await AdminRepository().parentUsers();
    final students = await StudentsRepository().all();
    return (parents, students);
  }

  void _refresh() => setState(() { _data = _load(); });

  Future<void> _toggleLink(User parent, Student student) async {
    final isLinked = parent.studentIds.contains(student.id);
    final repo = AdminRepository();
    if (isLinked) {
      await repo.unlinkParentFromStudent(
          parentUserId: parent.id, studentId: student.id);
    } else {
      await repo.linkParentToStudent(
          parentUserId: parent.id, studentId: student.id);
    }
    await AuditRepository().log(
      action: isLinked ? 'parent.unlink' : 'parent.link',
      actor: 'Admin',
      target: parent.name,
      detail: '${isLinked ? 'Unlinked' : 'Linked'} ${student.fullName} '
          '(with ${student.parentUserId ?? 'no'})',
      reason: 'Parent-child linking',
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Link Parents to Children'),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final parents = snap.data?.$1 ?? const <User>[];
          final students = snap.data?.$2 ?? const <Student>[];
          if (parents.isEmpty) {
            return const Center(
                child: Text(
                    'No parent accounts yet — create them in Settings → Users or via enroll'));
          }
          return ExpansionTileList(
            parents: parents,
            students: students,
            onToggle: _toggleLink,
          );
        },
      ),
    );
  }
}

class ExpansionTileList extends StatelessWidget {
  const ExpansionTileList({
    super.key,
    required this.parents,
    required this.students,
    required this.onToggle,
  });

  final List<User> parents;
  final List<Student> students;
  final Future<void> Function(User parent, Student student) onToggle;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final p in parents)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ExpansionTile(
              leading: CircleAvatar(
                backgroundColor: AppTheme.brand.withValues(alpha: .12),
                child: const Text('P'),
              ),
              title: Text(p.name),
              subtitle: Text(
                  '${p.email} · ${p.studentIds.length} linked'),
              children: [
                const Divider(height: 1),
                for (final s in students)
                  CheckboxListTile(
                    dense: true,
                    value: p.studentIds.contains(s.id),
                    title: Text(s.fullName),
                    subtitle: Text('${s.id} · ${s.classId}'),
                    onChanged: (_) => onToggle(p, s),
                  ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    icon: const Icon(Icons.lock_reset, size: 18),
                    label: const Text('Reset password'),
                    onPressed: () => showResetPasswordDialog(context, p),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}