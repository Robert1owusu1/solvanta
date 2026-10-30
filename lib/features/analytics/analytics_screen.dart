import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/subjects.dart';
import '../../core/responsive.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../assessment/assessment_repository.dart';
import '../students/students_repository.dart';
import 'analytics_service.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  late Future<ClassPerformance> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<ClassPerformance> _load() async {
    final assessments = await AssessmentRepository().assessments();
    final subs = await AssessmentRepository().submissions();
    final students = await StudentsRepository().all();
    return ClassPerformance(
        assessments: assessments, subs: subs, students: students);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Class & School Analytics'),
      body: FutureBuilder<ClassPerformance>(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final p = snap.data;
          if (p == null || p.assessments.isEmpty) {
            return const Center(child: Text('No assessment data yet'));
          }
          return DefaultTabController(
            length: 3,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'Overview'),
                    Tab(text: 'Learning gaps'),
                    Tab(text: 'Alerts'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _overview(p),
                      _gaps(p),
                      _alerts(p),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _overview(ClassPerformance p) {
    final subjects = p.assessments.map((a) => a.subjectId).toSet().toList();
    return ResponsiveBuilder(
      phone: (context) => ListView(
        padding: const EdgeInsets.all(16),
        children: _buildOverviewChildren(p, subjects),
      ),
      tablet: (context) => _OverviewGrid(p: p, subjects: subjects),
      desktop: (context) => _OverviewGrid(p: p, subjects: subjects, minItemWidth: 350),
    );
  }

  List<Widget> _buildOverviewChildren(ClassPerformance p, List<String> subjects) {
    return [
      _MetricCard(
        icon: Icons.school,
        label: 'Overall class average',
        value: '${(100 * p.classAverage()).toStringAsFixed(1)}%',
        color: AppColors.brand,
      ),
      const SizedBox(height: 16),
      Text('By subject', style: _head),
      const SizedBox(height: 8),
      for (final s in subjects)
        Card(
          child: ListTile(
            leading: const Icon(Icons.menu_book),
            title: Text(subjectName(s)),
            trailing: Text(
              '${(100 * p.subjectAverage(s)).toStringAsFixed(1)}%',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: AppColors.brand),
            ),
          ),
        ),
      const SizedBox(height: 16),
      Text('By assessment', style: _head),
      const SizedBox(height: 8),
      for (final a in p.assessments)
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                title: Text(a.title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                    '${subjectName(a.subjectId)} · ${a.date}'),
                trailing: Text(
                  '${(100 * p.averageFor(a)).toStringAsFixed(1)}%',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.accent),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _DistributionBar(dist: p.distributionFor(a)),
              ),
            ],
          ),
        ),
    ];
  }

  Widget _gaps(ClassPerformance p) {
    var gaps = <QuestionPerformance>[];
    for (final a in p.assessments) {
      gaps.addAll(p.gapsFor(a));
    }
    if (gaps.isEmpty) {
      return const Center(child: Text('Mark some work to see gaps'));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Lowest mastery first — re-teach the weakest '
            'topics before the next cycle.', style: _muted),
        const SizedBox(height: 12),
        for (final g in gaps)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(g.topic.isEmpty
                            ? g.questionId
                            : g.topic, style: _bold),
                      ),
                      _Pill(
                        label:
                            '${(100 * (1 - g.correctRate)).toStringAsFixed(0)}% wrong',
                        color: g.gap >= 0.5
                            ? AppColors.danger
                            : g.gap >= 0.3
                                ? AppColors.warning
                                : AppColors.success,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('${g.assessment.title} · Q · ${g.cognitiveLevel}',
                      style: _muted),
                  const SizedBox(height: 8),
                  Text('➜ ${interventionFor(g)}', style: _body),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _alerts(ClassPerformance p) {
    final alerts = p.atRisk(threshold: 50);
    final flagged = p.subs.map((s) => s.studentId).toSet().length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Icon(Icons.notifications_active,
                color: alerts.isNotEmpty ? AppColors.danger : AppColors.success),
            const SizedBox(width: 8),
            Text(
              alerts.isEmpty
                  ? 'No students at risk.'
                  : '${alerts.length} student(s) below 50% average '
                        'across $flagged assessed student(s)',
              style: _bold,
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final a in alerts)
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: AppColors.dangerBg,
                child: Text(a.student.initials,
                    style: TextStyle(
                        color: AppColors.danger, fontWeight: FontWeight.bold)),
              ),
              title: Text(a.student.fullName),
              subtitle: Text(
                  '${a.average.toStringAsFixed(1)}% avg (grade ${a.grade})\n'
                  '➜ ${a.suggestedIntervention}'),
              isThreeLine: true,
            ),
          ),
      ],
    );
  }

  final _head = const TextStyle(
      fontSize: 15, fontWeight: FontWeight.w700);
  final _muted =
      TextStyle(fontSize: 13, color: AppColors.muted);
  final _bold = const TextStyle(fontWeight: FontWeight.w700);
  final _body = const TextStyle(fontSize: 14);
}

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withValues(alpha: .12),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: _muted2)),
            Text(value,
                style: TextStyle(
                    fontSize: 26, fontWeight: FontWeight.w800, color: color)),
          ],
        ),
      ),
    );
  }
}

