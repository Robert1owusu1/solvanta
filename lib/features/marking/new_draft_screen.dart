import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/marking_scheme.dart';
import '../../core/models/ocr_job.dart';
import '../../core/models/student.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../assessment/assessment_repository.dart';
import '../assignments/assignment_submissions_repository.dart';
import '../assignments/assignments_repository.dart';
import '../ocr/ocr_repository.dart';
import '../students/students_repository.dart';
import 'draft_review_screen.dart';
import 'marking_drafts_repository.dart';

/// A scheme the teacher can mark against: the latest version for one
/// assessment or assignment, with that target's name and class.
class _Target {
  const _Target(this.scheme, this.title, this.classId, this.isAssignment);
  final MarkingScheme scheme;
  final String title;
  final String classId;
  final bool isAssignment;
}

/// Asks the matching engine for a draft of one student's paper (Phase 5/6),
/// from readings the teacher has confirmed or from answers typed in. The
/// draft then opens for review; nothing is recorded until it is finalized.
class NewDraftScreen extends StatefulWidget {
  const NewDraftScreen({super.key});

  @override
  State<NewDraftScreen> createState() => _NewDraftScreenState();
}

class _NewDraftScreenState extends State<NewDraftScreen> {
  late Future<(List<_Target>, List<Student>, List<OcrJob>)> _data;
  _Target? _target;
  MarkingScheme? _full; // the chosen scheme with its questions
  Student? _student;
  bool _typed = false;
  final Set<String> _readings = {};
  final Map<int, TextEditingController> _typedAnswers = {};
  bool _working = false;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  @override
  void dispose() {
    for (final c in _typedAnswers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<(List<_Target>, List<Student>, List<OcrJob>)> _load() async {
    final raw = await ApiClient().get('/api/marking-schemes');
    final schemes = (raw as List)
        .map((e) => MarkingScheme.fromJson(e as Map<String, dynamic>))
        .toList();
    // Only the latest version of each scheme is markable.
    final latest = <String, MarkingScheme>{};
    for (final s in schemes) {
      final key = s.assessmentId ?? 'A:${s.assignmentId}';
      if ((latest[key]?.version ?? 0) < s.version) latest[key] = s;
    }
    final assessments = {for (final a in await AssessmentRepository().assessments()) a.id: a};
    final assignments = {for (final a in await AssignmentsRepository().all()) a.id: a};
    final targets = <_Target>[];
    for (final s in latest.values) {
      final assessment = assessments[s.assessmentId];
      final assignment = assignments[s.assignmentId];
      if (assessment != null) {
        targets.add(_Target(s, assessment.title, assessment.classId, false));
      } else if (assignment != null) {
        targets.add(_Target(s, assignment.title, assignment.classId, true));
      }
    }
    targets.sort((a, b) => a.title.compareTo(b.title));
    final students = await StudentsRepository().all();
    final confirmed = (await OcrRepository().all()).where((j) => j.isConfirmed).toList();
    return (targets, students, confirmed);
  }

  Future<void> _pickTarget(_Target? t) async {
    setState(() {
      _target = t;
      _full = null;
      _student = null;
      _message = '';
    });
    if (t == null) return;
    try {
      final raw = await ApiClient().get('/api/marking-schemes/${t.scheme.id}');
      final full = MarkingScheme.fromJson(raw as Map<String, dynamic>);
      if (!mounted) return;
      setState(() {
        _full = full;
        for (final c in _typedAnswers.values) {
          c.dispose();
        }
        _typedAnswers
          ..clear()
          ..addAll({for (final q in full.questions) q.questionNumber: TextEditingController()});
      });
    } catch (_) {
      if (mounted) setState(() => _message = "Couldn't load that scheme's questions.");
    }
  }

  Future<void> _submit() async {
    final t = _target!, student = _student!;
    setState(() {
      _working = true;
      _message = '';
    });
    try {
      var submissionId = '';
      if (t.isAssignment) {
        final sub = await AssignmentSubmissionsRepository().openFor(t.scheme.assignmentId!, student.id);
        if (sub == null) {
          setState(() => _message = 'No work has been captured for ${student.fullName} on this assignment yet.');
          return;
        }
        submissionId = sub.id;
      }
      final repo = MarkingDraftsRepository();
      final req = await repo.request(
        schemeId: t.scheme.id,
        submissionId: submissionId,
        studentId: student.id,
        ocrJobIds: _typed ? const [] : _readings.toList(),
        answers: _typed
            ? [
                for (final e in _typedAnswers.entries)
                  if (e.value.text.trim().isNotEmpty) {'questionNumber': e.key, 'text': e.value.text.trim()},
              ]
            : const [],
      );
      final waiting = (await repo.pending()).where((r) => r.id == req.id).firstOrNull;
      if (waiting != null) {
        setState(() => _message = waiting.failed
            ? 'Not drafted: ${waiting.error}'
            : 'Saved on this device. It will be drafted when the server can be reached.');
        if (waiting.failed) await repo.dismiss(waiting.id);
        return;
      }
      // Answered: open the new draft for review.
      final queue = await repo.reviewQueue();
      final draft = queue
          .where((d) => d.studentId == student.id && d.schemeId == t.scheme.id)
          .lastOrNull;
      if (!mounted) return;
      if (draft == null) {
        setState(() => _message = 'Drafted. Open AI Marking Review to see it.');
        return;
      }
      await Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => DraftReviewScreen(draftId: draft.id, studentName: student.fullName),
      ));
    } on ArgumentError catch (e) {
      setState(() => _message = e.message.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  bool get _ready =>
      _target != null &&
      _full != null &&
      _student != null &&
      (_typed
          ? _typedAnswers.values.any((c) => c.text.trim().isNotEmpty)
          : _readings.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Draft marks')),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SvLoading(message: 'Loading marking schemes…');
          }
          if (snap.hasError) {
            return SvErrorState(
              message: 'Drafting needs the server, to read the marking schemes. Check the connection.',
              onRetry: () => setState(() => _data = _load()),
            );
          }
          final (targets, students, readings) = snap.data!;
          if (targets.isEmpty) {
            return const SvEmptyState(
              icon: Icons.rule,
              title: 'No marking schemes yet',
              message: 'Write a marking scheme for an assessment or assignment first.',
            );
          }
          final classStudents = _target == null
              ? <Student>[]
              : (students.where((s) => s.classId == _target!.classId).toList()
                ..sort((a, b) => a.fullName.compareTo(b.fullName)));
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              DropdownButtonFormField<_Target>(
                isExpanded: true,
                initialValue: _target,
                decoration: const InputDecoration(labelText: 'Marking scheme', border: OutlineInputBorder()),
                items: [
                  for (final t in targets)
                    DropdownMenuItem(
                      value: t,
                      child: Text('${t.title} (${t.isAssignment ? 'assignment' : 'assessment'}, v${t.scheme.version})',
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _working ? null : _pickTarget,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<Student>(
                isExpanded: true,
                initialValue: _student,
                decoration: const InputDecoration(labelText: 'Student', border: OutlineInputBorder()),
                items: [
                  for (final s in classStudents)
                    DropdownMenuItem(value: s, child: Text(s.fullName, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: _working || _target == null ? null : (s) => setState(() => _student = s),
              ),
              const SizedBox(height: 16),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, icon: Icon(Icons.document_scanner), label: Text('Readings')),
                  ButtonSegment(value: true, icon: Icon(Icons.keyboard), label: Text('Type answers')),
                ],
                selected: {_typed},
                onSelectionChanged: (v) => setState(() => _typed = v.first),
              ),
              const SizedBox(height: 12),
              if (!_typed) ..._readingChoices(readings) else ..._typedFields(),
              const SizedBox(height: 16),
              if (_message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(_message, style: TextStyle(color: AppColors.warning, fontWeight: FontWeight.w600)),
                ),
              FilledButton.icon(
                onPressed: _ready && !_working ? _submit : null,
                icon: const Icon(Icons.auto_fix_high),
                label: Text(_working ? 'Drafting…' : 'Draft marks'),
              ),
              const SizedBox(height: 8),
              Text(
                'A draft is a proposal. You review every mark and finalize it yourself; nothing is recorded before then.',
                style: TextStyle(fontSize: 12, color: AppColors.muted),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _readingChoices(List<OcrJob> readings) {
    if (readings.isEmpty) {
      return [
        Text(
          'No confirmed readings on this device. Photograph and confirm pages in OCR Review, or type the answers instead.',
          style: TextStyle(color: AppColors.muted),
        ),
      ];
    }
    return [
      Text('Pick the confirmed pages of this paper, in order', style: TextStyle(fontSize: 12, color: AppColors.muted)),
      for (final j in readings)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _readings.contains(j.id),
          title: Text(j.topic, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            j.effectiveText.split('\n').where((l) => l.trim().isNotEmpty).take(2).join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onChanged: (v) => setState(() => v == true ? _readings.add(j.id) : _readings.remove(j.id)),
        ),
    ];
  }

  List<Widget> _typedFields() {
    if (_full == null) {
      return [Text('Choose a marking scheme to see its questions.', style: TextStyle(color: AppColors.muted))];
    }
    return [
      for (final q in _full!.questions)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: _typedAnswers[q.questionNumber],
            decoration: InputDecoration(
              labelText: 'Question ${q.questionNumber} answer',
              suffixText: '/ ${q.totalMarks % 1 == 0 ? q.totalMarks.toStringAsFixed(0) : q.totalMarks}',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
    ];
  }
}
