import 'package:flutter/material.dart';

import '../../core/models/parent_meeting.dart';
import '../../core/models/role.dart';
import '../../core/models/student.dart';
import '../../core/models/user.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'parent_meetings_repository.dart';

/// Follow-up on "parent meeting requested": book it (the family is told),
/// record what was agreed, or cancel. A teacher sees their own class.
class ParentMeetingsScreen extends StatefulWidget {
  const ParentMeetingsScreen({super.key});

  @override
  State<ParentMeetingsScreen> createState() => _ParentMeetingsScreenState();
}

class _ParentMeetingsScreenState extends State<ParentMeetingsScreen> {
  late Future<({List<ParentMeeting> meetings, Map<String, Student> students})>
      _data;
  bool _showDone = false;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<({List<ParentMeeting> meetings, Map<String, Student> students})>
      _load() async {
    final User? me = await AuthRepository().currentUser();
    final students = {
      for (final s in await StudentsRepository().all()) s.id: s,
    };
    final mine = me?.role == AppRole.teacher
        ? (ParentMeeting m) => m.classId == me?.classId
        : (ParentMeeting m) => true;
    final meetings = [
      for (final m in await ParentMeetingsRepository().all())
        if (mine(m)) m,
    ]..sort((a, b) {
        final byWhen = a.scheduledFor.compareTo(b.scheduledFor);
        return byWhen != 0 ? byWhen : a.id.compareTo(b.id);
      });
    return (meetings: meetings, students: students);
  }

  Future<void> _save(ParentMeeting m) async {
    await ParentMeetingsRepository().save(m);
    if (mounted) {
      setState(() {
        _data = _load();
      });
    }
  }

  Future<void> _book(ParentMeeting m) async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 2)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 180)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 10, minute: 0),
    );
    if (time == null || !mounted) return;
    final place = await _ask('Where?', 'e.g. Headteacher\'s office',
        initial: m.place);
    if (place == null) return;
    String p(int v) => v.toString().padLeft(2, '0');
    await _save(m.copyWith(
      status: MeetingStatus.scheduled,
      scheduledFor: '${day.year}-${p(day.month)}-${p(day.day)} '
          '${p(time.hour)}:${p(time.minute)}',
      place: place,
    ));
  }

  Future<void> _recordOutcome(ParentMeeting m) async {
    final outcome = await _ask('What was agreed?',
        'e.g. Extra maths practice twice a week; review in 4 weeks',
        initial: m.outcome, lines: 4);
    if (outcome == null || outcome.isEmpty) return;
    await _save(m.copyWith(status: MeetingStatus.held, outcome: outcome));
  }

  Future<void> _cancel(ParentMeeting m) async {
    final ok = await svConfirm(context,
        title: 'Cancel this meeting?',
        message: 'It is kept on record as cancelled.',
        confirmLabel: 'Cancel meeting',
        destructive: true);
    if (ok) await _save(m.copyWith(status: MeetingStatus.cancelled));
  }

  Future<String?> _ask(String title, String hint,
      {String initial = '', int lines = 1}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLines: lines,
          decoration: InputDecoration(
              hintText: hint, border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Back')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Save')),
        ],
      ),
    ).whenComplete(c.dispose);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SvScreenHeader(
        title: 'Parent Meetings',
        subtitle: 'Book, hold and record follow-up with families',
      ),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return SvErrorState(
                onRetry: () => setState(() {
                      _data = _load();
                    }));
          }
          final data = snap.data;
          if (data == null) return const SvListSkeleton();
          final shown = [
            for (final m in data.meetings)
              if (m.status.open != _showDone) m,
          ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              SvFilterChips(
                options: [
                  SvFilterOption('Open', selected: !_showDone),
                  SvFilterOption('Done', selected: _showDone),
                ],
                onSelected: (i) => setState(() => _showDone = i == 1),
              ),
              const SizedBox(height: 8),
              if (shown.isEmpty)
                SvEmptyState(
                  icon: Icons.event_available_outlined,
                  title: _showDone ? 'No past meetings' : 'No open meetings',
                  message: _showDone
                      ? 'Held and cancelled meetings appear here.'
                      : 'A report card asks for one when a pupil\'s year '
                          'average falls below the school\'s mark.',
                ),
              for (final m in shown)
                _MeetingCard(
                  meeting: m,
                  student: data.students[m.studentId],
                  onBook: () => _book(m),
                  onOutcome: () => _recordOutcome(m),
                  onCancel: () => _cancel(m),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _MeetingCard extends StatelessWidget {
  const _MeetingCard({
    required this.meeting,
    required this.student,
    required this.onBook,
    required this.onOutcome,
    required this.onCancel,
  });

  final ParentMeeting meeting;
  final Student? student;
  final VoidCallback onBook;
  final VoidCallback onOutcome;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final m = meeting;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${student?.fullName ?? m.studentId} · ${m.classId}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Chip(label: Text(m.status.label)),
              ],
            ),
            Text('${m.term} · ${m.year} — ${m.reason}',
                style: TextStyle(color: AppColors.muted, fontSize: 13)),
            if (m.scheduledFor.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                    '${m.scheduledFor}${m.place.isEmpty ? '' : ' · ${m.place}'}'),
              ),
            if (m.outcome.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Agreed: ${m.outcome}'),
              ),
            if (m.status.open)
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: onBook,
                    icon: const Icon(Icons.event, size: 18),
                    label: Text(m.status == MeetingStatus.scheduled
                        ? 'Reschedule'
                        : 'Book'),
                  ),
                  if (m.status == MeetingStatus.scheduled)
                    TextButton.icon(
                      onPressed: onOutcome,
                      icon: const Icon(Icons.task_alt, size: 18),
                      label: const Text('Record outcome'),
                    ),
                  TextButton(onPressed: onCancel, child: const Text('Cancel')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
