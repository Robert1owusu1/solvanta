import 'package:flutter/material.dart';

import '../../core/models/class_room.dart';
import '../../core/models/subjects.dart';
import '../../core/models/timetable.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'timetable_repository.dart';

class TimetableScreen extends StatefulWidget {
  const TimetableScreen({super.key});

  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends State<TimetableScreen> {
  late Future<(List<LessonSlot>, List<ClassRoom>, bool)> _data;
  String? _classId;
  int _dayIndex = 0;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(List<LessonSlot>, List<ClassRoom>, bool)> _load() async {
    final slots = await TimetableRepository().loadSlots();
    final classes = await StudentsRepository().classes();
    final user = await AuthRepository().currentUser();
    final editable = user != null && user.isSchoolStaff;
    return (slots, classes, editable);
  }

  void _refresh() => setState(() => _data = _load());

  String _initialsFor(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || name.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  Color _subjectColor(String id) {
    // Brand rule: decorative category colors come from the navy ramp plus the
    // single gold accent — no off-brand hues (was purple/teal/magenta).
    const palette = [
      AppTheme.navy900,
      AppTheme.navy700,
      AppTheme.navy500,
      AppTheme.navy400,
      AppTheme.navy300,
      AppTheme.navy200,
      AppTheme.navy700,
      AppTheme.gold,
    ];
    return palette[id.hashCode.abs() % palette.length];
  }

  Future<void> _editSlot({LessonSlot? existing}) async {
    final classes = (await _data).$2;
    if (!mounted) return;
    final start = TextEditingController(text: existing?.start ?? '08:00');
    final end = TextEditingController(text: existing?.end ?? '08:50');
    String weekday = existing?.weekday ?? kWeekdays[_dayIndex];
    String subjectId = existing?.subjectId ?? 'MATH';
    String classId = existing?.classId ?? (_classId ?? classes.first.id);

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AlertDialog(
          title: Text(existing == null ? 'Add lesson' : 'Edit lesson'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_classId == null)
                  DropdownButtonFormField<String>(
                    initialValue: classId,
                    decoration: const InputDecoration(labelText: 'Class'),
                    items: [
                      for (final c in classes)
                        DropdownMenuItem(
                            value: c.id, child: Text(c.displayName)),
                    ],
                    onChanged: (v) => setSheet(() => classId = v ?? classId),
                  ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: weekday,
                  decoration: const InputDecoration(labelText: 'Day'),
                  items: [
                    for (final d in kWeekdays)
                      DropdownMenuItem(value: d, child: Text(d)),
                  ],
                  onChanged: (v) => setSheet(() => weekday = v ?? weekday),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: subjectId,
                  decoration: const InputDecoration(labelText: 'Subject'),
                  items: [
                    for (final s in subjects)
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (v) => setSheet(() => subjectId = v ?? subjectId),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                          controller: start,
                          decoration:
                              const InputDecoration(labelText: 'Start (HH:MM)')),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                          controller: end,
                          decoration:
                              const InputDecoration(labelText: 'End (HH:MM)')),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () async {
                  final repo = TimetableRepository();
                  final slots = await repo.loadSlots();
                  await repo.saveSlots(
                      slots.where((s) => s.id != existing.id).toList());
                  if (ctx.mounted) Navigator.pop(ctx);
                  _refresh();
                },
                child: Text('Delete',
                    style: TextStyle(color: AppColors.danger)),
              ),
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final repo = TimetableRepository();
                final slots = await repo.loadSlots();
                final slot = LessonSlot(
                  id: existing?.id ??
                      'SLOT-${DateTime.now().millisecondsSinceEpoch}',
                  classId: _classId ?? classId,
                  weekday: weekday,
                  start: start.text.trim().isEmpty
                      ? '08:00'
                      : start.text.trim(),
                  end: end.text.trim().isEmpty ? '08:50' : end.text.trim(),
                  subjectId: subjectId,
                  teacherId: existing?.teacherId ?? '',
                );
                final without =
                    slots.where((s) => s.id != slot.id).toList();
                await repo.saveSlots([...without, slot]);
                if (ctx.mounted) Navigator.pop(ctx);
                _refresh();
              },
              child: Text(existing == null ? 'Add' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Timetable'),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final (slots, classes, editable) =
              snap.data ?? (<LessonSlot>[], <ClassRoom>[], false);
          if (_classId == null && classes.isNotEmpty) {
            _classId = classes.first.id;
          }
          final mine = slots.where((s) => s.classId == _classId).toList();
          final daySlots =
              mine.where((s) => s.weekday == kWeekdays[_dayIndex]).toList()
                ..sort((a, b) => a.start.compareTo(b.start));
          return Column(
            children: [
              if (classes.length > 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: DropdownButtonFormField<String>(
                    initialValue: _classId,
                    decoration: const InputDecoration(
                        labelText: 'Class', isDense: true),
                    items: [
                      for (final c in classes)
                        DropdownMenuItem(
                            value: c.id, child: Text(c.displayName)),
                    ],
                    onChanged: (v) => setState(() => _classId = v),
                  ),
                ),
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  children: [
                    for (var i = 0; i < kWeekdays.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(kWeekdays[i]),
                          selected: _dayIndex == i,
                          onSelected: (_) =>
                              setState(() => _dayIndex = i),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: daySlots.isEmpty
                    ? Center(
                        child: Text('No lessons for this day',
                            style: TextStyle(color: AppColors.muted)))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: daySlots.length,
                        itemBuilder: (context, i) {
                          final slot = daySlots[i];
                          return SvEntrance(
                            delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
                            child: SvPressScale(
                              child: SvAvatarTile(
                              title: subjectName(slot.subjectId),
                              meta:
                                  '${slot.start} – ${slot.end} · Period ${i + 1}'
                                  '${slot.teacherId.isNotEmpty ? ' · ${slot.teacherId}' : ''}',
                              initials: _initialsFor(subjectName(slot.subjectId)),
                              avatarColor: _subjectColor(slot.subjectId),
                              trailing: editable
                                  ? IconButton(
                                      tooltip: 'Edit this lesson slot',
                                      icon: const Icon(Icons.edit_outlined),
                                      onPressed: () =>
                                          _editSlot(existing: slot),
                                    )
                                  : null,
                              onTap: editable
                                  ? () => _editSlot(existing: slot)
                                  : null,
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
          final editable = snap.data?.$3 ?? false;
          if (!editable || snap.connectionState != ConnectionState.done) {
            return const SizedBox.shrink();
          }
          return FloatingActionButton.extended(
            onPressed: () => _editSlot(),
            icon: const Icon(Icons.add),
            label: const Text('Add lesson'),
          );
        },
      ),
    );
  }
}