final _muted2 = TextStyle(color: AppColors.body, fontSize: 14);

class _DistributionBar extends StatelessWidget {
  final Map<String, int> dist;

  const _DistributionBar({required this.dist});

  // Single navy ramp (deepest = strongest grade), per the brand rule that
  // learning/grades views use the navy ramp — never traffic-light colors.
  // [dist] lists the school's grades best first, however many there are.
  static const _ramp = [
    AppTheme.navy900,
    AppTheme.navy700,
    AppTheme.navy500,
    AppTheme.navy400,
    AppTheme.navy200,
  ];

  static Color _colorAt(int i, int n) =>
      _ramp[n <= 1 ? 0 : (i * (_ramp.length - 1) / (n - 1)).round()];

  @override
  Widget build(BuildContext context) {
    final total = dist.values.fold(0, (x, y) => x + y);
    if (total == 0) {
      return Text('No grades yet', style: _muted2);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          height: 10,
          child: Row(
            children: [
              for (final (i, g) in dist.keys.indexed)
                if ((dist[g] ?? 0) > 0)
                  Expanded(
                    flex: dist[g]!,
                    child: Container(color: _colorAt(i, dist.length)),
                  ),
            ],
          ),
        ),
      ),
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.scale(
          scaleX: t,
          alignment: Alignment.centerLeft,
          child: child,
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;

  const _Pill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

class _OverviewGrid extends StatelessWidget {
  const _OverviewGrid({
    required this.p,
    required this.subjects,
    this.minItemWidth = 300,
  });

  final ClassPerformance p;
  final List<String> subjects;
  final double minItemWidth;

  @override
  Widget build(BuildContext context) {
    return ResponsiveGridView(
      minItemWidth: minItemWidth,
      maxColumns: 4,
      minColumns: 2,
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      padding: const EdgeInsets.all(16),
      baseAspectRatio: 1.2,
      children: [
        _MetricGridCard(
          icon: Icons.school,
          label: 'Overall class average',
          value: '${(100 * p.classAverage()).toStringAsFixed(1)}%',
          color: AppColors.brand,
        ),
        for (final s in subjects)
          _SubjectGridCard(
            subjectName: subjectName(s),
            average: '${(100 * p.subjectAverage(s)).toStringAsFixed(1)}%',
          ),
        for (final a in p.assessments)
          _AssessmentGridCard(assessment: a, performance: p),
      ],
    );
  }
}

class _MetricGridCard extends StatelessWidget {
  const _MetricGridCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: color.withValues(alpha: .12),
                  child: Icon(icon, color: color),
                ),
                const Spacer(),
                Text(
                  value,
                  style: TextStyle(
                      fontSize: 24, fontWeight: FontWeight.w800, color: color),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(label, style: _muted2),
          ],
        ),
      ),
    );
  }
}

class _SubjectGridCard extends StatelessWidget {
  const _SubjectGridCard({
    required this.subjectName,
    required this.average,
  });

  final String subjectName;
  final String average;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.menu_book, color: AppColors.brand, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    subjectName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                ),
              ],
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Average', style: _muted2),
                Text(
                  average,
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.brand),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AssessmentGridCard extends StatelessWidget {
  const _AssessmentGridCard({
    required this.assessment,
    required this.performance,
  });

  final Assessment assessment;
  final ClassPerformance performance;

  @override
  Widget build(BuildContext context) {
    final avg = (100 * performance.averageFor(assessment)).toStringAsFixed(1);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    assessment.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${subjectName(assessment.subjectId)} · ${assessment.date}',
              style: _muted2,
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Average', style: _muted2),
                Text(
                  '$avg%',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.accent),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _DistributionBar(dist: performance.distributionFor(assessment)),
          ],
        ),
      ),
    );
  }
}
