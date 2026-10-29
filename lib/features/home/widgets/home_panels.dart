import 'package:flutter/material.dart';

import '../../../core/models/announcement.dart';
import '../../../core/models/student.dart';
import '../../../core/models/subjects.dart';
import '../../../core/models/user.dart';
import '../../../core/sync/server_sync.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_kit.dart';
import '../../assessment/assessment_repository.dart';
import '../../assignments/assignments_repository.dart';
import '../../communication/announcements_repository.dart';
import '../../students/students_repository.dart';

/// The students the home dashboard reports on: a teacher's own class, a
/// parent's children, a student themself, everyone for leaders and staff.
/// ([StudentsRepository.visibleToUser] counts a teacher as staff, so it
/// returns the whole school for them.)
Future<List<Student>> homeScope(User user) async {
  final role = user.role;
  if (role.isTeacher) {
    return (await StudentsRepository().active()).where((s) => s.classId == user.classId).toList();
  }
  return StudentsRepository().visibleToUser(user);
}

/// Something dated that is still ahead: an assessment or an assignment due.
class UpcomingItem {
  const UpcomingItem(this.date, this.title, this.detail, {required this.assessment});

  final String date; // yyyy-MM-dd
  final String title;
  final String detail;
  final bool assessment;
}

/// The dashboard's side panels: the latest notices this person may see and
/// what is coming up for their classes. "View all" opens the full screen
/// through the menu, so the sidebar's selection follows.
class HomePanels extends StatefulWidget {
  const HomePanels({
    super.key,
    required this.user,
    required this.onOpenNotices,
    required this.onOpenCalendar,
  });

  final User user;

  /// Null when the person has no such module.
  final VoidCallback? onOpenNotices;
  final VoidCallback? onOpenCalendar;

  @override
  State<HomePanels> createState() => _HomePanelsState();
}

class _HomePanelsState extends State<HomePanels> {
  late Future<(List<Announcement>, List<UpcomingItem>)> _future = _load();

  @override
  void initState() {
    super.initState();
    ServerSync.instance.addListener(_reload);
  }

  @override
  void dispose() {
    ServerSync.instance.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _future = _load());
  }

  static String today() {
    final d = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)}';
  }

  Future<(List<Announcement>, List<UpcomingItem>)> _load() async {
    final user = widget.user;
    final students = await homeScope(user);
    final notices = await AnnouncementsRepository().visibleFor(user, await StudentsRepository().all());
    notices.sort((a, b) {
      // Emergencies first, then newest.
      final e = (b.audience == AnnouncementAudience.emergency ? 1 : 0) -
          (a.audience == AnnouncementAudience.emergency ? 1 : 0);
      return e != 0 ? e : b.timestamp.compareTo(a.timestamp);
    });

    // Leaders and staff follow the whole school; everyone else their classes.
    final classes = user.role.isTeacher || user.role.isParent || user.role.isStudent
        ? {for (final s in students) s.classId, if (user.classId != null) user.classId!}
        : null;
    bool mine(String classId) => classes == null || classes.contains(classId);
    final from = today();
    final upcoming = <UpcomingItem>[
      for (final a in await AssessmentRepository().assessments())
        if (a.date.compareTo(from) >= 0 && mine(a.classId))
          UpcomingItem(a.date, a.title, '${a.type.label} · ${subjectName(a.subjectId)} · ${a.classId}', assessment: true),
      for (final a in await AssignmentsRepository().all())
        if (a.deadline.compareTo(from) >= 0 && mine(a.classId))
          UpcomingItem(a.deadline, a.title, 'Assignment due · ${subjectName(a.subjectId)} · ${a.classId}',
              assessment: false),
    ]..sort((a, b) => a.date.compareTo(b.date));
    return (notices.take(3).toList(), upcoming.take(4).toList());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _future,
      builder: (context, snap) {
        final (notices, upcoming) = snap.data ?? (const <Announcement>[], const <UpcomingItem>[]);
        if (snap.connectionState != ConnectionState.done) {
          return const Column(children: [SvCardSkeleton(lines: 4), SizedBox(height: 12), SvCardSkeleton(lines: 4)]);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Panel(
              icon: Icons.campaign_outlined,
              title: 'Important notices',
              actionLabel: 'View all notices',
              onAction: widget.onOpenNotices,
              empty: 'No notices right now.',
              children: [for (final n in notices) _NoticeTile(n)],
            ),
            const SizedBox(height: 12),
            _Panel(
              icon: Icons.event_outlined,
              title: 'Upcoming',
              actionLabel: 'View full calendar',
              onAction: widget.onOpenCalendar,
              empty: 'Nothing scheduled ahead.',
              children: [for (final u in upcoming) _UpcomingTile(u)],
            ),
          ],
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.icon,
    required this.title,
    required this.actionLabel,
    required this.onAction,
    required this.empty,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String actionLabel;
  final VoidCallback? onAction;
  final String empty;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border.withValues(alpha: .6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: AppColors.brand),
              const SizedBox(width: 8),
              Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.ink)),
            ],
          ),
          const SizedBox(height: 10),
          if (children.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(empty, style: TextStyle(color: AppColors.muted)),
            )
          else
            ...children,
          if (onAction != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.brand,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(actionLabel, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_forward, size: 16),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

class _NoticeTile extends StatelessWidget {
  const _NoticeTile(this.n);

  final Announcement n;

  @override
  Widget build(BuildContext context) {
    final emergency = n.audience == AnnouncementAudience.emergency;
    final accent = emergency ? AppColors.danger : AppColors.brand;
    final date = n.timestamp.length >= 10 ? n.timestamp.substring(0, 10) : n.timestamp;
    final fresh = _isRecent(date);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (emergency) ...[
                Icon(Icons.warning_amber_rounded, size: 16, color: accent),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(n.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: AppColors.ink)),
              ),
              if (fresh)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('New', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: AppColors.danger)),
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(n.body, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: AppColors.body)),
          const SizedBox(height: 5),
          Row(children: [
            Icon(Icons.calendar_today_outlined, size: 12, color: AppColors.muted),
            const SizedBox(width: 4),
            Flexible(
              child: Text('$date · ${n.audience.label}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: AppColors.muted)),
            ),
          ]),
        ],
      ),
    );
  }

  static bool _isRecent(String date) {
    final d = DateTime.tryParse(date);
    return d != null && DateTime.now().difference(d).inDays <= 3;
  }
}

const _months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];

class _UpcomingTile extends StatelessWidget {
  const _UpcomingTile(this.u);

  final UpcomingItem u;

  @override
  Widget build(BuildContext context) {
    final d = DateTime.tryParse(u.date);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 46,
            padding: const EdgeInsets.symmetric(vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.brand.withValues(alpha: .1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(children: [
              Text(d == null ? '?' : '${d.day}',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: AppColors.brand, height: 1.1)),
              Text(d == null ? u.date : _months[d.month - 1],
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.body)),
            ]),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(u.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: AppColors.ink)),
                Text(u.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: AppColors.muted)),
              ],
            ),
          ),
          Icon(u.assessment ? Icons.quiz_outlined : Icons.assignment_outlined, size: 18, color: AppColors.muted),
        ],
      ),
    );
  }
}
