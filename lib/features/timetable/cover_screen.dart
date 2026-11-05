import 'package:flutter/material.dart';

import '../../core/models/cover_assignment.dart';
import '../../core/models/subjects.dart';
import '../../core/models/role.dart';
import '../../core/models/timetable.dart';
import '../../core/models/user.dart';
import '../../core/theme/app_theme.dart';
import '../admin/admin_repository.dart';
import '../auth/auth_repository.dart';
import 'cover_repository.dart';
import 'timetable_repository.dart';

/// Cover / substitution planner. For a chosen date it shows that weekday's
/// lessons and, for each, whether cover has been arranged. Leaders record an
/// absence and assign a substitute; everyone else sees it read-only so the
/// substitute and the class know who is teaching.
class CoverScreen extends StatefulWidget {
  const CoverScreen({super.key});

  @override
  State<CoverScreen> createState() => _CoverScreenState();
}

class _CoverScreenState extends State<CoverScreen> {
  DateTime _date = DateTime.now();
  late Future<_Data> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  String get _iso {
    final d = _date;
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)}';
  }

  // Dart weekday: Mon=1..Sun=7; kWeekdays is Mon..Fri.
  String get _weekday =>
      _date.weekday <= 5 ? kWeekdays[_date.weekday - 1] : '';

  Future<_Data> _load() async {
    final user = await AuthRepository().currentUser();
    final slots = await TimetableRepository().loadSlots();
    final cover = await CoverRepository().forDate(_iso);
    final staff = await AdminRepository().staffList();
    final day = [
      for (final s in slots)
        if (s.weekday == _weekday) s,
    ]..sort((a, b) => a.start.compareTo(b.start));
    return _Data(user: user, lessons: day, cover: cover, staff: staff);
  }

  void _refresh() => setState(() => _data = _load());

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now().add(const Duration(days: 180)),
    );
    if (picked != null) {
      _date = picked;
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cover & substitution')),
      body: FutureBuilder<_Data>(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final d = snap.data!;
          final canEdit =
              d.user != null && _canArrangeCover(d.user!);
          final coverByLesson = {for (final c in d.cover) c.lessonId: c};
          return Column(
            children: [
              _dateBar(d),
              Expanded(
                child: _weekday.isEmpty
                    ? const Center(
                        child: Text('Weekends have no timetabled lessons.'))
                    : d.lessons.isEmpty
                        ? Center(
                            child: Text('No lessons on $_weekday.',
                                style: TextStyle(color: AppColors.muted)))
                        : ListView(
                            padding: const EdgeInsets.all(12),
                            children: [
                              for (final slot in d.lessons)
                                _lessonTile(d, slot,
                                    coverByLesson[slot.id], canEdit),
                            ],
                          ),
              ),
            ],
          );
        },
      ),
    );
  }

  bool _canArrangeCover(User u) =>
      u.isSchoolLeader || u.role == AppRole.superAdmin;

  Widget _dateBar(_Data d) {
    final open = d.cover.where((c) => !c.isAssigned).length;
    final assigned = d.cover.where((c) => c.isAssigned).length;
    return Material(
      color: AppTheme.brand.withValues(alpha: .06),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_weekday.isEmpty ? 'Weekend' : _weekday,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  Text(_iso, style: TextStyle(color: AppColors.muted)),
                  if (assigned + open > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '$assigned covered'
                        '${open > 0 ? ' · $open awaiting a substitute' : ''}',
                        style: TextStyle(
                            fontSize: 12,
                            color: open > 0
                                ? AppColors.warning
                                : AppColors.success),
                      ),
                    ),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.calendar_today, size: 16),
              label: const Text('Change date'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lessonTile(
      _Data d, LessonSlot slot, CoverAssignment? cover, bool canEdit) {
    final scheduled =
        slot.teacherId.isNotEmpty ? slot.teacherId : 'Unassigned';
    Widget trailing;
    if (cover == null) {
      trailing = canEdit
          ? FilledButton.tonalIcon(
              onPressed: () => _arrange(d, slot, null),
              icon: const Icon(Icons.person_add_alt, size: 16),
              label: const Text('Cover'),
            )
          : const SizedBox.shrink();
    } else if (cover.isAssigned) {
      trailing = Chip(
        avatar: Icon(Icons.check_circle,
            size: 16, color: AppColors.success),
        label: Text(cover.substituteTeacherName,
            overflow: TextOverflow.ellipsis),
        backgroundColor: AppColors.success.withValues(alpha: .1),
      );
    } else {
      trailing = Chip(
        avatar:
            Icon(Icons.warning_amber, size: 16, color: AppColors.warning),
        label: const Text('Needs cover'),
        backgroundColor: AppColors.warning.withValues(alpha: .12),
      );
    }
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppTheme.brand.withValues(alpha: .12),
          child: Text(slot.classId.isNotEmpty ? slot.classId[0] : '?',
              style: TextStyle(
                  color: AppColors.brand, fontWeight: FontWeight.w700)),
        ),
        title: Text('${subjectName(slot.subjectId)} · ${slot.classId}'),
        subtitle: Text(
          '${slot.blockLabel} · ${cover != null ? cover.absentTeacherName : scheduled}'
          '${cover?.reason.isNotEmpty == true ? '\n${cover!.reason}' : ''}',
        ),
        isThreeLine: cover?.reason.isNotEmpty == true,
        trailing: trailing,
        onTap: canEdit ? () => _arrange(d, slot, cover) : null,
      ),
    );
  }

  Future<void> _arrange(
      _Data d, LessonSlot slot, CoverAssignment? existing) async {
    final absentCtrl = TextEditingController(
        text: existing?.absentTeacherName ??
            (slot.teacherId.isNotEmpty ? slot.teacherId : ''));
    final reasonCtrl = TextEditingController(text: existing?.reason ?? '');
    String? subId = existing?.substituteTeacherId.isNotEmpty == true
        ? existing!.substituteTeacherId
        : null;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: StatefulBuilder(
            builder: (ctx, setSheet) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Arrange cover',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                    '${subjectName(slot.subjectId)} · ${slot.classId} · '
                    '${slot.blockLabel} · $_iso',
                    style: TextStyle(color: AppColors.muted)),
                const SizedBox(height: 16),
                TextField(
                  controller: absentCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Absent teacher',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: subId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Substitute (leave empty = needs cover)',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('— not yet assigned —')),
                    for (final s in d.staff)
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (v) => setSheet(() => subId = v),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: reasonCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Reason (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    if (existing != null)
                      TextButton.icon(
                        onPressed: () async {
                          await CoverRepository().remove(existing.id);
                          if (ctx.mounted) Navigator.pop(ctx);
                          _refresh();
                        },
                        icon: Icon(Icons.delete_outline,
                            color: AppColors.danger),
                        label: Text('Remove',
                            style: TextStyle(color: AppColors.danger)),
                      ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () async {
                        final sub = subId == null
                            ? null
                            : d.staff.firstWhere((s) => s.id == subId);
                        final rec = CoverAssignment(
                          id: existing?.id ??
                              'COV-${DateTime.now().millisecondsSinceEpoch}',
                          date: _iso,
                          weekday: _weekday,
                          lessonId: slot.id,
                          classId: slot.classId,
                          subjectId: slot.subjectId,
                          start: slot.start,
                          end: slot.end,
                          absentTeacherId: existing?.absentTeacherId ?? '',
                          absentTeacherName: absentCtrl.text.trim(),
                          substituteTeacherId: sub?.id ?? '',
                          substituteTeacherName: sub?.name ?? '',
                          reason: reasonCtrl.text.trim(),
                          status: sub != null ? 'assigned' : 'open',
                        );
                        await CoverRepository().upsert(rec);
                        if (ctx.mounted) Navigator.pop(ctx);
                        _refresh();
                      },
                      child: const Text('Save cover'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Data {
  final User? user;
  final List<LessonSlot> lessons;
  final List<CoverAssignment> cover;
  final List<User> staff;
  const _Data({
    required this.user,
    required this.lessons,
    required this.cover,
    required this.staff,
  });
}
