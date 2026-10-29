import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/intervention.dart';
import '../../core/models/student.dart';
import '../../core/models/submission.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../assessment/assessment_repository.dart';
import '../interventions/interventions_repository.dart';
import '../students/students_repository.dart';
import 'error_pattern_engine.dart';
import 'student_learning_profile.dart';

class LearningProfileScreen extends StatefulWidget {
  const LearningProfileScreen({super.key, this.studentId});

  final String? studentId;

  @override
  State<LearningProfileScreen> createState() => _LearningProfileScreenState();
}

class _LearningProfileScreenState extends State<LearningProfileScreen> {
  String? _studentId;

  late Future<
      (List<Student>, List<Assessment>, List<AssessmentSubmission>,
          List<Intervention>)> _data;
  late Future<StudentLearningProfile> _profile;

  @override
  void initState() {
    super.initState();
    _data = _loadBase();
    _studentId = widget.studentId;
    _profile = _loadProfile(_studentId);
  }

  Future<
      (List<Student>, List<Assessment>, List<AssessmentSubmission>,
          List<Intervention>)> _loadBase() async {
    final students = await StudentsRepository().active()
      ..sort((a, b) => a.classId.compareTo(b.classId));
    final assessments = await AssessmentRepository().assessments();
    final subs = await AssessmentRepository().submissions();
    final interventions = await InterventionsRepository().all();
    return (students, assessments, subs, interventions);
  }

  Future<StudentLearningProfile> _loadProfile(String? studentId) async {
    final (_, assessments, subs, interventions) = await _loadBase();
    if (studentId == null) {
      final student = Student(
        id: 'ALL',
        firstName: 'All',
        lastName: 'Students',
        gender: '',
        dateOfBirth: '',
        admissionDate: '',
        admissionNo: '',
        classId: '',
        schoolId: 'SCH-001',
      );
      return StudentLearningProfile(
        student: student,
        topics: _aggregate(assessments, subs),
        errorPatterns: _aggregatePatterns(assessments, subs),
        interventions: interventions,
      );
    }
    final student = await StudentsRepository().byId(studentId);
    if (student == null) {
      return StudentLearningProfile(
        student: Student(
          id: studentId,
          firstName: 'Unknown',
          lastName: 'Student',
          gender: '',
          dateOfBirth: '',
          admissionDate: '',
          admissionNo: '',
          classId: '',
          schoolId: 'SCH-001',
        ),
        topics: const [],
        errorPatterns: const [],
        interventions: const [],
      );
    }
    return LearningProfileBuilder(
      assessments: assessments,
      subs: subs,
      interventions: interventions,
    ).build(student);
  }

  List<TopicMastery> _aggregate(
      List<Assessment> assessments, List<AssessmentSubmission> subs) {
    final acc = <String, _Agg>{};
    for (final sub in subs) {
      final a = assessments.where((x) => x.id == sub.assessmentId).firstOrNull;
      if (a == null) continue;
      for (final q in a.questions) {
        final k = '${a.subjectId}::${q.topic}';
        final agg = acc.putIfAbsent(k, () => _Agg(a.subjectId, q.topic));
        final answer = (sub.answers[q.id] ?? '').trim();
        final isCorrect = q.isObjective
            ? answer.isNotEmpty &&
                answer.toLowerCase() == q.correctAnswer.trim().toLowerCase()
            : (sub.teacherMarks[q.id] ?? 0) >= q.marks * 0.8;
        agg.attempts++;
        if (isCorrect) agg.correct++;
      }
    }
    return [
      for (final a in acc.values)
        TopicMastery(
          subjectId: a.subjectId,
          topic: a.topic,
          attempts: a.attempts,
          correctRate: a.attempts == 0 ? 0 : a.correct / a.attempts,
        ),
    ]..sort((x, y) => x.correctRate.compareTo(y.correctRate));
  }

  List<ErrorPattern> _aggregatePatterns(
      List<Assessment> assessments, List<AssessmentSubmission> subs) {
    final analyzer = ErrorPatternAnalyzer();
    final counts = <String, int>{};
    for (final sub in subs) {
      final a = assessments.where((x) => x.id == sub.assessmentId).firstOrNull;
      if (a == null) continue;
      for (final p in analyzer.analyze(questions: a.questions, sub: sub)) {
        counts[p.label] = (counts[p.label] ?? 0) + p.count;
      }
    }
    return [
      for (final e in counts.entries)
        ErrorPattern(label: e.key, count: e.value, detail: ''),
    ]..sort((x, y) => y.count.compareTo(x.count));
  }

