import 'package:flutter/material.dart';

import '../../core/models/role.dart';
import '../../core/models/safety_training.dart';
import '../../core/models/user.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import 'safety_training_repository.dart';

class SafetyTrainingScreen extends StatefulWidget {
  const SafetyTrainingScreen({super.key});

  @override
  State<SafetyTrainingScreen> createState() => _SafetyTrainingScreenState();
}

class _SafetyTrainingScreenState extends State<SafetyTrainingScreen> {
  late Future<(List<SafetyPack>, List<TrainingCompletion>, User?)> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(List<SafetyPack>, List<TrainingCompletion>, User?)> _load() async {
    final user = await AuthRepository().currentUser();
    final repo = SafetyTrainingRepository();
    final packs = await repo.all();
    final completions = await repo.completionsFor(studentIdFor(user));
    return (packs, completions, user);
  }

  String studentIdFor(User? user) {
    if (user == null) return '';
    if (user.role.isStudent) return user.id.replaceFirst('USR-', '');
    if (user.studentIds.isNotEmpty) return user.studentIds.first;
    return '';
  }

  String audienceFor(User? user) {
    if (user == null) return 'STUDENT';
    switch (user.role) {
      case AppRole.student:
        return 'STUDENT';
      case AppRole.parent:
        return 'PARENT';
      case AppRole.teacher:
      case AppRole.headteacher:
      case AppRole.schoolAdmin:
      case AppRole.superAdmin:
        return 'TEACHER';
      default:
        return 'STAFF';
    }
  }

  Future<void> _launchPack(SafetyPack pack) async {
    final completed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => _PackRunner(pack: pack),
    ));
    if (completed == true) setState(() => _data = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Safety Training Packs'),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final user = snap.data?.$3;
          final packs = snap.data?.$1 ?? const <SafetyPack>[];
          final completions = snap.data?.$2 ?? const <TrainingCompletion>[];
          final audience = audienceFor(user);
          final mine =
              packs.where((p) => p.audience == audience).toList();
          final completedIds = completions.map((c) => c.packId).toSet();

          if (packs.isEmpty) {
            return const Center(child: Text('No training packs available'));
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Packs for ${kSafetyAudienceLabels[audience] ?? audience}',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.muted)),
              const SizedBox(height: 8),
              for (final p in mine)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          AppTheme.brand.withValues(alpha: .12),
                      child: completedIds.contains(p.id)
                          ? Icon(Icons.check_circle,
                              color: AppColors.brand)
                          : Text('${p.lessons.length}',
                              style: TextStyle(
                                  color: AppColors.brand,
                                  fontWeight: .w700)),
                    ),
                    title: Text(p.title,
                        style: const TextStyle(fontWeight: .w600)),
                    subtitle: Text(
                        '${p.topic}\n${p.lessons.length} lesson(s) · '
                        '${p.quizQuestions.length} question quiz'),
                    isThreeLine: true,
                    onTap: () => _launchPack(p),
                  ),
                ),
              if (mine.isEmpty)
                const Center(
                    child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                      'No packs for this audience yet. Switch account to view others.'),
                )),
            ],
          );
        },
      ),
    );
  }
}

class _PackRunner extends StatefulWidget {
  const _PackRunner({required this.pack});

  final SafetyPack pack;

  @override
  State<_PackRunner> createState() => _PackRunnerState();
}

class _PackRunnerState extends State<_PackRunner> {
  int _step = 0;
  bool _readDone = false;
  final List<bool?> _answers = [];

  void _next() {
    if (!_readDone) {
      if (_step < widget.pack.lessons.length) {
        setState(() => _step++);
        return;
      }
      setState(() {
        _readDone = true;
        _step = 0;
        _answers.addAll(
            List<bool?>.filled(widget.pack.quizQuestions.length, null));
      });
      return;
    }
    setState(() => _step++);
  }

  Future<void> _finish() async {
    var score = 0;
    final total = widget.pack.quizQuestions.length;
    for (var i = 0; i < total; i++) {
      final correct = widget.pack.quizAnswers[i] == 'true';
      if (_answers[i] == correct) score++;
    }
    final user = await AuthRepository().currentUser();
    final sid = user?.role.isStudent == true
        ? user!.id.replaceFirst('USR-', '')
        : (user?.studentIds.isNotEmpty == true ? user!.studentIds.first : '');
    await SafetyTrainingRepository().recordCompletion(
      packId: widget.pack.id,
      studentId: sid,
      score: score,
      total: total,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Training complete — $score/$total'),
      backgroundColor: score == total ? AppColors.success : null,
    ));
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final pack = widget.pack;
    final isQuiz = _readDone;
    final maxStep = isQuiz ? pack.quizQuestions.length : pack.lessons.length;
    final done = _step >= maxStep;

    return Scaffold(
      appBar: AppBar(title: Text(pack.title)),
      body: isQuiz
          ? _quizView(pack, done)
          : _lessonView(pack, done),
    );
  }

  Widget _lessonView(SafetyPack pack, bool done) {
    if (done) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book, size: 56, color: AppColors.brand),
              const SizedBox(height: 16),
              const Text('Lessons read — ready for the quiz',
                  style: TextStyle(fontSize: 17, fontWeight: .w700)),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _next,
                child: const Text('Start quiz'),
              ),
            ],
          ),
        ),
      );
    }
    final lesson = pack.lessons[_step];
    return Column(
      children: [
        LinearProgressIndicator(
            value: (_step + 1) / pack.lessons.length,
            color: AppColors.brand),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Lesson ${_step + 1} of ${pack.lessons.length}',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: .w700,
                        color: AppColors.muted)),
                const SizedBox(height: 8),
                Text(pack.topic,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: .w800)),
                const Divider(height: 24),
                Text(lesson, style: const TextStyle(fontSize: 16, height: 1.5)),
              ],
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _next,
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16)),
                child: Text(_step == pack.lessons.length - 1
                    ? 'Finish lessons'
                    : 'Next lesson'),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _quizView(SafetyPack pack, bool done) {
    if (done) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.task_alt, size: 56, color: AppColors.brand),
              const SizedBox(height: 16),
              const Text('Quiz complete',
                  style: TextStyle(fontSize: 17, fontWeight: .w700)),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _finish,
                child: const Text('Submit training'),
              ),
            ],
          ),
        ),
      );
    }
    final q = pack.quizQuestions[_step];
    final answer = _answers[_step];
    return Column(
      children: [
        LinearProgressIndicator(
            value: (_step + 1) / pack.quizQuestions.length,
            color: AppColors.brand),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Question ${_step + 1} of ${pack.quizQuestions.length}',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: .w700,
                        color: AppColors.muted)),
                const SizedBox(height: 8),
                Text(q, style: const TextStyle(fontSize: 16, height: 1.4)),
                const SizedBox(height: 24),
                RadioGroup<bool>(
                  onChanged: (v) => setState(() => _answers[_step] = v),
                  groupValue: answer,
                  child: Column(
                    children: [
                      RadioListTile<bool>(
                        value: true,
                        title: const Text('True'),
                        subtitle:
                            const Text('Statement is correct or safe'),
                      ),
                      RadioListTile<bool>(
                        value: false,
                        title: const Text('False'),
                        subtitle:
                            const Text('Statement is wrong or unsafe'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: answer == null
                    ? null
                    : _next,
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16)),
                child: Text(_step == pack.quizQuestions.length - 1
                    ? 'Finish quiz'
                    : 'Next question'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}