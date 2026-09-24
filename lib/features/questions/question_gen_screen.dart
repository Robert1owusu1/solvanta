import 'package:flutter/material.dart';

import '../../core/models/qgen_request.dart';
import '../../core/models/question.dart';
import '../../core/models/subjects.dart';
import '../../core/models/app_notification.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../assessment/assessment_repository.dart';
import '../auth/auth_repository.dart';
import '../notifications/notifications_repository.dart';
import 'question_gen_repository.dart';

/// AI question-generation request UI (doc §43): teachers request drafts on a
/// subject + topic; drafts are reviewed and approved into the question bank.
class QuestionGenScreen extends StatefulWidget {
  const QuestionGenScreen({super.key});

  @override
  State<QuestionGenScreen> createState() => _QuestionGenScreenState();
}

class _QuestionGenScreenState extends State<QuestionGenScreen> {
  late Future<List<QuestionGenRequest>> _data;
  String _reqSubject = 'MATH';
  QuestionType _reqType = QuestionType.mcq;
  int _reqCount = 5;
  String _reqPriority = 'Normal';
  final _topicCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _data = QuestionGenRepository().requests();
  }

  @override
  void dispose() {
    _topicCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() => _data = QuestionGenRepository().requests());
  }

  Future<void> _submitRequest() async {
    final topic = _topicCtrl.text.trim();
    if (topic.isEmpty) {
      svSnack(context, 'Enter a topic for the question set.', error: true);
      return;
    }
    final me = await AuthRepository().currentUser();
    if (me == null) return;
    final repo = QuestionGenRepository();
    await repo.create(QuestionGenRequest(
      id: 'QREQ-${DateTime.now().millisecondsSinceEpoch}',
      requesterId: me.id,
      requesterName: me.name,
      subjectId: _reqSubject,
      topic: topic,
      type: _reqType,
      count: _reqCount,
      priority: _reqPriority,
      classId: me.classId ?? '',
      createdAt: _now(),
    ));
    await NotificationsRepository().push(
      kind: NotificationKind.system,
      title: 'AI question request queued',
      body:
          '${me.name} requested $_reqCount ${_reqType.label} questions on "$topic".',
    );
    _topicCtrl.clear();
    _reload();
    if (mounted) {
      svSnack(context, 'Request sent to the AI question engine.');
    }
  }

  Future<void> _generate(QuestionGenRequest r) async {
    final repo = QuestionGenRepository();
    final drafts = repo.draftFor(
      subjectId: r.subjectId,
      topic: r.topic,
      type: r.type,
      count: r.count,
      classId: r.classId,
    );
    await repo.update(
        r.copyWith(drafts: drafts, status: QGenStatus.generated));
    await NotificationsRepository().push(
      kind: NotificationKind.system,
      title: 'AI drafts ready for review',
      body:
          '${r.count} draft question(s) on "${r.topic}" (${subjectName(r.subjectId)}) are ready to review.',
    );
    _reload();
  }

  Future<void> _review(QuestionGenRequest r) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Review drafts — ${r.topic}'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              Text('${r.count} draft question(s) · ${r.type.label}',
                  style: TextStyle(fontSize: 12, color: AppColors.muted)),
              const SizedBox(height: 8),
              for (final (i, q) in r.drafts.indexed)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${i + 1}. ${q.stem}',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        if (q.options.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              q.options.map((o) => o == q.correctAnswer ? '● $o' : '○ $o').join('  ·  '),
                              style: const TextStyle(fontSize: 12),
                            ),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('Answer: ${q.correctAnswer}',
                                style: const TextStyle(fontSize: 12)),
                          ),
                        if (q.markingScheme.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(q.markingScheme,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.muted)),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _reject(r);
            },
            child: const Text('Reject'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _publish(r);
            },
            child: const Text('Approve all'),
          ),
        ],
      ),
    );
  }

  Future<void> _publish(QuestionGenRequest r) async {
    final repo = QuestionGenRepository();
    final bank = await AssessmentRepository().bank();
    for (final q in r.drafts) {
      if (bank.any((e) => e.id == q.id)) continue;
      await AssessmentRepository().saveBankQuestion(q);
    }
    await repo.update(r.copyWith(
        status: QGenStatus.published,
        publishedAt: _now()));
    await NotificationsRepository().push(
      kind: NotificationKind.system,
      title: 'AI questions published to the bank',
      body:
          '${r.count} question(s) on "${r.topic}" are now live in the question bank.',
    );
    _reload();
    if (mounted) {
      svSnack(context,
          '${r.count} question(s) added to the bank.');
    }
  }

  Future<void> _reject(QuestionGenRequest r) async {
    await QuestionGenRepository()
        .update(r.copyWith(status: QGenStatus.rejected));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'AI Question Generator'),
      body: FutureBuilder<List<QuestionGenRequest>>(
        future: _data,
        builder: (context, snap) {
          final requests = snap.data ?? const <QuestionGenRequest>[];
          return DefaultTabController(
            length: 2,
            child: Column(
              children: [
                const TabBar(tabs: [
                  Tab(text: 'New request'),
                  Tab(text: 'Queue'),
                ]),
                Expanded(
                  child: TabBarView(
                    children: [_newRequest(requests.length), _queue(requests)],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _newRequest(int queued) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: AppTheme.brand.withValues(alpha: .05),
          child: ListTile(
            leading: const Icon(Icons.auto_awesome, color: AppTheme.brand),
            title: const Text('How it works',
                style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text(
                'Request draft questions on any topic. The AI engine produces '
                'drafts, you review them, then approve the best into the '
                'question bank. Nothing is published without your check.'),
            isThreeLine: true,
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _reqSubject,
          decoration: const InputDecoration(labelText: 'Subject'),
          items: [
            for (final s in subjects)
              DropdownMenuItem(value: s.id, child: Text(s.name)),
          ],
          onChanged: (v) => setState(() => _reqSubject = v ?? _reqSubject),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _topicCtrl,
          decoration: const InputDecoration(
            labelText: 'Topic',
            hintText: 'e.g. Fractions, Photosynthesis, Grammar…',
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<QuestionType>(
          initialValue: _reqType,
          decoration: const InputDecoration(labelText: 'Question type'),
          items: [
            for (final t in const [
              QuestionType.mcq,
              QuestionType.trueFalse,
              QuestionType.fillBlank,
              QuestionType.shortAnswer,
            ])
              DropdownMenuItem(value: t, child: Text(t.label)),
          ],
          onChanged: (v) => setState(() => _reqType = v ?? _reqType),
        ),
        const SizedBox(height: 12),
        Text('Number of questions',
            style: TextStyle(fontSize: 12, color: AppColors.muted)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            for (final n in const [5, 10, 20])
              ChoiceChip(
                label: Text('$n'),
                selected: _reqCount == n,
                onSelected: (_) => setState(() => _reqCount = n),
              ),
          ],
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _reqPriority,
          decoration: const InputDecoration(labelText: 'Priority'),
          items: [
            for (final p in const ['Low', 'Normal', 'High'])
              DropdownMenuItem(value: p, child: Text(p)),
          ],
          onChanged: (v) => setState(() => _reqPriority = v ?? _reqPriority),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _submitRequest,
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Send to AI question engine'),
        ),
        const SizedBox(height: 8),
        Text('$queued request(s) waiting in the queue.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppColors.muted)),
      ],
    );
  }

  Widget _queue(List<QuestionGenRequest> requests) {
    if (requests.isEmpty) {
      return const SvEmptyState(
        icon: Icons.inbox_outlined,
        title: 'No requests yet',
        message: 'Create a request on the "New request" tab — drafts appear '
            'here for review and approval.',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final r in requests)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('${subjectName(r.subjectId)} — ${r.topic}',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      _statusChip(r),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                      '${r.count} ${r.type.label} · priority ${r.priority} · '
                      'requested by ${r.requesterName} on ${r.createdAt}',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.muted)),
                  const SizedBox(height: 8),
                  if (r.status == QGenStatus.pending)
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonalIcon(
                        onPressed: () => _generate(r),
                        icon: const Icon(Icons.auto_awesome, size: 16),
                        label: const Text('Run AI generation'),
                      ),
                    ),
                  if (r.status == QGenStatus.generated)
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonalIcon(
                        onPressed: () => _review(r),
                        icon: const Icon(Icons.rate_review_outlined, size: 16),
                        label: Text('Review ${r.drafts.length} draft(s)'),
                      ),
                    ),
                  if (r.status == QGenStatus.published)
                    Text('Published to bank on ${r.publishedAt}',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.success)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _statusChip(QuestionGenRequest r) {
    final (bg, fg) = switch (r.status) {
      QGenStatus.pending => (AppColors.warningBg,
          AppColors.warning),
      QGenStatus.generated => (AppTheme.brand.withValues(alpha: .12),
          AppTheme.brand),
      QGenStatus.published => (AppColors.successBg,
          AppColors.success),
      QGenStatus.rejected => (AppColors.notAttempted.withValues(alpha: .15),
          AppColors.notAttempted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(12)),
      child: Text(r.status.label,
          style: TextStyle(
              color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }

  String _now() {
    final d = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }
}