  void _select(String? id) {
    setState(() {
      _studentId = id;
      _profile = _loadProfile(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(
        title: 'Student Learning Profile',
      ),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final students = snap.data?.$1 ?? const <Student>[];
          if (widget.studentId == null) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: DropdownButtonFormField<String>(
                    initialValue: _studentId,
                    // "name · class" is dynamic — expanded + ellipsis keeps
                    // it sharing the row with the arrow (no right overflow).
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Student'),
                    items: [
                      for (final s in students)
                        DropdownMenuItem(
                          value: s.id,
                          child: Text(
                            '${s.fullName} · ${s.classId}',
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                    ],
                    onChanged: (v) => _select(v),
                  ),
                ),
                Expanded(
                  child: _studentId == null
                      ? const Center(child: Text('Select a student'))
                      : _ProfileView(profileFuture: _profile),
                ),
              ],
            );
          }
          return _ProfileView(profileFuture: _profile);
        },
      ),
    );
  }
}

class _ProfileView extends StatelessWidget {
  const _ProfileView({required this.profileFuture});

  final Future<StudentLearningProfile> profileFuture;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<StudentLearningProfile>(
      future: profileFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final profile = snap.data;
        if (profile == null) {
          return const Center(child: Text('No profile data'));
        }
        final weak = profile.topics.take(5).toList();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${profile.student.fullName} — learning profile',
                        style: const TextStyle(
                            fontSize: 17, fontWeight: .w800)),
                    const SizedBox(height: 8),
                    Text(
                        '${profile.topics.length} topics assessed · '
                        '${profile.interventions.length} intervention(s) · '
                        '${profile.errorPatterns.length} recurring error pattern(s)'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (profile.topics.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                    child: Text('No submitted answers yet — profile builds '
                        'after the first completed assessment')),
              ),
            for (final (i, t) in profile.topics.take(8).indexed)
              SvEntrance(
                delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
                child: SvPressScale(
                  child: Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  dense: true,
                  title: Text(t.topic),
                  subtitle: Text('${t.subjectId} · ${t.attempts} attempt(s)'),
                  trailing: _MasteryRing(correctRate: t.correctRate),
                ),
              ),
              ),
            ),
            if (profile.errorPatterns.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Recurring error patterns',
                  style: TextStyle(fontSize: 16, fontWeight: .w700)),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    for (final (i, p) in profile.errorPatterns.take(6).indexed)
                      SvEntrance(
                        delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
                        child: SvPressScale(
                          child: ListTile(
                        dense: true,
                        leading: Icon(
                          p.count >= 3
                              ? Icons.error_outline
                              : Icons.info_outline,
                          color: p.count >= 3
                              ? AppColors.danger
                              : AppColors.warning,
                        ),
                        title: Text('${p.label} (${p.count}x)',
                            style: const TextStyle(fontWeight: .w600)),
                        subtitle: p.detail.isEmpty ? null : Text(p.detail),
                      ),
                    ),
                  ),
                  ],
                ),
              ),
            ],
            if (profile.interventions.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Active interventions',
                  style: TextStyle(fontSize: 16, fontWeight: .w700)),
              const SizedBox(height: 8),
              for (final (i, iv) in profile.interventions.take(4).indexed)
                SvEntrance(
                  delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
                  child: SvPressScale(
                    child: Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: Icon(
                      iv.status == InterventionStatus.completed
                          ? Icons.task_alt
                          : Icons.support_agent,
                      color: iv.status == InterventionStatus.completed
                          ? AppColors.success
                          : AppTheme.brand,
                    ),
                    title: Text('${iv.topic} · ${iv.status.label}'),
                    subtitle: Text(iv.action),
                    isThreeLine: true,
                  ),
                ),
              ),
            ),
            ],
            if (weak.isNotEmpty) ...[
              const SizedBox(height: 16),
              Card(
                color: AppTheme.brand.withValues(alpha: .06),
                child: ListTile(
                  leading: Icon(Icons.tips_and_updates,
                      color: AppColors.brand),
                  title: const Text('Next steps',
                      style: TextStyle(fontWeight: .w700)),
                  subtitle: Text(
                      'Weakest topic: "${weak.first.topic}". Add targeted '
                      'practice questions, assign an intervention, and '
                      'schedule a reassessment after support.'),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _MasteryRing extends StatelessWidget {
  const _MasteryRing({required this.correctRate});

  final double correctRate;

  @override
  Widget build(BuildContext context) {
    final pct = (correctRate * 100).round();
    final color = pct >= 75
        ? AppColors.success
        : pct >= 50
            ? AppColors.warning
            : AppColors.danger;
    return Stack(
      alignment: Alignment.center,
      children: [
        SizedBox(
          width: 42,
          height: 42,
          child: CircularProgressIndicator(
            value: correctRate,
            strokeWidth: 5,
            backgroundColor: color.withValues(alpha: .16),
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
        Text('$pct%',
            style: TextStyle(
                fontSize: 11, fontWeight: .w800, color: color)),
      ],
    );
  }
}

class _Agg {
  final String subjectId;
  final String topic;
  int attempts = 0;
  int correct = 0;

  _Agg(this.subjectId, this.topic);
}