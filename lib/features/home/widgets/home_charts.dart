import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/models/attendance.dart';
import '../../../core/models/user.dart';
import '../../../core/responsive.dart';
import '../../../core/storage/local_store.dart';
import '../../../core/sync/server_sync.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_kit.dart';
import '../../analytics/analytics_service.dart';
import '../../assessment/assessment_repository.dart';
import 'home_panels.dart';

/// One plotted value: its axis label, its value (0–100 for a percentage, or
/// a count) and the line a tooltip or table row shows for it.
class ChartPoint {
  const ChartPoint(this.label, this.value, this.detail);

  final String label;
  final double value;
  final String detail;
}

/// The charts on the home dashboard, scoped to what the signed-in person may
/// see: a teacher their class, a parent their children, a student themself,
/// leaders the whole school. Every chart is one series, so its title names
/// it and there is no legend; each can be switched to a table.
class HomeCharts extends StatefulWidget {
  const HomeCharts({super.key, required this.user});

  final User user;

  @override
  State<HomeCharts> createState() => _HomeChartsState();
}

class _HomeChartsState extends State<HomeCharts> {
  late Future<_ChartData> _future = _load();

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

  Future<_ChartData> _load() async {
    final user = widget.user;
    final students = await homeScope(user);
    final ids = {for (final s in students) s.id};
    final repo = AssessmentRepository();
    final assessments = await repo.assessments();
    final subs = (await repo.submissions()).where((s) => ids.contains(s.studentId)).toList();
    final attendance = (await LocalStore().loadAttendance()).where((r) => ids.contains(r.studentId)).toList();
    final family = user.role.isParent || user.role.isStudent;

    // Attendance: share present (or late) per school day, the last ten.
    final byDay = <String, List<AttendanceRecord>>{};
    for (final r in attendance) {
      byDay.putIfAbsent(r.date, () => []).add(r);
    }
    final days = byDay.keys.toList()..sort();
    final attendancePoints = [
      for (final d in days.skip(math.max(0, days.length - 10)))
        () {
          final rs = byDay[d]!;
          final here = rs
              .where((r) => r.status == AttendanceStatus.present || r.status == AttendanceStatus.late)
              .length;
          final pct = 100 * here / rs.length;
          return ChartPoint(_shortDate(d), pct, '${_shortDate(d)}: ${pct.round()}% present ($here of ${rs.length})');
        }(),
    ];

    // Results: average score per assessment, oldest first, the last eight.
    final byId = {for (final a in assessments) a.id: a};
    final scored = <String, List<double>>{};
    for (final s in subs) {
      final a = byId[s.assessmentId];
      if (a == null || a.totalMarks <= 0) continue;
      scored.putIfAbsent(a.id, () => []).add(100 * s.earned / a.totalMarks);
    }
    final marked = scored.keys.map((id) => byId[id]!).toList()..sort((a, b) => a.date.compareTo(b.date));
    final resultPoints = [
      for (final a in marked.skip(math.max(0, marked.length - 8)))
        () {
          final pcts = scored[a.id]!;
          final avg = pcts.reduce((x, y) => x + y) / pcts.length;
          final who = family ? '' : ' · ${pcts.length} paper${pcts.length == 1 ? '' : 's'}';
          return ChartPoint(a.title, avg, '${a.title}: ${avg.round()}%$who');
        }(),
    ];

    // Grade spread over every marked paper in view.
    const grades = ['A', 'B', 'C', 'D', 'E', 'F'];
    final counts = {for (final g in grades) g: 0};
    for (final pcts in scored.values) {
      for (final p in pcts) {
        final g = gradeLetter(p);
        if (counts.containsKey(g)) counts[g] = counts[g]! + 1;
      }
    }
    final gradePoints = [
      for (final g in grades)
        ChartPoint(g, counts[g]!.toDouble(), 'Grade $g: ${counts[g]} paper${counts[g] == 1 ? '' : 's'}'),
    ];

    return _ChartData(
      attendance: attendancePoints,
      results: resultPoints,
      grades: scored.isEmpty ? const [] : gradePoints,
      family: family,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_ChartData>(
      future: _future,
      builder: (context, snap) {
        final d = snap.data;
        if (d == null) {
          // Placeholders the size of the charts, so the page doesn't jump.
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: ResponsiveGridView(
              minItemWidth: 320,
              maxColumns: 3,
              minColumns: 1,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.45,
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: const [SvCardSkeleton(lines: 5), SvCardSkeleton(lines: 5), SvCardSkeleton(lines: 5)],
            ),
          );
        }
        final who = widget.user.role.isTeacher
            ? 'Your class'
            : d.family
                ? (widget.user.role.isParent ? 'Your children' : 'You')
                : 'Whole school';
        final cards = [
          ChartCard(
            title: 'Attendance',
            subtitle: '$who · % present, last ${d.attendance.length} school days',
            points: d.attendance,
            empty: 'No attendance recorded yet.',
            chart: (p) => LineChart(points: p, max: 100, unit: '%'),
          ),
          ChartCard(
            title: d.family ? 'Results' : 'Average results',
            subtitle: '$who · score % per assessment',
            points: d.results,
            empty: 'No marked work yet.',
            chart: (p) => BarChart(points: p, max: 100, unit: '%'),
          ),
          if (!d.family)
            ChartCard(
              title: 'Grade spread',
              subtitle: '$who · marked papers per grade',
              points: d.grades,
              empty: 'No marked work yet.',
              chart: (p) => BarChart(points: p, max: null, unit: ''),
            ),
        ];
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: ResponsiveGridView(
            minItemWidth: 320,
            maxColumns: 3,
            minColumns: 1,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.45,
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: cards,
          ),
        );
      },
    );
  }
}

