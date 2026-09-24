import 'package:flutter/material.dart';

import '../../core/models/announcement.dart';
import '../../core/models/class_room.dart';
import '../../core/models/user.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'announcements_repository.dart';

class AnnouncementsScreen extends StatefulWidget {
  const AnnouncementsScreen({super.key});

  @override
  State<AnnouncementsScreen> createState() => _AnnouncementsScreenState();
}

class _AnnouncementsScreenState extends State<AnnouncementsScreen> {
  late Future<AnnouncementsData> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  void _refresh() => setState(() => _data = _load());

  Future<AnnouncementsData> _load() async {
    final user = await AuthRepository().currentUser();
    if (user == null) {
      throw StateError('You need to be signed in to view announcements.');
    }
    final students = await StudentsRepository().active();
    final announcements =
        await AnnouncementsRepository().visibleFor(user, students);
    final classes = await StudentsRepository().classes();
    return AnnouncementsData(
        user: user, announcements: announcements, classes: classes);
  }

  Future<void> _create() async {
    final user = await AuthRepository().currentUser();
    if (user == null || !mounted) return;
    final classes = await StudentsRepository().classes();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _CreateAnnouncementDialog(
        user: user,
        classes: classes,
        onSubmit: () {
          if (mounted) _refresh();
        },
      ),
    );
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Announcements'),
      body: FutureBuilder<AnnouncementsData>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return SvErrorState(
              title: "Couldn't load announcements",
              message: 'Something went wrong loading announcements. '
                  'Please try again.',
              onRetry: _refresh,
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const SvLoading(message: 'Loading announcements…');
          }
          final d = snap.data;
          if (d == null) return const SvErrorState();
          final canPost =
              d.user.isSchoolStaff || d.user.role.isTeacher;
          final emergency =
              d.announcements.where((a) => a.isEmergency).toList();
          final rest = d.announcements
              .where((a) => !a.isEmergency)
              .toList();
          if (d.announcements.isEmpty) {
            return SvEmptyState(
              icon: Icons.campaign_outlined,
              title: 'No announcements yet',
              message: 'School-wide updates will appear here.',
              actionLabel: canPost ? 'Post announcement' : null,
              onAction: canPost ? _create : null,
            );
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (canPost)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: FilledButton.icon(
                    onPressed: _create,
                    icon: const Icon(Icons.add_alert_outlined),
                    label: const Text('Post announcement'),
                  ),
                ),
              for (final (i, a) in emergency.indexed) _card(d, a, i),
              if (rest.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.only(top: 8, bottom: 4),
                  child: Text('School & class notices',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                for (final (i, a) in rest.indexed) _card(d, a, i),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _card(AnnouncementsData d, Announcement a, int i) {
    final own = a.authorId == d.user.id;
    final canDelete = d.user.isSchoolStaff || own;
    final colors = a.isEmergency
        ? (bg: AppColors.warningBg, fg: AppColors.warning, ic: Icons.warning_amber_rounded)
        : a.audience == AnnouncementAudience.classes
            ? (bg: AppColors.infoBg, fg: AppColors.info, ic: Icons.groups_outlined)
            : (bg: AppTheme.gold.withValues(alpha: .14), fg: AppTheme.gold, ic: Icons.campaign_outlined);
    return SvEntrance(
      delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
      child: SvPressScale(
        child: Card(
      color: colors.bg,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(colors.ic, color: colors.fg),
        title: Text(a.title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(a.body),
            const SizedBox(height: 6),
            Text(
              '${a.audience.label} · ${_classLabel(a, d.classes)}'
              ' · ${a.authorName} · ${a.timestamp}',
              style: TextStyle(fontSize: 11, color: AppColors.body),
            ),
          ],
        ),
        isThreeLine: true,
        trailing: canDelete
            ? IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await AnnouncementsRepository().delete(a.id);
                  if (mounted) _refresh();
                },
              )
            : null,
      ),
    ),
    ),
    );
  }

  String _classLabel(Announcement a, List<ClassRoom> classes) {
    for (final c in classes) {
      if (c.id == a.targetClassId) return c.displayName;
    }
    return 'School';
  }
}

enum _Scope {
  school('Whole school', AnnouncementAudience.school),
  classes('Selected classes', AnnouncementAudience.classes),
  emergency('Emergency', AnnouncementAudience.emergency);

  const _Scope(this.label, this.value);
  final String label;
  final AnnouncementAudience value;
}

class _CreateAnnouncementDialog extends StatefulWidget {
  final User user;
  final List<ClassRoom> classes;
  final VoidCallback onSubmit;

  const _CreateAnnouncementDialog({
    required this.user,
    required this.classes,
    required this.onSubmit,
  });

  @override
  State<_CreateAnnouncementDialog> createState() =>
      _CreateAnnouncementDialogState();
}

class _CreateAnnouncementDialogState extends State<_CreateAnnouncementDialog> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  _Scope _scope = _Scope.school;
  String? _classId;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty || _body.text.trim().isEmpty) {
      svSnack(context, 'Add a title and message first.', error: true);
      return;
    }
    await AnnouncementsRepository().create(
      title: _title.text,
      body: _body.text,
      audience: _scope.value,
      targetClassId: _scope == _Scope.classes ? _classId : null,
      authorId: widget.user.id,
      authorName: widget.user.name,
    );
    widget.onSubmit();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Post announcement'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              decoration: const InputDecoration(
                  labelText: 'Title', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _body,
              maxLines: 3,
              decoration: const InputDecoration(
                  labelText: 'Message',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final s in _Scope.values)
                  ChoiceChip(
                    label: Text(s.label),
                    selected: _scope == s,
                    onSelected: (_) => setState(() {
                      _scope = s;
                      if (s != _Scope.classes) _classId = null;
                    }),
                  ),
              ],
            ),
            if (_scope == _Scope.classes) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: widget.classes.isNotEmpty
                    ? widget.classes.first.id
                    : null,
                decoration: const InputDecoration(
                    labelText: 'Class', border: OutlineInputBorder()),
                items: [
                  for (final c in widget.classes)
                    DropdownMenuItem(value: c.id, child: Text(c.displayName)),
                ],
                onChanged: (v) => setState(() => _classId = v),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Posted announcements also appear in Messages and the '
              'Notifications inbox.',
              style: TextStyle(fontSize: 11, color: AppColors.muted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Post'),
        ),
      ],
    );
  }
}

class AnnouncementsData {
  final User user;
  final List<Announcement> announcements;
  final List<ClassRoom> classes;

  const AnnouncementsData({
    required this.user,
    required this.announcements,
    required this.classes,
  });
}