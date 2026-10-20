import 'package:flutter/material.dart';

import '../../../core/models/assessment.dart';
import '../../../core/models/attendance.dart';
import '../../../core/models/student.dart';
import '../../../core/models/user.dart';
import '../../../core/sync/server_sync.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_kit.dart';
import '../../analytics/analytics_screen.dart';
import '../../analytics/analytics_service.dart';
import '../../assessment/assessment_repository.dart';
import '../../assignments/assignments_repository.dart';
import '../../attendance/attendance_repository.dart';
import '../../attendance/attendance_screen.dart';
import '../../marking/marking_dashboard_screen.dart';
import '../../notifications/notifications_inbox_screen.dart';
import '../../notifications/notifications_repository.dart';
import '../../students/students_repository.dart';

/// A glanceable, role-aware "What needs attention" panel shown at the top of
/// the home screen. It answers the questions each role asks first:
/// * teacher — what needs marking, who is struggling, any attendance issues;
/// * admin — school-wide totals, at-risk students, marking backlog;
/// * parent — anything urgent about my child;
/// * student — anything due, any new results.
///
/// Everything is optional and fail-safe: if data cannot be loaded the panel
/// degrades to a retry state and never blocks the module list below.
class HomeOverview extends StatefulWidget {
  const HomeOverview({super.key, required this.user});

  final User user;

  @override
  State<HomeOverview> createState() => _HomeOverviewState();
}

class _HomeOverviewState extends State<HomeOverview> {
  late Future<OverviewData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
    // A background pull (cold start, resume, timer) brings new numbers.
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