class _ChartData {
  const _ChartData({required this.attendance, required this.results, required this.grades, required this.family});

  final List<ChartPoint> attendance;
  final List<ChartPoint> results;
  final List<ChartPoint> grades;
  final bool family;
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _shortDate(String iso) {
  final p = iso.split('-');
  if (p.length < 3) return iso;
  final m = int.tryParse(p[1]) ?? 0;
  return '${int.tryParse(p[2]) ?? p[2]} ${m >= 1 && m <= 12 ? _months[m - 1] : p[1]}';
}

String _num(double v) => v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// A titled chart with a chart/table switch — the table is the accessible
/// view of the same numbers.
class ChartCard extends StatefulWidget {
  const ChartCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.points,
    required this.empty,
    required this.chart,
  });

  final String title;
  final String subtitle;
  final List<ChartPoint> points;
  final String empty;
  final Widget Function(List<ChartPoint>) chart;

  @override
  State<ChartCard> createState() => _ChartCardState();
}

class _ChartCardState extends State<ChartCard> {
  var _table = false;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border.withValues(alpha: .6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.title,
                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.ink)),
                      Text(widget.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: AppColors.muted)),
                    ],
                  ),
                ),
                if (widget.points.isNotEmpty)
                  IconButton(
                    tooltip: _table ? 'Show as chart' : 'Show as table',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _table = !_table),
                    icon: Icon(_table ? Icons.insert_chart_outlined : Icons.table_rows_outlined,
                        size: 20, color: AppColors.muted),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: widget.points.isEmpty
                    ? Center(child: Text(widget.empty, style: TextStyle(color: AppColors.muted)))
                    : _table
                        ? _ChartTable(widget.points)
                        : widget.chart(widget.points),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartTable extends StatelessWidget {
  const _ChartTable(this.points);

  final List<ChartPoint> points;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: points.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: AppColors.border),
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(points[i].detail, style: TextStyle(fontSize: 13, color: AppColors.ink)),
      ),
    );
  }
}

const _axisWidth = 32.0;

/// Recessive gridlines with their values, shared by both chart forms.
class _Grid extends StatelessWidget {
  const _Grid({required this.max, required this.unit, required this.child});

  final double max;
  final String unit;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 10, color: AppColors.muted);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: _axisWidth,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${_num(max)}$unit', style: style),
              Text('${_num(max / 2)}$unit', style: style),
              Text('0', style: style),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (var i = 0; i < 3; i++)
                      Container(height: 1, color: AppColors.border.withValues(alpha: i == 2 ? 1 : .5)),
                  ],
                ),
              ),
              Positioned.fill(child: child),
            ],
          ),
        ),
      ],
    );
  }
}

/// Columns from a zero baseline, rounded at the data end, each with a
/// tooltip; values are labelled directly when there are few enough to fit.
class BarChart extends StatelessWidget {
  const BarChart({super.key, required this.points, required this.max, required this.unit});

  final List<ChartPoint> points;

