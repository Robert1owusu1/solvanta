import 'package:flutter/material.dart';

import '../../core/models/student.dart';
import '../../core/models/user.dart';
import '../../core/ui/ui_kit.dart';
import '../assessment/results_screen.dart';
import '../auth/auth_repository.dart';
import '../students/student_profile_screen.dart';
import '../students/students_repository.dart';

class ParentChildViewScreen extends StatelessWidget {
  const ParentChildViewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _ParentScaffold(
      title: 'My Child',
      builder: (student) =>
          StudentProfileScreen(studentId: student.id, showAppBar: false),
    );
  }
}

class ParentResultsScreen extends StatelessWidget {
  const ParentResultsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _ParentScaffold(
      title: 'Results',
      builder: (student) => ResultsScreen(
        studentId: student.id,
        title: '${student.firstName} — Results',
        showAppBar: false,
      ),
    );
  }
}

/// Loads the signed-in parent and, if they have multiple children, shows a
/// child switcher in the app bar before rendering the child content.
class _ParentScaffold extends StatefulWidget {
  const _ParentScaffold({required this.title, required this.builder});

  final String title;
  final Widget Function(Student student) builder;

  @override
  State<_ParentScaffold> createState() => _ParentScaffoldState();
}

class _ParentScaffoldState extends State<_ParentScaffold> {
  late Future<(User?, List<Student>)> _data;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(User?, List<Student>)> _load() async {
    final user = await AuthRepository().currentUser();
    if (user == null) return (null, const <Student>[]);
    // Prefer students linked to this user (both mechanisms).
    final linked =
        await StudentsRepository().byParentUserAll(user.id);
    final extra = await StudentsRepository().byParentAll(user);
    final seen = <String>{};
    final children = <Student>[];
    for (final s in [...linked, ...extra]) {
      if (seen.add(s.id)) children.add(s);
    }
    return (user, children);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _data,
      builder: (context, snap) {
        final user = snap.data?.$1;
        final children = snap.data?.$2 ?? const <Student>[];
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (user == null) {
          return const Scaffold(body: Center(child: Text('Not signed in')));
        }
        if (children.isEmpty) {
          return const Scaffold(
            body: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No child linked to this account yet. Ask the school to '
                  'link your child so you can see their progress.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        if (_index >= children.length) _index = children.length - 1;
        final student = children[_index];
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.title),
            actions: [
              if (children.length > 1)
                PopupMenuButton<String>(
                  tooltip: '${student.firstName} — switch child',
                  onSelected: (v) {
                    final i = int.tryParse(v);
                    if (i != null) setState(() => _index = i);
                  },
                  itemBuilder: (_) => [
                    for (var i = 0; i < children.length; i++)
                      PopupMenuItem(
                        value: '$i',
                        child: Row(
                          children: [
                            Icon(
                              i == _index
                                  ? Icons.check_circle
                                  : Icons.child_care,
                              size: 18,
                              color: i == _index
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                            const SizedBox(width: 10),
                            Text(children[i].fullName),
                          ],
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.swap_horiz, size: 20),
                        const SizedBox(width: 6),
                        Text(student.firstName),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          body: KeyedSubtree(
            key: ValueKey(student.id),
            child: widget.builder(student),
          ),
        );
      },
    );
  }
}

/// Resolves the signed-in student's own record id and builds [builder] with
/// it. Shows a spinner while the session loads rather than flashing
/// "Not signed in" on every open.
class _OwnStudentId extends StatefulWidget {
  const _OwnStudentId({required this.builder});

  final Widget Function(String studentId) builder;

  @override
  State<_OwnStudentId> createState() => _OwnStudentIdState();
}

class _OwnStudentIdState extends State<_OwnStudentId> {
  late final Future<User?> _user = AuthRepository().currentUser();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<User?>(
      future: _user,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: SvLoading());
        }
        final user = snap.data;
        if (user == null) {
          return const Scaffold(body: Center(child: Text('Not signed in')));
        }
        // Derive student ID from the user's linked studentIds, not from the
        // user ID pattern (which assumes USR-STU-xxx format and breaks for
        // manually created accounts or migrated data).
        final studentId = user.studentIds.isNotEmpty
            ? user.studentIds.first
            : user.id.replaceFirst('USR-', '');
        return widget.builder(studentId);
      },
    );
  }
}

class StudentResultsScreen extends StatelessWidget {
  const StudentResultsScreen({super.key});

  @override
  Widget build(BuildContext context) => _OwnStudentId(
        builder: (id) => ResultsScreen(studentId: id, title: 'My Results'),
      );
}

class StudentSelfViewScreen extends StatelessWidget {
  const StudentSelfViewScreen({super.key});

  @override
  Widget build(BuildContext context) => _OwnStudentId(
        builder: (id) => StudentProfileScreen(studentId: id),
      );
}
