import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/question.dart';
import '../../core/models/submission.dart';
import '../../core/models/grading.dart';
import '../../core/models/subjects.dart';
import '../../core/models/subjects.dart' as app_subjects;
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../assessment/assessment_repository.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'mock_take_screen.dart';

/// Public-exam programmes (doc §45): BECE / WASSCE timed papers built from
/// the question bank, plus weak-topic practice analytics.
class PrepScreen extends StatefulWidget {
  const PrepScreen({super.key});

  @override
  State<PrepScreen> createState() => _PrepScreenState();
}

class _Programme {
  final String name;
  final String description;
  final List<({String subjectId, String paper, int minutes})> papers;

  const _Programme({
    required this.name,
    required this.description,
    required this.papers,
  });
}

const _beceProgramme = _Programme(
  name: 'BECE',
  description: 'Basic Education Certificate Examination — JHS 3',
  papers: [
    (subjectId: 'MATH', paper: 'Mathematics Paper 1', minutes: 30),
    (subjectId: 'ENG', paper: 'English Paper 1', minutes: 30),
    (subjectId: 'SCI', paper: 'Integrated Science Paper 1', minutes: 30),
    (subjectId: 'SOC', paper: 'Social Studies Paper 1', minutes: 30),
    (subjectId: 'ICT', paper: 'ICT Paper 1', minutes: 30),
    (subjectId: 'RME', paper: 'RME Paper 1', minutes: 30),
  ],
);

const _wasseProgramme = _Programme(
  name: 'WASSCE',
  description: 'West African Senior School Certificate Examination',
  papers: [
    (subjectId: 'MATH', paper: 'Core Mathematics Paper 1', minutes: 45),
    (subjectId: 'ENG', paper: 'Core English Paper 1', minutes: 60),
    (subjectId: 'SCI', paper: 'Integrated Science Paper 1', minutes: 45),
  ],
);

class _PrepScreenState extends State<PrepScreen> {
  late Future<PrepData> _data;
  String _programme = 'BECE';

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<PrepData> _load() async {
    final me = await AuthRepository().currentUser();
    if (me == null) {
      throw StateError('You need to be signed in to view prep.');
    }
    final schoolId = me.schoolId ?? 'SCH-001';
    final studentId =
        me.role.isStudent ? me.id.replaceFirst('USR-', '') : me.id;
    final repo = AssessmentRepository();
    final store = LocalStore();
    final students = await StudentsRepository().all();
    final student = students.where((s) => s.id == studentId).firstOrNull;
    final classId = student?.classId ?? me.classId ?? '';
    // Only this student's own class's work and their own marks count.
    final assessments = [
      for (final a in await repo.assessments())
        if (classId.isEmpty || a.classId == classId) a,
    ];
    final subs = [
      for (final s in await repo.submissions())
        if (s.studentId == studentId) s,
    ];
    final bank = await repo.bank();
    final mocks =
        assessments.where((a) => a.type == AssessmentType.mock).toList();
    final targets = await store.loadTargets(userId: me.id);
    final grading = await store.loadGradingConfig();
    final classes = await store.loadClasses();
    return PrepData(
      studentId: studentId,
      schoolId: schoolId,
      mocks: mocks,
      subs: subs,
      assessments: assessments,
      bank: bank,
      targets: targets,
      scheme: grading.schemeFor(classId, classes),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'BECE / WASSCE Prep'),
      body: FutureBuilder<PrepData>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return SvErrorState(
              title: "Couldn't load prep",
              message: 'We couldn\'t load your prep. Please try again.',
              onRetry: () => setState(() { _data = _load(); }),
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const SvLoading(message: 'Preparing your dashboard…');
          }
          final d = snap.data;
          if (d == null) return const SvErrorState();
          return DefaultTabController(
            length: 3,
            child: Column(
              children: [
                const TabBar(tabs: [
                  Tab(text: 'Mocks'),
                  Tab(text: 'Programmes'),
                  Tab(text: 'Targets'),
                ]),
                Expanded(
                  child: TabBarView(
                    children: [_mocks(d), _programmes(d), _targets(d)],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _mocks(PrepData d) {
    if (d.mocks.isEmpty) {
      return const SvEmptyState(
        icon: Icons.hourglass_empty,
        title: 'No mock exams published yet',
        message: 'Check back soon — your teacher will publish timed exams '
            'here as exam season approaches.',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Timed mock exams. Every attempt is saved to your results.',
            style: TextStyle(fontSize: 12, color: AppColors.muted)),
        const SizedBox(height: 8),
        for (final (i, a) in d.mocks.indexed)
          Builder(builder: (context) {
            final best = d.bestPercent(a.id);
            return SvEntrance(
              delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
              child: SvPressScale(
                child: Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppTheme.brand.withValues(alpha: .12),
                  child: Icon(Icons.timer, color: AppColors.brand),
                ),
                title: Text(a.title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                    '${subjectName(a.subjectId)} · ${a.questions.length} '
                    'questions · ${a.totalMarks.toStringAsFixed(0)} marks\n'
                    '${best == null ? 'Not attempted yet' : 'Best: ${best.toStringAsFixed(1)}% — '
                        'grade ${d.scheme.bandFor(best).grade}'}'),
                isThreeLine: true,
                trailing: const Icon(Icons.play_circle_fill,
                    color: AppTheme.accent),
                onTap: () async {
                  if (a.questions.isEmpty) {
                    svSnack(context,
                        'This exam has no questions yet — let your teacher know.',
                        error: true);
                    return;
                  }
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MockTakeScreen(
                          assessment: a, studentId: d.studentId),
                    ),
                  );
                  setState(() { _data = _load(); });
                },
              ),
            ),
          ),
        );
          }),
      ],
    );
  }

