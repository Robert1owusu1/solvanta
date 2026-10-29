import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/assignment.dart';
import '../../core/models/school_term.dart';
import '../../core/models/subjects.dart';
import '../../core/models/user.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../assessment/assessment_repository.dart';
import '../assignments/assignments_repository.dart';
import '../auth/auth_repository.dart';
import 'term_repository.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Academic calendar (doc §19, §7): a month view of assessments, assignment
/// deadlines and term context. Staff can update the current term.
class AcademicCalendarScreen extends StatefulWidget {
  const AcademicCalendarScreen({super.key});

  @override
  State<AcademicCalendarScreen> createState() => _AcademicCalendarScreenState();
}

class _Dated {
  final String date;
  final String title;
  final String sub;
  final bool isAssessment;

  const _Dated(this.date, this.title, this.sub, this.isAssessment);
}

class _CalData {
  final SchoolTerm term;
  final List<Assessment> assessments;
  final List<Assignment> assignments;
  final User? user;

  const _CalData({
    required this.term,
    required this.assessments,
    required this.assignments,
    required this.user,
  });
}

class _AcademicCalendarScreenState extends State<AcademicCalendarScreen> {
  late Future<_CalData> _data;
  late DateTime _month;
  String? _selected;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _data = _load();
    _selected = _dateStr(now);
  }

  void _refresh() => setState(() => _data = _load());

  Future<_CalData> _load() async {
    final term = await TermRepository().current();
    final assessments = await AssessmentRepository().assessments();
    final assignments = await AssignmentsRepository().all();
    final user = await AuthRepository().currentUser();
    return _CalData(
      term: term,
      assessments: assessments,
      assignments: assignments,
      user: user,
    );
  }

  String _dateStr(DateTime d) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)}';
  }

  String _monthLabel() {
    const names = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${names[_month.month - 1]} ${_month.year}';
  }

  List<_Dated> _items(_CalData d) {
    final out = <_Dated>[];
    for (final a in d.assessments) {
      out.add(_Dated(a.date, '${a.type.label} · ${a.title}',
          '${subjectName(a.subjectId)} · ${a.classId}', true));
    }
    for (final asg in d.assignments) {
      out.add(_Dated(
          asg.deadline, 'Assignment due · ${asg.title}',
          '${subjectName(asg.subjectId)} · ${asg.classId}', false));
    }
    out.sort((x, y) => x.date.compareTo(y.date));
    return out;
  }

  Map<String, List<_Dated>> _byDate(List<_Dated> items) {
    final map = <String, List<_Dated>>{};
    for (final it in items) {
      map.putIfAbsent(it.date, () => []).add(it);
    }
    return map;
  }

  Future<void> _editTerm(_CalData d) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _EditTermDialog(initial: d.term),
    );
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(
        title: 'Academic Calendar',
        subtitle:
            '${_month.year} · ${_monthLabel().replaceAll(RegExp(r' \d+$'), '')}',
        actions: [
          IconButton(
            tooltip: 'Today',
            icon: const Icon(Icons.today_outlined,
                color: Colors.white),
            onPressed: () {
              final now = DateTime.now();
              setState(() {
                _month = DateTime(now.year, now.month);
                _selected = _dateStr(now);
              });
            },
          ),
        ],
      ),
      body: FutureBuilder<_CalData>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return SvErrorState(
              title: "Couldn't load the calendar",
              message: 'Something went wrong. Please try again.',
              onRetry: _refresh,
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const SvLoading(message: 'Building calendar…');
          }
          final d = snap.data;
          if (d == null) return const SvErrorState();
          final byDate = _byDate(_items(d));
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _termBanner(d, byDate),
              const SizedBox(height: 12),
              _monthGrid(d, byDate),
              const SizedBox(height: 12),
              _dayList(byDate[_selected] ?? const []),
            ],
          );
        },
      ),
    );
  }

  Widget _termBanner(_CalData d, Map<String, List<_Dated>> byDate) {
    final visible = d.user?.isSchoolStaff ?? false;
    final inTerm = byDate.values
        .expand((x) => x)
        .where((x) => d.term.contains(x.date))
        .length;
    return Card(
      color: AppTheme.brand.withValues(alpha: .05),
      child: ListTile(
        leading: Icon(Icons.school, color: AppColors.brand),
        title: Text(d.term.label,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text('${d.term.start} → ${d.term.end}\n'
            '$inTerm activities within this term'),
        isThreeLine: true,
        trailing: visible
            ? TextButton(
                onPressed: () => _editTerm(d),
                child: const Text('Edit'),
              )
            : null,
      ),
    );
  }

  Widget _monthGrid(_CalData d, Map<String, List<_Dated>> byDate) {
    final now = DateTime.now();
    final today = _dateStr(now);
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final offset = DateTime(_month.year, _month.month, 1).weekday - 1;
    final isCurrentMonth =
        _month.year == now.year && _month.month == now.month;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Previous month',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => setState(() {
                    _month = DateTime(_month.year, _month.month - 1, 1);
                    _selected = null;
                  }),
                ),
                Expanded(
                  child: Text(
                    _monthLabel(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Next month',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => setState(() {
                    _month = DateTime(_month.year, _month.month + 1, 1);
                    _selected = null;
                  }),
                ),
              ],
            ),
            Row(
              children: [
                for (final w in _weekdays)
                  Expanded(
                    child: Text(w,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 11,
                            color: AppColors.muted,
                            fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              children: [
                for (var i = 0; i < offset + daysInMonth; i++) ...[
                  if (i < offset)
                    const SizedBox()
                  else
                    _dayCell(i - offset + 1, d, byDate, today,
                        isCurrentMonth),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _legendDot(AppTheme.brand, 'Assessment'),
                const SizedBox(width: 12),
                _legendDot(AppTheme.gold, 'Assignment due'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: color),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      );

  Widget _dayCell(int day, _CalData d, Map<String, List<_Dated>> byDate,
      String today, bool isCurrentMonth) {
    final date = '${_month.year}-${_month.month.toString().padLeft(2, '0')}'
        '-${day.toString().padLeft(2, '0')}';
    final items = byDate[date] ?? const [];
    final assessments =
        items.where((x) => x.isAssessment).length;
    final assignments =
        items.where((x) => !x.isAssessment).length;
    final selected = _selected == date;
    final isToday = isCurrentMonth && today == date;

    Color? bg;
    if (selected) {
      bg = AppTheme.brand;
    } else if (isToday) {
      bg = AppTheme.brand.withValues(alpha: .18);
    }
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _selected = date),
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: isToday && !selected
              ? Border.all(color: AppTheme.brand)
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$day',
              style: TextStyle(
                fontWeight:
                    selected || isToday ? FontWeight.w800 : FontWeight.w500,
                fontSize: 13,
                color: selected ? Colors.white : null,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (assessments > 0)
                  Icon(Icons.circle,
                      size: 6,
                      color: selected
                          ? Colors.white
                          : AppTheme.brand),
                if (assignments > 0) ...[
                  const SizedBox(width: 3),
                  // Meaningful "has assignments" marker → needs 3:1 against
                  // the white cell, which the decorative brand gold lacks.
                  Icon(Icons.circle,
                      size: 6,
                      color: selected
                          ? Colors.white70
                          : AppColors.goldFg),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dayList(List<_Dated> items) {
    if (items.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Nothing scheduled on this day.',
            style: TextStyle(color: AppColors.muted)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 3,
              height: 16,
              decoration: BoxDecoration(
                color: AppTheme.gold,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _selected == null ? 'Viewing' : 'Scheduled on $_selected',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final (i, it) in items.indexed)
          SvEntrance(
            delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
            child: SvPressScale(
              child: _DayItem(it),
            ),
          ),
      ],
    );
  }
}

class _DayItem extends StatelessWidget {
  const _DayItem(this.it);

  final _Dated it;

  @override
  Widget build(BuildContext context) {
    final brand = it.isAssessment;
    final color = brand ? AppTheme.brand : AppTheme.gold;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [color, color.withValues(alpha: .58)],
            ),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(
            brand ? Icons.quiz_outlined : Icons.assignment_outlined,
            color: Colors.white,
            size: 20,
          ),
        ),
        title: Text(it.title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        subtitle: Text(it.sub,
            style: const TextStyle(fontSize: 12, height: 1.3)),
      ),
    );
  }
}

class _EditTermDialog extends StatefulWidget {
  final SchoolTerm initial;

  const _EditTermDialog({required this.initial});

  @override
  State<_EditTermDialog> createState() => _EditTermDialogState();
}

class _EditTermDialogState extends State<_EditTermDialog> {
  late final _year = TextEditingController(text: widget.initial.year);
  late final _name = TextEditingController(text: widget.initial.name);
  late String _start = widget.initial.start;
  late String _end = widget.initial.end;

  @override
  void dispose() {
    _year.dispose();
    _name.dispose();
    super.dispose();
  }

  String _d(DateTime x) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${x.year}-${p(x.month)}-${p(x.day)}';
  }

  Future<void> _pick(bool isStart) async {
    final parsed = DateTime.tryParse(isStart ? _start : _end);
    final picked = await showDatePicker(
      context: context,
      initialDate: parsed ?? DateTime.now(),
      firstDate: DateTime(2024),
      lastDate: DateTime(2032),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        _start = _d(picked);
      } else {
        _end = _d(picked);
      }
    });
  }

  Future<void> _save() async {
    await TermRepository().setTerm(SchoolTerm(
      year: _year.text.trim().isEmpty ? widget.initial.year : _year.text.trim(),
      name: _name.text.trim().isEmpty ? widget.initial.name : _name.text.trim(),
      start: _start,
      end: _end,
    ));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set academic term'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _year,
              decoration: const InputDecoration(
                labelText: 'Academic year',
                hintText: '2026/2027',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Term',
                hintText: 'Term 1',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Starts $_start'),
              subtitle: const Text('Tap to change start date'),
              trailing: const Icon(Icons.edit_calendar),
              onTap: () => _pick(true),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Ends $_end'),
              subtitle: const Text('Tap to change end date'),
              trailing: const Icon(Icons.edit_calendar),
              onTap: () => _pick(false),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}