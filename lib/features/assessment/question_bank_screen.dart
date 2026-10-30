import 'package:flutter/material.dart';

import '../../core/models/question.dart';
import '../../core/models/subjects.dart';
import '../../core/models/user.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import 'assessment_repository.dart';
import 'question_editor_screen.dart';
import 'rule_marking_engine.dart';

class QuestionBankScreen extends StatefulWidget {
  const QuestionBankScreen({super.key});

  @override
  State<QuestionBankScreen> createState() => _QuestionBankScreenState();
}

class _QuestionBankScreenState extends State<QuestionBankScreen> {
  late Future<(List<Question>, User?)> _data;
  String _subject = 'All';
  String _query = '';
  bool _canManage = false;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(List<Question>, User?)> _load() async {
    final user = await AuthRepository().currentUser();
    final bank = await AssessmentRepository().bank();
    // Creating/editing/deleting bank questions is teacher+ (doc §17); staff
    // members on this screen get a read-only reference view.
    _canManage = user?.role.canManageQuestionBank ?? false;
    return (bank, user);
  }

  Future<void> _reload() async {
    setState(() { _data = _load(); });
  }

  Future<void> _addQuestion() async {
    final q = await Navigator.of(context).push<Question>(MaterialPageRoute(
      builder: (_) => const QuestionEditorScreen(),
    ));
    if (q != null) {
      await AssessmentRepository().saveBankQuestion(q);
      await _reload();
    }
  }

  Future<void> _edit(Question q) async {
    final updated = await Navigator.of(context).push<Question>(MaterialPageRoute(
      builder: (_) => QuestionEditorScreen(initial: q),
    ));
    if (updated != null) {
      await AssessmentRepository().saveBankQuestion(updated);
      await _reload();
    }
  }

  Future<void> _delete(Question q) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete question?'),
        content: Text(q.stem),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AssessmentRepository().deleteBankQuestion(q.id);
      await _reload();
    }
  }

  List<Question> _filter(List<Question> all) {
    return all.where((q) {
      final subjOk = _subject == 'All' || q.subjectId == _subject;
      final needle = _query.trim().toLowerCase();
      final textOk = needle.isEmpty ||
          q.stem.toLowerCase().contains(needle) ||
          q.topic.toLowerCase().contains(needle);
      return subjOk && textOk;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Question Bank'),
      floatingActionButton: _canManage
          ? FloatingActionButton.extended(
              onPressed: _addQuestion,
              icon: const Icon(Icons.add),
              label: const Text('New question'),
            )
          : null,
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final all = snap.data?.$1 ?? const <Question>[];
          final questions = _filter(all);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Search by question or topic',
                    prefixIcon: const Icon(Icons.search),
                  ),
                ),
              ),
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  children: [
                    for (final s in ['All', ...subjects.map((e) => e.id)])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(s == 'All'
                              ? 'All'
                              : subjectName(s)),
                          selected: _subject == s,
                          onSelected: (_) =>
                              setState(() => _subject = s),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('${questions.length} question(s)',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.muted)),
                ),
              ),
              Expanded(
                child: questions.isEmpty
                    ? const Center(child: Text('No questions found'))
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: questions.length,
                        itemBuilder: (context, i) {
                          final q = questions[i];
                          final rule = q.correctAnswer.isNotEmpty &&
                                  !q.isObjective
                              ? RuleMarkingEngine().suggest(q, q.correctAnswer)
                              : null;
                          return SvEntrance(
                            delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
                            child: SvPressScale(
                              child: Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            child: InkWell(
                              onTap: _canManage ? () => _edit(q) : null,
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          width: 28,
                                          height: 28,
                                          decoration: BoxDecoration(
                                            gradient: const LinearGradient(
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                              colors: [
                                                AppTheme.brand,
                                                AppTheme.brandLight
                                              ],
                                            ),
                                            borderRadius:
                                                BorderRadius.circular(9),
                                          ),
                                          alignment: Alignment.center,
                                          child: Text('${i + 1}',
                                              style: const TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: .w700,
                                                  color: Colors.white)),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(q.stem,
                                                  style: const TextStyle(
                                                      fontWeight: .w600)),
                                              const SizedBox(height: 4),
                                              Text(
                                                '${subjectName(q.subjectId)} · ${q.classId} · ${q.topic}'
                                                ' · ${q.type.label} · ${q.marks.toStringAsFixed(0)}m'
                                                ' · ${_difficulty(q.difficulty)}',
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    color: AppColors.muted),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (_canManage)
                                          PopupMenuButton<String>(
                                            onSelected: (v) => switch (v) {
                                              'edit' => _edit(q),
                                              'delete' => _delete(q),
                                              _ => null,
                                            },
                                            itemBuilder: (_) => const [
                                              PopupMenuItem(
                                                  value: 'edit',
                                                  child: Text('Edit')),
                                              PopupMenuItem(
                                                  value: 'delete',
                                                  child: Text('Delete')),
                                            ],
                                          ),
                                      ],
                                    ),
                                    if (q.markingScheme.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 6,
                                        children: [
                                          for (final k in RuleMarkingEngine()
                                              .keywords(q.markingScheme))
                                            _token(k),
                                        ],
                                      ),
                                    ] else if (rule != null && rule.confident) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        'Rule engine: "${rule.note}"',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color:
                                                AppColors.muted),
                                      ), 
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
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

  Widget _token(String k) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppTheme.accent.withValues(alpha: .1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(k,
            style: TextStyle(
                fontSize: 11,
                color: AppTheme.accent,
                fontWeight: FontWeight.w600)),
      );

  String _difficulty(int d) => switch (d) {
        1 => 'Easy',
        2 => 'Medium',
        _ => 'Hard',
      };
}