  /// The top of the scale; null rounds the largest value up to a nice step.
  final double? max;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final top = max ?? _niceMax(points.map((p) => p.value).fold(0.0, math.max));
    final labelled = points.length <= 8;
    return Column(
      children: [
        Expanded(
          child: _Grid(
            max: top,
            unit: unit,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final p in points)
                  Expanded(
                    child: Tooltip(
                      message: p.detail,
                      triggerMode: TooltipTriggerMode.tap,
                      child: LayoutBuilder(builder: (context, c) {
                        final h = top <= 0 ? 0.0 : (c.maxHeight - 14) * (p.value / top).clamp(0.0, 1.0);
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (labelled)
                              Text('${_num(p.value.roundToDouble())}$unit',
                                  style: TextStyle(fontSize: 10, color: AppColors.body)),
                            Container(
                              width: math.min(28, c.maxWidth * .6),
                              height: math.max(h, p.value > 0 ? 2 : 0),
                              decoration: BoxDecoration(
                                color: AppColors.chart,
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                              ),
                            ),
                          ],
                        );
                      }),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        _XLabels(points),
      ],
    );
  }

  static double _niceMax(double v) {
    if (v <= 0) return 1;
    final step = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
    return (v / step).ceil() * step;
  }
}

class _XLabels extends StatelessWidget {
  const _XLabels(this.points);

  final List<ChartPoint> points;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: _axisWidth + 6),
      child: Row(
        children: [
          for (final p in points)
            Expanded(
              child: Text(p.label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: AppColors.muted)),
            ),
        ],
      ),
    );
  }
}

/// A single-series line with a light area beneath it. Hovering or tapping
/// shows a crosshair on the nearest day and its value.
class LineChart extends StatefulWidget {
  const LineChart({super.key, required this.points, required this.max, required this.unit});

  final List<ChartPoint> points;
  final double max;
  final String unit;

  @override
  State<LineChart> createState() => _LineChartState();
}

class _LineChartState extends State<LineChart> {
  int? _active;

  void _pick(Offset at, double width) {
    final n = widget.points.length;
    if (n == 0) return;
    final slot = width / n;
    setState(() => _active = (at.dx / slot).floor().clamp(0, n - 1));
  }

  @override
  Widget build(BuildContext context) {
    final points = widget.points;
    return Column(
      children: [
        Expanded(
          child: _Grid(
            max: widget.max,
            unit: widget.unit,
            child: LayoutBuilder(builder: (context, c) {
              final active = _active;
              return MouseRegion(
                onHover: (e) => _pick(e.localPosition, c.maxWidth),
                onExit: (_) => setState(() => _active = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (e) => _pick(e.localPosition, c.maxWidth),
                  child: Semantics(
                    label: points.map((p) => p.detail).join('. '),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _LinePainter(
                              values: [for (final p in points) p.value / widget.max],
                              colour: AppColors.chart,
                              ring: AppColors.surface,
                              guide: AppColors.muted,
                              active: active,
                            ),
                          ),
                        ),
                        if (active != null)
                          Positioned(
                            top: 0,
                            left: ((active + .5) * c.maxWidth / points.length - 80).clamp(0.0, math.max(0.0, c.maxWidth - 160)),
                            width: 160,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                              decoration: BoxDecoration(
                                color: AppColors.ink,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(points[active].detail,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 11, color: AppColors.surface)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 4),
        _XLabels(points),
      ],
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({required this.values, required this.colour, required this.ring, required this.guide, this.active});

  final List<double> values;
  final Color colour;
  final Color ring;
  final Color guide;
  final int? active;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final slot = size.width / values.length;
    Offset at(int i) => Offset((i + .5) * slot, size.height * (1 - values[i].clamp(0.0, 1.0)));

    final line = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < values.length; i++) {
      line.lineTo(at(i).dx, at(i).dy);
    }
    final area = Path.from(line)
      ..lineTo(at(values.length - 1).dx, size.height)
      ..lineTo(at(0).dx, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = colour.withValues(alpha: .14));
    canvas.drawPath(
      line,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    if (active != null) {
      final x = at(active!).dx;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()..color = guide.withValues(alpha: .5));
    }
    for (var i = 0; i < values.length; i++) {
      final r = i == active ? 5.0 : 4.0;
      canvas.drawCircle(at(i), r + 2, Paint()..color = ring);
      canvas.drawCircle(at(i), r, Paint()..color = colour);
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.values != values || old.colour != colour || old.active != active || old.ring != ring;
}
