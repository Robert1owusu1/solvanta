import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/question.dart';
import '../../core/models/student.dart';
import '../../core/models/subjects.dart';
import '../../core/models/submission.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../assessment/assessment_repository.dart';
import '../auth/auth_repository.dart';
import '../prep/mock_take_screen.dart';
import '../students/students_repository.dart';

class StudyHubScreen extends StatefulWidget {
  const StudyHubScreen({super.key});

  @override
  State<StudyHubScreen> createState() => _StudyHubScreenState();
}

class _StudyHubScreenState extends State<StudyHubScreen> {
  late Future<HubData> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<HubData> _load() async {
    final user = await AuthRepository().currentUser();
    final studentId = user?.role.isStudent == true
        ? user!.id.replaceFirst('USR-', '')
        : (user?.studentIds.isNotEmpty == true ? user!.studentIds.first : '');
    final student = await StudentsRepository().byId(studentId);
    final bank = await AssessmentRepository().bank();
    final assessments = await AssessmentRepository().assessments();
    final subs = await AssessmentRepository().submissions();
    return HubData(
      student: student,
      bank: bank,
      assessments: assessments,
      subs: subs,
    );
  }

  String _today() {
    final d = DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Assessment _synth({
    required String title,
    required AssessmentType type,
    required List<Question> questions,
    required String subjectId,
    required String classId,
  }) =>
      Assessment(
        id: 'PRAC-${DateTime.now().millisecondsSinceEpoch}',
        title: title,
        type: type,
        subjectId: subjectId,
        classId: classId,
        date: _today(),
        createdBy: 'Study Hub',
        questions: questions,
      );

  Future<void> _practice(List<Question> bank, Student student,
      {String? topic, String? subjectId}) async {
    final picked = AssessmentRepository().blueprintPick(
      from: bank,
      subjectId: subjectId,
      topic: topic,
      count: 5,
    );
    if (picked.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No questions in the bank for that topic yet')));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MockTakeScreen(
        assessment: _synth(
          title: topic == null
              ? 'Practice — ${subjectName(subjectId!)}'
              : 'Practice — $topic',
          type: AssessmentType.exercise,
          questions: picked,
          subjectId: subjectId ?? picked.first.subjectId,
          classId: student.classId,
        ),
        studentId: student.id,
      ),
    ));
    if (mounted) setState(() => _data = _load());
  }

  Future<void> _quiz(List<Question> bank, Student student, String subjectId) async {
    final picked = AssessmentRepository().blueprintPick(
      from: bank, subjectId: subjectId, count: 10);
    if (picked.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No quiz questions for that subject yet')));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MockTakeScreen(
        assessment: _synth(
          title: 'Quiz — ${subjectName(subjectId)}',
          type: AssessmentType.quiz,
          questions: picked,
          subjectId: subjectId,
          classId: student.classId,
        ),
        studentId: student.id,
      ),
    ));
    if (mounted) setState(() => _data = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Study Hub'),
      body: FutureBuilder<HubData>(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final d = snap.data;
          if (d == null || d.student == null) {
            return const Scaffold(
                body: Center(child: Text('No linked student account')));
          }
          return DefaultTabController(
            length: 4,
            child: Column(
              children: [
                const TabBar(
                  isScrollable: true,
                  tabs: [
                    Tab(text: 'Corrections'),
                    Tab(text: 'Practice'),
                    Tab(text: 'Quizzes'),
                    Tab(text: 'Vacation'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _corrections(d),
                      _practiceTab(d),
                      _quizzesTab(d),
                      _vacationTab(d),
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

  Widget _corrections(HubData d) {
    final wrong = d.wrongAnswers();
    if (wrong.isEmpty) {
      return const Center(
          child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
            'No corrections needed — great work!\n\n'
            'Wrong objective answers from your assessments appear here '
            'so you can re-learn the topic.',
            textAlign: TextAlign.center),
      ));
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Re-learn the topics behind every question you missed.',
            style: TextStyle(fontSize: 12, color: AppColors.muted)),
        const SizedBox(height: 8),
        for (final (i, c) in wrong.indexed)
          SvEntrance(
            delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
            child: SvPressScale(
              child: Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: AppTheme.brand.withValues(alpha: .12),
                child: const Icon(Icons.refresh, color: AppTheme.brand),
              ),
              title: Text(c.question.stem,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: .w600)),
              subtitle: Text(
                  '${subjectName(c.question.subjectId)} · ${c.question.topic}'
                  '\nYour answer: ${c.answer}'
                  '\nCorrect: ${c.question.correctAnswer}'
                  '${c.question.explanation.isNotEmpty ? '\n${c.question.explanation}' : ''}'),
              isThreeLine: true,
              trailing: FilledButton.tonalIcon(
                onPressed: () =>
                    _practice(d.bank, d.student!, topic: c.question.topic),
                icon: const Icon(Icons.replay, size: 16),
                label: const Text('Re-try'),
              ),
            ),
          ),
          ),
        ),
      ],
    );
  }

  Widget _practiceTab(HubData d) {
    final topics = d.topicsInBank();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Pick a weak topic and practise 5 bank questions on it.',
            style: TextStyle(fontSize: 12, color: AppColors.muted)),
        const SizedBox(height: 8),
        for (final (i, t) in topics.indexed)
          SvEntrance(
            delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
            child: SvPressScale(
              child: Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: AppTheme.accent.withValues(alpha: .14),
                child: Text(t.topic.substring(0, 1).toUpperCase()),
              ),
              title: Text('${t.topic} — ${subjectName(t.subjectId)}'),
              subtitle: Text('${t.count} question(s) in the bank'),
              trailing: const Icon(Icons.play_circle_fill,
                  color: AppTheme.accent),
              onTap: () => _practice(d.bank, d.student!,
                  topic: t.topic, subjectId: t.subjectId),
            ),
          ),
          ),
        ),
        if (topics.isEmpty)
          const Center(
              child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('The question bank is empty — ask a teacher to add '
                'questions.'),
          )),
      ],
    );
  }

  Widget _quizzesTab(HubData d) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('A 10-question timed quiz, auto-marked.',
            style: TextStyle(fontSize: 12, color: AppColors.muted)),
        const SizedBox(height: 8),
        for (final (i, s) in subjects.indexed)
          SvEntrance(
            delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
            child: SvPressScale(
              child: Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: AppTheme.brand.withValues(alpha: .12),
                child: const Icon(Icons.quiz_outlined,
                    color: AppTheme.brand),
              ),
              title: Text(s.name,
                  style: const TextStyle(fontWeight: .w600)),
              subtitle: Text(s.id),
              trailing: const Icon(Icons.play_circle_fill,
                  color: AppTheme.accent),
              onTap: () => _quiz(d.bank, d.student!, s.id),
            ),
          ),
          ),
        ),
      ],
    );
  }

  Widget _vacationTab(HubData d) {
    final packs = d
        .assessments
        .where((a) => a.type == AssessmentType.vacation)
        .toList();
    final weak = d.weakTopics();
    final progress = d.vacationProgress();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Vacation exercises published by your school, plus an '
            'auto-generated pack linked to your class. Carry your weak '
            'topics into the break (doc §44).',
            style: TextStyle(fontSize: 12, color: AppColors.muted)),
        const SizedBox(height: 8),
        Card(
          color: AppTheme.brand.withValues(alpha: .05),
          child: ListTile(
            leading: Icon(Icons.verified, color: AppTheme.brand),
            title: Text('Break progress',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: progress.total == 0
                      ? 0
                      : progress.done / progress.total,
                  backgroundColor: AppTheme.brand.withValues(alpha: .12),
                ),
                const SizedBox(height: 6),
                Text('${progress.done} of ${progress.total} vacation '
                    'packs ${progress.total == 0 ? 'planned — none published yet' : 'attempted'}'),
              ],
            ),
            isThreeLine: true,
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: AppTheme.accent.withValues(alpha: .14),
              child: const Icon(Icons.beach_access, color: AppTheme.accent),
            ),
            title: const Text('My vacation revision pack',
                style: TextStyle(fontWeight: .w600)),
            subtitle: Text(
                '10 auto-picked questions across ${d.bank.isNotEmpty ? 'the bank' : '— add questions first'}'),
            trailing: const Icon(Icons.play_circle_fill, color: AppTheme.accent),
            onTap: d.bank.isEmpty
                ? null
                : () => _vacationPack(d),
          ),
        ),
        for (final (i, a) in packs.indexed)
          SvEntrance(
            delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
            child: SvPressScale(
              child: Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: AppTheme.brand.withValues(alpha: .12),
                child: const Icon(Icons.assignment_outlined,
                    color: AppTheme.brand),
              ),
              title: Text(a.title,
                  style: const TextStyle(fontWeight: .w600)),
              subtitle: Text(
                  '${subjectName(a.subjectId)} · ${a.classId} · ${a.questions.length} questions'),
              trailing: const Icon(Icons.play_circle_fill,
                  color: AppTheme.accent),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => MockTakeScreen(
                      assessment: a, studentId: d.student!.id),
                ));
                if (mounted) setState(() => _data = _load());
              },
            ),
          ),
          ),
        ),
        if (packs.isEmpty)
          Padding(
            padding: EdgeInsets.all(12),
            child: Text('No published vacation packs yet.',
                style: TextStyle(color: AppColors.muted)),
          ),
        const SizedBox(height: 8),
        const Row(
          children: [
            Icon(Icons.auto_awesome, color: AppTheme.accent, size: 18),
            SizedBox(width: 6),
            Text('Carry your gaps into the break',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          ],
        ),
        const SizedBox(height: 6),
        if (weak.isEmpty)
          Card(
            child: ListTile(
              leading: Icon(Icons.check_circle, color: AppColors.success),
              title: Text('Nothing to carry yet'),
              subtitle: Text('Your topic accuracy is above 60% everywhere. '
                  'Keep the momentum going across the break.'),
            ),
          )
        else
          for (final t in weak)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.warningBg,
                  child: Icon(Icons.priority_high,
                      color: AppColors.warning),
                ),
                title: Text('${t.topic} — ${t.pct.toStringAsFixed(0)}% accurate',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${t.correct}/${t.total} correct on '
                    '${subjectName(t.subjectId)}'),
                trailing: FilledButton.tonalIcon(
                  onPressed: () => _practice(d.bank, d.student!,
                      topic: t.topic, subjectId: t.subjectId),
                  icon: const Icon(Icons.replay, size: 16),
                  label: const Text('Practise'),
                ),
              ),
            ),
      ],
    );
  }

  Future<void> _vacationPack(HubData d) async {
    final picked = AssessmentRepository().blueprintPick(
        from: d.bank, subjectId: null, count: 10);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MockTakeScreen(
        assessment: _synth(
          title: 'Vacation Revision Pack',
          type: AssessmentType.vacation,
          questions: picked,
          subjectId: picked.first.subjectId,
          classId: d.student!.classId,
        ),
        studentId: d.student!.id,
      ),
    ));
    if (mounted) setState(() => _data = _load());
  }
}

