import 'package:flutter/material.dart';

import '../../core/models/audit.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import 'audit_repository.dart';

class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  late Future<List<AuditEntry>> _data;
  String _filter = 'All';

  @override
  void initState() {
    super.initState();
    _data = AuditRepository().all();
  }

  IconData _iconFor(String action) {
    if (action.startsWith('attendance')) return Icons.badge_outlined;
    if (action.startsWith('student')) return Icons.person_outline;
    if (action.startsWith('mark')) return Icons.grading_outlined;
    if (action.startsWith('parent')) return Icons.family_restroom;
    if (action.startsWith('staff')) return Icons.badge;
    if (action.startsWith('class')) return Icons.meeting_room_outlined;
    if (action.startsWith('school')) return Icons.school_outlined;
    if (action.startsWith('assessment') || action.startsWith('intervention')) {
      return Icons.assignment_outlined;
    }
    return Icons.history;
  }

  static const _filters = [
    ('All', 'All'),
    ('attendance', 'Attendance'),
    ('student', 'Students'),
    ('mark', 'Marking'),
    ('parent', 'Parents'),
    ('staff', 'Staff'),
    ('assessment', 'Assessments'),
    ('intervention', 'Interventions'),
    ('school', 'School'),
    ('class', 'Classes'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Audit Trail'),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return SvErrorState(
              title: "Couldn't load the audit trail",
              message: 'We couldn\'t load the activity log. Please try again.',
              onRetry: () => setState(() => _data = AuditRepository().all()),
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const SvLoading(message: 'Loading activity log…');
          }
          final all = snap.data ?? const <AuditEntry>[];
          final family = all.where((e) {
            if (_filter == 'All') return true;
            return e.action.startsWith(_filter);
          }).toList();
          return Column(
            children: [
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  children: [
                    for (final (value, label) in _filters)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(label),
                          selected: _filter == value,
                          onSelected: (_) => setState(() => _filter = value),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: family.isEmpty
                    ? const SvEmptyState(
                        icon: Icons.history,
                        title: 'No activity here yet',
                        message: 'Changes across the school — student records, '
                            'attendance, marking and more — are logged here.',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: family.length,
                        itemBuilder: (context, i) {
                          final e = family[i];
                          return Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    AppTheme.brand.withValues(alpha: .12),
                                child: Icon(_iconFor(e.action),
                                    size: 20, color: AppColors.brand),
                              ),
                              title: Text(
                                  '${_friendlyAction(e.action)} · ${e.target}',
                                  style: const TextStyle(fontWeight: .w600)),
                              subtitle: Text(
                                  '${e.detail}'
                                  '${e.reason != null && e.reason!.isNotEmpty ? '\nReason: ${e.reason}' : ''}'
                                  '\n${e.actor} · ${_when(e.timestamp)}'),
                              isThreeLine: true,
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _friendlyAction(String action) => action
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');

  String _when(String ts) {
    final t = ts.trim();
    if (t.isEmpty) return '';
    final datePart = t.contains('T')
        ? t.split('T').first
        : (t.contains(' ') ? t.split(' ').first : t);
    final d = DateTime.tryParse(datePart);
    if (d == null) return t;
    final now = DateTime.now();
    final isToday =
        d.year == now.year && d.month == now.month && d.day == now.day;
    final time = svFormatTime(t);
    return isToday ? 'Today · $time' : '${svFormatDate(t)} · $time';
  }
}