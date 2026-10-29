import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/assessment.dart';
import '../../../core/models/student.dart';
import '../../../core/models/subjects.dart';
import '../../../core/models/user.dart';
import '../../../core/theme/app_theme.dart';
import '../../assessment/assessment_repository.dart';
import '../../assessment/capture_screen.dart';
import '../../search/global_search_screen.dart';
import '../../students/student_profile_screen.dart';
import '../../students/students_repository.dart';
import 'dashboard_scaffold.dart';

/// One thing the palette can open.
class PaletteEntry {
  const PaletteEntry({
    required this.group,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.run,
  });

  final String group;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback run;
}

/// Ctrl/⌘+K: one box to jump to a menu item and, for staff, a student or an
/// assessment. Arrow keys move, Enter opens, Esc closes. The last entry
/// hands the words to the full search (messages and alerts).
Future<void> showCommandPalette(
  BuildContext context, {
  required User user,
  required List<Module> modules,
  required void Function(Module) onModule,
  required void Function(WidgetBuilder) onPush,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close search',
    barrierColor: Colors.black.withValues(alpha: .35),
    pageBuilder: (context, _, _) => _Palette(user: user, modules: modules, onModule: onModule, onPush: onPush),
  );
}

class _Palette extends StatefulWidget {
  const _Palette({required this.user, required this.modules, required this.onModule, required this.onPush});

  final User user;
  final List<Module> modules;
  final void Function(Module) onModule;
  final void Function(WidgetBuilder) onPush;

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  final _controller = TextEditingController();
  var _selected = 0;
  var _students = const <Student>[];
  var _assessments = const <Assessment>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Records only for staff: a family reaches its own through the menu.
  Future<void> _load() async {
    if (!widget.user.isSchoolStaff) return;
    final students = await StudentsRepository().visibleToUser(widget.user);
    final assessments = await AssessmentRepository().assessments();
    if (mounted) {
      setState(() {
        _students = students;
        _assessments = assessments;
      });
    }
  }

  void _close() => Navigator.of(context).pop();

  List<PaletteEntry> _entries() {
    final q = _controller.text.trim().toLowerCase();
    bool has(String s) => s.toLowerCase().contains(q);
    final out = <PaletteEntry>[
      for (final m in widget.modules.where((m) => q.isEmpty || has(m.label) || has(m.subtitle)).take(q.isEmpty ? 6 : 8))
        PaletteEntry(
          group: 'Menu',
          icon: m.icon,
          title: m.label,
          subtitle: '${m.section.label} · ${m.subtitle}',
          run: () => widget.onModule(m),
        ),
    ];
    if (q.isNotEmpty) {
      out.addAll([
        for (final s in _students.where((s) => has(s.fullName) || has(s.admissionNo) || has(s.id)).take(6))
          PaletteEntry(
            group: 'Students',
            icon: Icons.person_outline,
            title: s.fullName,
            subtitle: '${s.classId} · ${s.admissionNo}',
            run: () => widget.onPush((_) => StudentProfileScreen(studentId: s.id)),
          ),
        for (final a in _assessments.where((a) => has(a.title) || has(subjectName(a.subjectId))).take(4))
          PaletteEntry(
            group: 'Assessments',
            icon: Icons.assignment_outlined,
            title: a.title,
            subtitle: '${a.type.label} · ${subjectName(a.subjectId)} · ${a.classId} · ${a.date}',
            run: () => widget.onPush((_) => CaptureScreen(assessment: a)),
          ),
        PaletteEntry(
          group: 'More',
          icon: Icons.manage_search,
          title: 'Search messages and alerts for "${_controller.text.trim()}"',
          subtitle: 'Opens the full search',
          run: () => widget.onPush((_) => const GlobalSearchScreen()),
        ),
      ]);
    }
    return out;
  }

  /// Moves the choice by [step], wrapping; reads the current list, so key
  /// presses faster than a frame still land where they should.
  void _move(int step) {
    final n = _entries().length;
    if (n == 0) return;
    setState(() => _selected = ((_selected.clamp(0, n - 1) + step) % n + n) % n);
  }

  void _run(PaletteEntry e) {
    _close();
    e.run();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries();
    final selected = entries.isEmpty ? 0 : _selected.clamp(0, entries.length - 1);
    final width = MediaQuery.sizeOf(context).width;
    return Align(
      alignment: const Alignment(0, -.6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 600, maxHeight: MediaQuery.sizeOf(context).height * .7),
          child: Material(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            elevation: 12,
            child: SizedBox(
              width: width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
                      const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
                      const SingleActivator(LogicalKeyboardKey.escape): _close,
                    },
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      onChanged: (_) => setState(() => _selected = 0),
                      onSubmitted: (_) {
                        if (entries.isNotEmpty) _run(entries[selected]);
                      },
                      style: TextStyle(fontSize: 16, color: AppColors.ink),
                      decoration: InputDecoration(
                        hintText: widget.user.isSchoolStaff
                            ? 'Jump to a page, student or assessment…'
                            : 'Jump to a page…',
                        prefixIcon: Icon(Icons.search, color: AppColors.muted),
                        suffixIcon: Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Center(
                            widthFactor: 1,
                            child: Text('Esc', style: TextStyle(fontSize: 11, color: AppColors.muted)),
                          ),
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 18),
                      ),
                    ),
                  ),
                  Divider(height: 1, color: AppColors.border),
                  Flexible(
                    child: entries.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text('Nothing matches.', style: TextStyle(color: AppColors.muted)),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            itemCount: entries.length,
                            itemBuilder: (context, i) {
                              final e = entries[i];
                              final header = i == 0 || entries[i - 1].group != e.group;
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (header)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                                      child: Text(e.group.toUpperCase(),
                                          style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: .8,
                                              color: AppColors.muted)),
                                    ),
                                  ListTile(
                                    dense: true,
                                    selected: i == selected,
                                    selectedTileColor: AppColors.brand.withValues(alpha: .1),
                                    leading: Icon(e.icon, color: AppColors.brand),
                                    title: Text(e.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink)),
                                    subtitle: Text(e.subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(color: AppColors.muted)),
                                    onTap: () => _run(e),
                                  ),
                                ],
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