  String _today() {
    final d = DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  Future<OverviewData> _load() async {
    final role = widget.user.role;
    if (role.isTeacher) return _teacherOverview();
    if (role.isParent) return _parentOverview();
    if (role.isStudent) return _studentOverview();
    return _adminOverview();
  }

  Future<OverviewData> _teacherOverview() async {
    final students = await StudentsRepository().active();
    final assessments = await AssessmentRepository().assessments();
    final subs = await AssessmentRepository().submissions();
    final classId = widget.user.classId;

    final roster =
        classId == null ? <dynamic>[] : students.where((s) => s.classId == classId).toList();
    final myAssessments =
        classId == null ? <Assessment>[] : assessments.where((a) => a.classId == classId).toList();

    var pendingMarks = 0;
    for (final a in myAssessments) {
      final done = subs.where((s) => s.assessmentId == a.id).length;
      pendingMarks += (roster.length - done).clamp(0, roster.length);
    }

    var absentToday = 0;
    var lateToday = 0;
    if (classId != null) {
      final today = await AttendanceRepository().forClassDate(classId, _today());
      absentToday = today.where((r) => r.status == AttendanceStatus.absent).length;
      lateToday = today.where((r) => r.status == AttendanceStatus.late).length;
    }

    var atRisk = 0;
    try {
      final perf =
          ClassPerformance(assessments: assessments, subs: subs, students: students);
      atRisk = perf.atRisk(threshold: 50).length;
    } catch (e, st) {
      debugPrint('[HomeOverview] metric failed: $e');
      debugPrint(st.toString());
    }

    final stats = <OverviewStat>[
      OverviewStat(
          icon: Icons.people_outline,
          value: '${roster.length}',
          label: 'Students'),
      OverviewStat(
          icon: Icons.grading_outlined,
          value: '$pendingMarks',
          label: 'To mark',
          builder: (_) => const MarkingDashboardScreen()),
      OverviewStat(
          icon: Icons.support_agent_outlined,
          value: '$atRisk',
          label: 'Need help',
          builder: (_) => const AnalyticsScreen()),
      OverviewStat(
          icon: Icons.event_busy_outlined,
          value: '${absentToday + lateToday}',
          label: 'Absent / late'),
    ];

    final attention = <AttentionItem>[];
    void add(AttentionItem item) => attention.add(item);

    if (pendingMarks > 0) {
      add(AttentionItem(
        icon: Icons.grading_outlined,
        color: AppColors.warning,
        title: '$pendingMarks answer sheet${pendingMarks == 1 ? '' : 's'} awaiting marking',
        detail: 'Review marks and confirm results',
        builder: (_) => const MarkingDashboardScreen(),
      ));
    }
    if (atRisk > 0) {
      add(AttentionItem(
        icon: Icons.error_outline,
        color: AppColors.danger,
        title: '$atRisk student${atRisk == 1 ? '' : 's'} scoring below 50%',
        detail: 'Set an intervention to re-teach and reassess',
        builder: (_) => const AnalyticsScreen(),
      ));
    }
    if (absentToday > 0 || lateToday > 0) {
      add(AttentionItem(
        icon: Icons.event_busy_outlined,
        color: AppColors.warning,
        title: '$absentToday absent · $lateToday late today',
        detail: 'Open the roll to review and notify parents',
        builder: (_) => const AttendanceScreen(),
      ));
    }
    if (attention.isEmpty) {
      add(AttentionItem(
        icon: Icons.check_circle_outline,
        color: AppColors.success,
        title: 'All caught up',
        detail: 'No urgent marking, risk or attendance issues today.',
      ));
    }
    return OverviewData(stats: stats, attention: attention);
  }

  Future<OverviewData> _adminOverview() async {
    final students = await StudentsRepository().active();
    final classes = await StudentsRepository().classes();
    final assessments = await AssessmentRepository().assessments();
    final subs = await AssessmentRepository().submissions();

    var atRisk = 0;
    var pendingMarks = 0;
    try {
      final perf =
          ClassPerformance(assessments: assessments, subs: subs, students: students);
      atRisk = perf.atRisk(threshold: 50).length;
    } catch (e, st) {
      debugPrint('[HomeOverview] metric failed: $e');
      debugPrint(st.toString());
    }
    for (final a in assessments) {
      final roster = students.where((s) => s.classId == a.classId).length;
      final done = subs.where((s) => s.assessmentId == a.id).length;
      pendingMarks += (roster - done).clamp(0, roster);
    }

    final stats = <OverviewStat>[
      OverviewStat(
          icon: Icons.people_outline, value: '${students.length}', label: 'Students'),
      OverviewStat(
          icon: Icons.school_outlined, value: '${classes.length}', label: 'Classes'),
      OverviewStat(
          icon: Icons.grading_outlined,
          value: '$pendingMarks',
          label: 'To mark'),
      OverviewStat(
          icon: Icons.support_agent_outlined,
          value: '$atRisk',
          label: 'Need help'),
    ];

    final attention = <AttentionItem>[];
    if (atRisk > 0) {
      attention.add(AttentionItem(
        icon: Icons.error_outline,
        color: AppColors.danger,
        title: '$atRisk student${atRisk == 1 ? '' : 's'} across the school need intervention',
        detail: 'Review class analytics and schedule re-teaching',
        builder: (_) => const AnalyticsScreen(),
      ));
    }
    if (pendingMarks > 0) {
      attention.add(AttentionItem(
        icon: Icons.grading_outlined,
        color: AppColors.warning,
        title: '$pendingMarks answer sheets awaiting marking',
        detail: 'Results become available to parents once confirmed',
        builder: (_) => const MarkingDashboardScreen(),
      ));
    }
    if (attention.isEmpty) {
      attention.add(AttentionItem(
        icon: Icons.check_circle_outline,
        color: AppColors.success,
        title: 'School is running smoothly',
        detail: 'No urgent issues detected. Open a module to get started.',
      ));
    }
    return OverviewData(stats: stats, attention: attention);
  }

  Future<OverviewData> _parentOverview() async {
    final studentsRepo = StudentsRepository();
    final children = await studentsRepo.byParentAll(widget.user);
    final extras = await studentsRepo.byParentUserAll(widget.user.id);
    final seen = <String>{};
    final allChildren = <Student>[];
    for (final s in [...children, ...extras]) {
      if (seen.add(s.id)) allChildren.add(s);
    }

    int unread = 0;
    try {
      unread = await NotificationsRepository().unreadCount(
          widget.user, await studentsRepo.active());
    } catch (e, st) {
      debugPrint('[HomeOverview] metric failed: $e');
      debugPrint(st.toString());
    }

    final stats = <OverviewStat>[
      OverviewStat(
          icon: Icons.child_care, value: '${allChildren.length}', label: 'Child'),
      OverviewStat(
          icon: Icons.notifications_outlined,
          value: '$unread',
          label: 'Unread',
          builder: (_) => const NotificationsInboxScreen()),
    ];

    final attention = <AttentionItem>[];
    if (unread > 0) {
      attention.add(AttentionItem(
        icon: Icons.notifications_active_outlined,
        color: AppColors.info,
        title: '$unread new update${unread == 1 ? '' : 's'} for you',
        detail: 'Attendance, results and school messages',
        builder: (_) => const NotificationsInboxScreen(),
      ));
    }
    if (allChildren.isEmpty) {
      attention.add(AttentionItem(
        icon: Icons.child_care,
        color: AppColors.warning,
        title: 'No child linked to this account yet',
        detail: 'Ask the school to link your child to see their progress.',
      ));
    } else {
      final first = allChildren.first;
      try {
        final today = await AttendanceRepository().forClassDate(
            first.classId, _today());
        final absent = today.where((r) => r.studentId == first.id &&
            r.status == AttendanceStatus.absent).length;
        final late = today.where((r) => r.studentId == first.id &&
            r.status == AttendanceStatus.late).length;
        if (absent > 0 || late > 0) {
          attention.add(AttentionItem(
            icon: Icons.event_busy_outlined,
            color: AppColors.warning,
            title: '${first.firstName} marked $absent absent · $late late today',
            detail: 'Check attendance for details',
          ));
        }
      } catch (e, st) {
        debugPrint('[HomeOverview] child attendance failed: $e');
        debugPrint(st.toString());
      }
    }
    if (attention.isEmpty) {
      attention.add(AttentionItem(
        icon: Icons.check_circle_outline,
        color: AppColors.success,
        title: 'All caught up',
        detail: 'No urgent updates for your child right now.',
      ));
    }
    return OverviewData(stats: stats, attention: attention);
  }

  Future<OverviewData> _studentOverview() async {
    var unread = 0;
    var dueAssignments = 0;
    var recentResult = false;
    try {
      final students = await StudentsRepository().active();
      unread = await NotificationsRepository().unreadCount(widget.user, students);
      final assignments = await AssignmentsRepository().all();
      final me = widget.user;
      final classId = me.classId;
      final studentId = me.id.replaceFirst('USR-', '');
      dueAssignments = assignments
          .where((a) => a.classId == classId && !a.completedBy.contains(studentId))
          .length;
      recentResult = (await AssessmentRepository().submissions())
          .any((s) => s.studentId == studentId);
    } catch (e, st) {
      debugPrint('[HomeOverview] metric failed: $e');
      debugPrint(st.toString());
    }

    final stats = <OverviewStat>[
      OverviewStat(
          icon: Icons.assignment_outlined,
          value: '$dueAssignments',
          label: 'Due'),
      OverviewStat(
          icon: Icons.notifications_outlined,
          value: '$unread',
          label: 'Updates'),
    ];

    final attention = <AttentionItem>[];
    if (dueAssignments > 0) {
      attention.add(AttentionItem(
        icon: Icons.assignment_outlined,
        color: AppColors.info,
        title: '$dueAssignments assignment${dueAssignments == 1 ? '' : 's'} to complete',
        detail: 'Check what\'s due and submit before the deadline',
      ));
    }
    if (unread > 0) {
      attention.add(AttentionItem(
        icon: Icons.notifications_active_outlined,
        color: AppColors.warning,
        title: '$unread new update${unread == 1 ? '' : 's'} for you',
        detail: 'Results, corrections and school messages',
        builder: (_) => const NotificationsInboxScreen(),
      ));
    }
    if (recentResult) {
      attention.add(AttentionItem(
        icon: Icons.emoji_events_outlined,
        color: AppColors.success,
        title: 'New results available',
        detail: 'See your scores and what to practice next',
      ));
    }
    if (attention.isEmpty) {
      attention.add(AttentionItem(
        icon: Icons.check_circle_outline,
        color: AppColors.success,
        title: 'All caught up',
        detail: 'Nothing due right now. Keep practicing in Study Hub.',
      ));
    }
    return OverviewData(stats: stats, attention: attention);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<OverviewData>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          // Skeleton keeps the panel's shape while the summary loads.
          return const SvCardSkeleton(lines: 4);
        }
        if (snap.hasError) {
          return _OverviewCard(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SvErrorState(
                title: 'Couldn\'t load your summary',
                message: 'Open a module below — we\'ll retry this afterwards.',
                onRetry: _reload,
              ),
            ),
          );
        }
        final data = snap.data ?? const OverviewData(stats: [], attention: []);
        return SvEntrance(
          offset: const Offset(0, .04),
          child: _OverviewCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    _AccentBar(),
                    SizedBox(width: 8),
                    Text(
                      'What needs attention',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                  ],
                ),
              ),
              if (data.stats.isNotEmpty) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  // One evenly divided row at every width, so all of a
                  // role's stats stay visible together.
                  child: Row(
                    children: [
                      for (final s in data.stats)
                        Expanded(child: _statTile(s)),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 6),
              for (var i = 0; i < data.attention.length; i++)
                SvEntrance(
                  delay: Duration(milliseconds: 80 * i.clamp(0, 8)),
                  child: _attentionRow(data.attention[i]),
                ),
              const SizedBox(height: 6),
            ],
          ),
        ),
        );
      },
    );
  }

  Widget _statTile(OverviewStat s) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: AppColors.brand.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.brand.withValues(alpha: .08)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: s.builder == null
            ? null
            : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: s.builder!),
                ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: Column(
            children: [
              Icon(s.icon, size: 18, color: AppColors.brand),
              const SizedBox(height: 5),
              SvAnimatedNumber(
                value: s.value,
                style:
                    const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                s.label,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted, fontSize: 9.5),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _attentionRow(AttentionItem a) {
    final content = ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [a.color, a.color.withValues(alpha: .58)],
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(a.icon, size: 18, color: Colors.white),
      ),
      title: Text(a.title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
      subtitle: a.detail.isEmpty
          ? null
          : Text(a.detail,
              style: TextStyle(fontSize: 11.5, color: AppColors.muted)),
      trailing: a.builder == null
          ? null
          : Icon(Icons.chevron_right, size: 20, color: AppColors.muted),
      dense: true,
      minVerticalPadding: 4,
    );
    if (a.builder == null) return content;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: a.builder!),
      ),
      child: content,
    );
  }
}

class _AccentBar extends StatelessWidget {
  const _AccentBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: 16,
      decoration: BoxDecoration(
        color: AppTheme.gold,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 2, 16, 12),
      color: AppColors.surface,
      child: child,
    );
  }
}

class OverviewStat {
  final IconData icon;
  final String value;
  final String label;
  final WidgetBuilder? builder;

  const OverviewStat({
    required this.icon,
    required this.value,
    required this.label,
    this.builder,
  });
}

class AttentionItem {
  final IconData icon;
  final String title;
  final String detail;
  final Color color;
  final WidgetBuilder? builder;

  const AttentionItem({
    required this.icon,
    required this.title,
    this.detail = '',
    required this.color,
    this.builder,
  });
}

class OverviewData {
  final List<OverviewStat> stats;
  final List<AttentionItem> attention;

  const OverviewData({
    this.stats = const [],
    this.attention = const [],
  });
}