  Widget _programmes(PrepData d) {
    final programme = _programme == 'WASSCE'
        ? _wasseProgramme
        : _beceProgramme;
    final available = <String, int>{};
    for (final q in d.bank) {
      available.update(q.subjectId, (v) => v + 1, ifAbsent: () => 1);
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Timed papers from the question bank, built for public exams. '
            'Your results count toward your subject averages.',
            style: TextStyle(fontSize: 12, color: AppColors.muted)),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final p in const ['BECE', 'WASSCE'])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(p),
                  selected: _programme == p,
                  onSelected: (_) => setState(() => _programme = p),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(programme.description,
            style: TextStyle(fontSize: 12, color: AppColors.body)),
        const SizedBox(height: 10),
        for (final (i, paper) in programme.papers.indexed)
          Builder(builder: (context) {
            final n = available[paper.subjectId] ?? 0;
            return SvEntrance(
              delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
              child: SvPressScale(
                child: Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppTheme.brand.withValues(alpha: .12),
                  child: Icon(Icons.timer_outlined,
                      color: AppColors.brand),
                ),
                title: Text('${subjectName(paper.subjectId)} · ${paper.paper}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${paper.minutes} minutes · '
                    '${available[paper.subjectId] ?? 0} bank questions'),
                trailing: const Icon(Icons.play_circle_fill,
                    color: AppTheme.accent),
                onTap: () async {
                  if (n == 0) {
                    svSnack(context,
                        'No bank questions for ${subjectName(paper.subjectId)} yet.',
                        error: true);
                    return;
                  }
                  final qs = AssessmentRepository().blueprintPick(
                    from: d.bank,
                    subjectId: paper.subjectId,
                    count: n > 20 ? 20 : n,
                  );
                  final paperAssessment = Assessment(
                    id: 'PAP-${DateTime.now().millisecondsSinceEpoch}',
                    title: '$programme ${paper.paper}',
                    type: AssessmentType.mock,
                    subjectId: paper.subjectId,
                    classId: d.studentPrimaryClass ?? 'JHS3',
                    date: _today(),
                    createdBy: 'BECE / WASSCE Prep',
                    questions: qs,
                  );
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MockTakeScreen(
                        assessment: paperAssessment,
                        studentId: d.studentId,
                        durationMinutes: paper.minutes,
                      ),
                    ),
                  );
                  setState(() { _data = _load(); });
                },
              ),
            ),
          ),
        );
          }),
        const Divider(height: 28),
        _weakTopics(d),
      ],
    );
  }

  Widget _weakTopics(PrepData d) {
    final topics = d.topicStrength();
    final weak = topics.where((t) => t.pct < 60).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.psychology_outlined, color: AppColors.brand, size: 18),
            SizedBox(width: 6),
            Text('Weak-topic practice',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          ],
        ),
        const SizedBox(height: 6),
        if (weak.isEmpty) ...[
          Card(
            child: ListTile(
              leading: Icon(Icons.check_circle, color: AppColors.success),
              title: Text('No weak topics right now'),
              subtitle: Text('Your accuracy is above 60% in every assessed '
                  'topic. Keep practising to stay sharp.'),
            ),
          ),
        ] else
          for (final (i, t) in weak.indexed)
            SvEntrance(
              delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
              child: SvPressScale(
                child: Card(
              child: ListTile(
                leading: Icon(Icons.priority_high,
                    color: AppColors.warning),
                title: Text('${t.topic} · ${t.pct.toStringAsFixed(0)}% accurate',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${t.correct}/${t.total} correct · '
                    '${subjectName(t.subjectId)}'),
                trailing: const Icon(Icons.play_circle_fill,
                    color: AppTheme.accent),
                onTap: () async {
                  final qs = AssessmentRepository().blueprintPick(
                    from: d.bank,
                    topic: t.topic,
                    subjectId: t.subjectId,
                    count: 5,
                  );
                  if (qs.isEmpty) {
                    svSnack(context, 'No bank questions for ${t.topic} yet.',
                        error: true);
                    return;
                  }
                  final practice = Assessment(
                    id: 'PRAC-${DateTime.now().millisecondsSinceEpoch}',
                    title: 'Topic practice — ${t.topic}',
                    type: AssessmentType.exercise,
                    subjectId: t.subjectId,
                    classId: d.studentPrimaryClass ?? 'JHS3',
                    date: _today(),
                    createdBy: 'BECE / WASSCE Prep',
                    questions: qs,
                  );
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MockTakeScreen(
                          assessment: practice, studentId: d.studentId),
                    ),
                  );
                  setState(() { _data = _load(); });
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _targets(PrepData d) {
    final aggregate = d.predictedAggregate();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Set your target grade per subject. The app compares your '
            'current scores, on your school\'s grading.',
            style: TextStyle(fontSize: 12, color: AppColors.muted)),
        if (d.scheme.showAggregate)
          Card(
            child: ListTile(
              leading: Icon(Icons.emoji_events_outlined, color: AppColors.brand),
              title: Text(aggregate == null
                  ? 'Predicted aggregate: not enough scores yet'
                  : 'Predicted aggregate: $aggregate'),
              subtitle: Text(
                  'From your current scores: ${d.scheme.coreSubjects.map(subjectName).join(', ')}'
                  '${d.scheme.bestOthers > 0 ? ' + your best ${d.scheme.bestOthers}' : ''}. '
                  'Lower is better.'),
            ),
          ),
        const SizedBox(height: 8),
        for (final (i, sub) in d.subjects.indexed)
          Builder(builder: (context) {
            final current = d.currentPercent(sub.id);
            final target = d.targetFor(sub.id);
            final grade =
                current == null ? '–' : d.scheme.bandFor(current).grade;
            final onTrack = current != null &&
                d.gradeRank(grade) >= d.gradeRank(target);
            return SvEntrance(
              delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
              child: SvPressScale(
                child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(sub.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                          Text(
                            current == null
                                ? 'No scores yet'
                                : 'Current ${current.toStringAsFixed(1)}% '
                                    '(grade $grade)',
                            style: TextStyle(
                                fontSize: 12, color: AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                    if (current != null)
                      Chip(
                        label: Text(onTrack ? 'On track' : 'Needs work'),
                        backgroundColor: onTrack
                            ? AppColors.successBg
                            : AppColors.warningBg,
                        labelStyle: TextStyle(
                            color: onTrack
                                ? AppColors.success
                                : AppColors.warning,
                            fontWeight: FontWeight.w600),
                      ),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: target,
                      onChanged: (v) async {
                        if (v == null) return;
                        final targets = Map<String, String>.from(d.targets)
                          ..[sub.id] = v;
                        final me = await AuthRepository().currentUser();
                        if (me == null) return;
                        await LocalStore().saveTargets(targets, userId: me.id);
                        await ServerSync.instance.send(
                            'PUT', '/api/records/targets/${me.id}',
                            body: {'id': me.id, 'targets': targets});
                        if (!mounted) return;
                        setState(() { _data = _load(); });
                      },
                      items: [
                        for (final b in d.scheme.bands)
                          DropdownMenuItem(
                              value: b.grade, child: Text('Target ${b.grade}')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
          }),
      ],
    );
  }

  String _today() {
    final d = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)}';
  }

}

class PrepData {
  final String studentId;
  final String schoolId;
  final List<Assessment> mocks;
  final List<AssessmentSubmission> subs;
  final List<Assessment> assessments;
  final List<Question> bank;
  final Map<String, String> targets;

  /// The school's grading scheme for this student's class.
  final GradingScheme scheme;

  const PrepData({
    required this.studentId,
    required this.schoolId,
    required this.mocks,
    required this.subs,
    required this.assessments,
    required this.bank,
    required this.targets,
    this.scheme = gesBasicPreset,
  });

  /// Subjects the class is taking, plus the scheme's core subjects.
  List<Subject> get subjects {
    final ids = {
      ...scheme.coreSubjects,
      for (final a in assessments) a.subjectId,
    };
    return [
      for (final s in app_subjects.subjects)
        if (ids.contains(s.id)) s,
    ];
  }

  /// 0 for the lowest grade upwards; -1 for one not on the scheme.
  int gradeRank(String grade) {
    final i = scheme.bands.indexWhere((b) => b.grade == grade);
    return i < 0 ? -1 : scheme.bands.length - 1 - i;
  }

  /// The target set for [subjectId] if it is a grade on today's scheme,
  /// else the pass mark's grade (the band holding 50).
  String targetFor(String subjectId) {
    final t = targets[subjectId];
    if (t != null && gradeRank(t) >= 0) return t;
    return scheme.bandFor(50).grade;
  }

  /// BECE-style aggregate from current scores (the scheme's core subjects
  /// plus its best others), or `null` when the scores aren't all in yet.
  int? predictedAggregate() {
    if (!scheme.showAggregate || !scheme.numericGrades) return null;
    final cores = <int>[];
    final others = <int>[];
    for (final s in subjects) {
      final p = currentPercent(s.id);
      if (p == null) continue;
      final g = int.parse(scheme.bandFor(p).grade);
      (scheme.coreSubjects.contains(s.id) ? cores : others).add(g);
    }
    others.sort();
    if (cores.length < scheme.coreSubjects.length ||
        others.length < scheme.bestOthers) {
      return null;
    }
    return [...cores, ...others.take(scheme.bestOthers)]
        .fold<int>(0, (a, b) => a + b);
  }

  /// Best saved score for a published mock.
  double? bestPercent(String assessmentId) {
    final mine = subs
        .where((s) => s.assessmentId == assessmentId && s.studentId == studentId)
        .toList();
    if (mine.isEmpty) return null;
    final a = assessments.firstWhere((x) => x.id == assessmentId,
        orElse: () => assessments.first);
    if (a.totalMarks <= 0) return null;
    final best = mine.map((s) => 100 * s.earned / a.totalMarks).reduce(_max);
    return best;
  }

  static double _max(double a, double b) => a > b ? a : b;

  double? currentPercent(String subjectId) {
    var earned = 0.0, possible = 0.0;
    for (final a in assessments.where((x) => x.subjectId == subjectId)) {
      for (final s in subs.where(
          (x) => x.assessmentId == a.id && x.studentId == studentId)) {
        earned += s.earned;
        possible += a.totalMarks;
      }
    }
    return possible > 0 ? 100 * earned / possible : null;
  }

  /// Objective-question topic accuracy across this student's marked work,
  /// used to surface weak topics for targeted practice (doc §45).
  List<({String subjectId, String topic, int correct, int total, double pct})>
      topicStrength() {
    final counters = <String, List<int>>{};
    for (final a in assessments) {
      for (final q in a.questions.where((x) => x.isObjective)) {
        for (final s in subs) {
          if (s.assessmentId != a.id || s.studentId != studentId) continue;
          final c = counters.putIfAbsent(
              '${a.subjectId}|${q.topic}', () => [0, 0]);
          c[1] += 1;
          final got = s.answers[q.id]?.trim().toLowerCase() ?? '';
          if (got.isNotEmpty &&
              got == q.correctAnswer.trim().toLowerCase()) {
            c[0] += 1;
          }
        }
      }
    }
    final out =
        <({String subjectId, String topic, int correct, int total, double pct})>[];
    for (final e in counters.entries) {
      final parts = e.key.split('|');
      final pct = 100 * e.value[0] / e.value[1];
      out.add((
        subjectId: parts[0],
        topic: parts[1],
        correct: e.value[0],
        total: e.value[1],
        pct: pct,
      ));
    }
    out.sort((a, b) => a.pct.compareTo(b.pct));
    return out;
  }

  /// First class id found on the student's assessments (used to tag
  /// ephemeral practice assessments).
  String? get studentPrimaryClass {
    for (final a in assessments) {
      if (a.classId.isNotEmpty) return a.classId;
    }
    return null;
  }
}