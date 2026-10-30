import 'package:flutter/material.dart';

import '../../core/models/school_assets.dart';
import '../../core/models/subjects.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'resources_repository.dart';

class ResourcesScreen extends StatefulWidget {
  const ResourcesScreen({super.key});

  @override
  State<ResourcesScreen> createState() => _ResourcesScreenState();
}

class _ResourcesScreenState extends State<ResourcesScreen> {
  late Future<(List<ContentResource>, List<({String id, String name})>, bool)>
      _data;
  String _subject = 'All';

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(List<ContentResource>, List<({String id, String name})>, bool)>
      _load() async {
    final resources = await ResourcesRepository().all();
    final classes = await StudentsRepository().classes();
    final user = await AuthRepository().currentUser();
    return (resources, classes.map((c) => (id: c.id, name: c.displayName)).toList(), user?.isSchoolStaff ?? false);
  }

  void _refresh() => setState(() { _data = _load(); });

  Future<void> _add() async {
    final classes = (await _data).$2;
    if (!mounted) return;
    final title = TextEditingController();
    final body = TextEditingController();
    final topic = TextEditingController();
    String subjectId = 'MATH';
    String classId = classes.isNotEmpty ? classes.first.id : 'JHS2A';
    String kind = 'notes';
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AlertDialog(
          title: const Text('Add resource'),
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
                      DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: (v) => setSheet(() => classId = v ?? classId),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: kind,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: const [
                    DropdownMenuItem(value: 'notes', child: Text('Notes')),
                    DropdownMenuItem(value: 'worksheet', child: Text('Worksheet')),
                    DropdownMenuItem(value: 'video', child: Text('Video')),
                    DropdownMenuItem(value: 'lessonPlan', child: Text('Lesson plan')),
                  ],
                  onChanged: (v) => setSheet(() => kind = v ?? 'notes'),
                ),
                const SizedBox(height: 12),
                TextField(
                    controller: topic,
                    decoration: const InputDecoration(labelText: 'Topic')),
                const SizedBox(height: 12),
                TextField(
                    controller: body,
                    minLines: 3,
                    maxLines: 5,
                    decoration: const InputDecoration(labelText: 'Content')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (title.text.trim().isEmpty) return;
                final n = DateTime.now();
                await ResourcesRepository().add(
                  resource: ContentResource(
                    id: 'RES-${DateTime.now().millisecondsSinceEpoch}',
                    subjectId: subjectId,
                    classId: classId,
                    kind: kind,
                    title: title.text.trim(),
                    topic: topic.text.trim(),
                    body: body.text.trim(),
                    addedBy: 'Teacher',
                    addedOn:
                        '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}',
                  ),
                );
                if (ctx.mounted) Navigator.pop(ctx);
                _refresh();
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _delete(ContentResource r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete resource?'),
        content: Text(r.title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ResourcesRepository().delete(r.id);
      _refresh();
    }
  }

  IconData _kindIcon(String kind) => switch (kind) {
        'video' => Icons.play_circle_outline,
        'worksheet' => Icons.edit_note,
        'lessonPlan' => Icons.menu_book_outlined,
        _ => Icons.article_outlined,
      };

  Color _kindColor(String kind) => switch (kind) {
        'video' => AppTheme.brandLight,
        'worksheet' => AppTheme.navy500,
        'lessonPlan' => AppTheme.gold,
        _ => AppTheme.brand,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Learning Resources'),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final (resources, classes, editable) =
              snap.data ?? (<ContentResource>[], <({String id, String name})>[], false);
          final list = _subject == 'All'
              ? resources
              : resources.where((r) => r.subjectId == _subject).toList();
          return Column(
            children: [
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  children: [
                    for (final s in ['All', ...subjects.map((e) => e.id)])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(s == 'All' ? 'All' : subjectName(s)),
                          selected: _subject == s,
                          onSelected: (_) =>
                              setState(() => _subject = s),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? const Center(child: Text('No resources yet'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final r = list[i];
                          return SvEntrance(
                            delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
                            child: SvPressScale(
                              child: SvAvatarTile(
                              title: r.title,
                              meta:
                                  '${subjectName(r.subjectId)} · ${r.classId}'
                                  '${r.topic.isNotEmpty ? ' · ${r.topic}' : ''}'
                                  '\n${r.body}',
                              icon: _kindIcon(r.kind),
                              avatarColor: _kindColor(r.kind),
                              trailing: editable
                                  ? IconButton(
                                      tooltip: 'Delete ${r.title}',
                                      icon: Icon(
                                          Icons.delete_outline,
                                          color: AppColors.danger),
                                      onPressed: () => _delete(r),
                                    )
                                  : null,
                              onTap: () => showModalBottomSheet(
                                context: context,
                                builder: (ctx) => Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: SingleChildScrollView(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(r.title,
                                            style: const TextStyle(
                                                fontSize: 18,
                                                fontWeight: .w800)),
                                        const SizedBox(height: 6),
                                        Text(
                                            '${subjectName(r.subjectId)} · ${r.classId} · by ${r.addedBy} · ${r.addedOn}',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: AppColors.muted)),
                                        const Divider(height: 24),
                                        Text(r.body,
                                            style: const TextStyle(
                                                fontSize: 15, height: 1.5)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                        },
                       ),
              ),
              if (editable) ...[],
            ],
          );
        },
      ),
      floatingActionButton: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          final editable = snap.data?.$3 ?? false;
          if (!editable || snap.connectionState != ConnectionState.done) {
            return const SizedBox.shrink();
          }
          return FloatingActionButton.extended(
            onPressed: _add,
            icon: const Icon(Icons.add),
            label: const Text('Add resource'),
          );
        },
      ),
    );
  }
}