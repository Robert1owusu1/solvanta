import 'package:flutter/material.dart';

import '../../core/models/app_notification.dart';
import '../../core/models/student.dart';
import '../../core/models/user.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../students/student_profile_screen.dart';
import '../students/students_repository.dart';
import 'notifications_repository.dart';

/// Full-screen inbox (pushed from the dashboard header / attention rows).
class NotificationsInboxScreen extends StatelessWidget {
  const NotificationsInboxScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Notifications'),
      body: const NotificationsInboxBody(),
    );
  }
}

/// The inbox list on its own, so the shell can embed it as a bottom-nav tab
/// without a nested app bar. Calls [onChanged] after any read-state change so
/// the shell can keep its unread badge in sync.
class NotificationsInboxBody extends StatefulWidget {
  const NotificationsInboxBody({super.key, this.onChanged});

  final VoidCallback? onChanged;

  @override
  State<NotificationsInboxBody> createState() => _NotificationsInboxBodyState();
}

class _NotificationsInboxBodyState extends State<NotificationsInboxBody> {
  late Future<(User?, List<AppNotification>, List<Student>)> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(User?, List<AppNotification>, List<Student>)> _load() async {
    final user = await AuthRepository().currentUser();
    if (user == null) {
      return (null, const <AppNotification>[], const <Student>[]);
    }
    final students = await StudentsRepository().active();
    final visible =
        await NotificationsRepository().visibleFor(user, students);
    return (user, visible, students);
  }

  void _refresh() => setState(() { _data = _load(); });

  Future<void> _markAllRead() async {
    final (user, _, students) = await _data;
    if (user == null) return;
    await NotificationsRepository().markAllRead(user, students);
    _refresh();
    widget.onChanged?.call();
  }

  IconData _iconFor(NotificationKind k) => switch (k) {
        NotificationKind.gate => Icons.sensors_outlined,
        NotificationKind.attendance => Icons.badge_outlined,
        NotificationKind.assessment => Icons.quiz_outlined,
        NotificationKind.marking => Icons.grading_outlined,
        NotificationKind.intervention => Icons.support_agent_outlined,
        NotificationKind.message => Icons.chat_bubble_outline,
        NotificationKind.assignment => Icons.assignment_outlined,
        NotificationKind.announcement => Icons.campaign_outlined,
        NotificationKind.system => Icons.info_outline,
        NotificationKind.reportCard => Icons.workspace_premium_outlined,
        NotificationKind.meeting => Icons.event_available_outlined,
      };

  // Decorative category tints drawn from the single navy ramp, gold accent,
  // and neutral — per the brand system (60/30/10 + semantic).
  Color _colorFor(NotificationKind k) => switch (k) {
        NotificationKind.gate => AppTheme.navy900,
        NotificationKind.attendance => AppTheme.navy700,
        NotificationKind.assessment => AppTheme.navy500,
        NotificationKind.marking => AppTheme.navy400,
        NotificationKind.intervention => AppTheme.navy200,
        NotificationKind.message => AppTheme.navy700,
        NotificationKind.assignment => AppTheme.navy500,
        NotificationKind.announcement => AppTheme.gold,
        NotificationKind.system => AppColors.notAttempted,
        NotificationKind.reportCard => AppTheme.gold,
        NotificationKind.meeting => AppTheme.navy700,
      };

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _data,
      builder: (context, snap) {
        if (snap.hasError) {
          return SvErrorState(
            title: "Couldn't load notifications",
            message: 'We couldn\'t load your notifications. '
                'Please try again.',
            onRetry: _refresh,
          );
        }
        if (snap.connectionState != ConnectionState.done) {
          return const SvLoading(message: 'Loading notifications…');
        }
        final (user, notifications, students) =
            snap.data ?? (null, const <AppNotification>[], const <Student>[]);
        if (user == null) {
          return const Center(child: Text('Not signed in'));
        }
        if (notifications.isEmpty) {
          return const SvEmptyState(
            icon: Icons.notifications_none,
            title: 'You\'re all caught up',
            message: 'Updates about attendance, results and school messages '
                'will show up here.',
          );
        }

        String? nameFor(String? id) {
          for (final s in students) {
            if (s.id == id) return s.fullName;
          }
          return null;
        }

        final unread = notifications.where((n) => !n.read).length;
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: notifications.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$unread unread · ${notifications.length} total',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.muted),
                      ),
                    ),
                    if (unread > 0)
                      TextButton.icon(
                        onPressed: _markAllRead,
                        icon: const Icon(Icons.done_all, size: 17),
                        label: const Text('Mark all read'),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.brand,
                          textStyle: const TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                  ],
                ),
              );
            }
            final n = notifications[i - 1];
            final color = _colorFor(n.kind);
            return SvEntrance(
              delay: Duration(milliseconds: 50 * (i - 1).clamp(0, 10)),
              child: SvAvatarTile(
                title: n.title,
                meta: '${n.body}'
                    '${nameFor(n.studentId) != null ? '\n${nameFor(n.studentId)}' : ''}'
                    '\n${n.kind.label} · ${_when(n.timestamp)}',
                icon: _iconFor(n.kind),
                avatarColor: color,
                color: n.read ? null : color.withValues(alpha: .08),
                trailing: n.read
                    ? Icon(Icons.chevron_right,
                        size: 20, color: AppColors.muted)
                    : Icon(Icons.circle, size: 10, color: color),
                onTap: () async {
                  if (!n.read) {
                    await NotificationsRepository().markRead(n.id);
                    widget.onChanged?.call();
                    if (mounted) _refresh();
                  }
                  final sid = n.studentId;
                  if (sid == null || nameFor(sid) == null) return;
                  if (!context.mounted) return;
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => StudentProfileScreen(studentId: sid),
                    ),
                  );
                  if (mounted) _refresh();
                },
              ),
            );
          },
        );
      },
    );
  }

  String _when(String ts) {
    final t = ts.trim();
    if (t.isEmpty) return '';
    final datePart = t.contains('T')
        ? t.split('T').first
        : (t.contains(' ') ? t.split(' ').first : t);
    final d = DateTime.tryParse(datePart);
    if (d == null) return t;
    final now = DateTime.now();
    final isToday = d.year == now.year &&
        d.month == now.month &&
        d.day == now.day;
    final time = svFormatTime(t);
    return isToday ? 'Today · $time' : '${svFormatDate(t)} · $time';
  }
}