class CorrectionItem {
  final Assessment assessment;
  final Question question;
  final String answer;

  const CorrectionItem({
    required this.assessment,
    required this.question,
    required this.answer,
  });
}

class HubData {
  final Student? student;
  final List<Question> bank;
  final List<Assessment> assessments;
  final List<AssessmentSubmission> subs;

  const HubData({
    required this.student,
    required this.bank,
    required this.assessments,
    required this.subs,
  });

  List<CorrectionItem> wrongAnswers() {
    if (student == null) return const [];
    final out = <CorrectionItem>[];
    for (final sub in subs.where((s) => s.studentId == student!.id)) {
      final a =
          assessments.where((x) => x.id == sub.assessmentId).firstOrNull;
      if (a == null) continue;
      for (final q in a.questions) {
        if (!q.isObjective) continue;
        final answer = (sub.answers[q.id] ?? '').trim();
        if (answer.isNotEmpty &&
            answer.toLowerCase() != q.correctAnswer.trim().toLowerCase()) {
          out.add(CorrectionItem(
              assessment: a, question: q, answer: answer));
        }
      }
    }
    return out;
  }

  List<({String subjectId, String topic, int count})> topicsInBank() {
    final buckets = <String, ({String subjectId, int count})>{};
    for (final q in bank) {
      final key = '${q.subjectId}::${q.topic}';
      final existing = buckets[key];
      buckets[key] = (
        subjectId: q.subjectId,
        count: (existing?.count ?? 0) + 1,
      );
    }
    return [
      for (final e in buckets.entries)
        (
          subjectId: e.value.subjectId,
          topic: e.key.split('::').last,
          count: e.value.count,
        ),
    ]..sort((a, b) => a.topic.compareTo(b.topic));
  }

  /// Objective-question topic accuracy across this student's marked work.
  /// Topics under 60% are the gaps to carry into the break (doc §44).
  List<({String subjectId, String topic, int correct, int total, double pct})>
      weakTopics() {
    if (student == null) return const [];
    final counters = <String, List<int>>{};
    for (final a in assessments) {
      for (final q in a.questions.where((x) => x.isObjective)) {
        for (final s in subs.where((x) =>
            x.assessmentId == a.id && x.studentId == student!.id)) {
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
      if (pct >= 60) continue;
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

  /// (done, total) vacation packs for this student (doc §44).
  ({int done, int total}) vacationProgress() {
    final packs = assessments
        .where((a) => a.type == AssessmentType.vacation)
        .toList();
    final done = <String>{};
    for (final s in subs.where((x) => x.studentId == student?.id)) {
      if (packs.any((a) => a.id == s.assessmentId)) done.add(s.assessmentId);
    }
    return (done: done.length, total: packs.length);
  }
}