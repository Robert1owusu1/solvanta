import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/scan_page.dart';
import '../../core/models/question.dart';
import '../../core/models/student.dart';
import '../../core/models/submission.dart';
import '../../core/models/subjects.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../students/students_repository.dart';
import 'assessment_repository.dart';
import 'scan_capture_screen.dart';
import 'scans_repository.dart';

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, required this.assessment});

  final Assessment assessment;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  late Future<(List<Student>, List<AssessmentSubmission>, List<ScanPage>)>
      _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(List<Student>, List<AssessmentSubmission>, List<ScanPage>)>
      _load() async {
    final students =
        await StudentsRepository().byClass(widget.assessment.classId);
    final subs = await AssessmentRepository().submissions();
    final scans = await ScansRepository().forAssessment(widget.assessment.id);
    return (students, subs, scans);
  }

  /// Shows the photo behind [scan], fetched from the server so a page
  /// captured on another staff device can be checked here too.
  Future<void> _viewScan(ScanPage scan) async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Page ${scan.pageNumber} · ${scan.status.label}'),
        content: FutureBuilder(
          future: ScansRepository().image(scan),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(
                  height: 120, child: Center(child: CircularProgressIndicator()));
            }
            final bytes = snap.data;
            if (bytes == null) {
              return const Text('The photo is not available on this device '
                  'and has not reached the server yet.');
            }
            return InteractiveViewer(child: Image.memory(bytes));
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.assessment;
    return Scaffold(
      appBar: AppBar(title: const Text('Capture answer sheets')),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SvLoading();
          }
          if (snap.hasError) {
            return SvErrorState(
              message: 'Could not load the class roster',
              onRetry: () => setState(() => _data = _load()),
            );
          }
          final (students, subs, scans) = snap.data ??
    (<Student>[], <AssessmentSubmission>[], <ScanPage>[]);
          return Column(
            crossAxisAlignment: .stretch,
            children: [
              Card(
                margin: const EdgeInsets.all(16),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: .start,
                    children: [
                      Text(a.title,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: .w700)),
                      const SizedBox(height: 4),
                      Text(
                          '${a.type.label} · ${subjectName(a.subjectId)} · ${a.classId} · ${a.totalMarks.toStringAsFixed(0)} marks',
                          style: TextStyle(color: AppColors.body)),
                      const SizedBox(height: 8),
                      Text(
                        'Students answer on paper — you transcribe &\nconfirm marks. Objective questions mark automatically.',
                        style: TextStyle(fontSize: 12, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
              ),
              if (students.isEmpty)
                Expanded(
                  child: SvEmptyState(
                    icon: Icons.group_outlined,
                    title: 'No students in this class',
                    message:
                        'Add students to ${a.classId} before capturing answer sheets.',
                  ),
                )
              else
                Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: students.length,
                  itemBuilder: (context, i) {
                    final s = students[i];
                    final submitted =
                        subs.any((x) => x.studentId == s.id &&
                            x.assessmentId == a.id);
                    final scan = scans
                        .where((x) => x.studentId == s.id)
                        .toList();
                    final scanStatus = scan.isEmpty
                        ? null
                        : 'Scan attached · ${scan.first.status.label}'
                            '${scan.length > 1 ? ' (+${scan.length - 1})' : ''}';
                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              AppTheme.brand.withValues(alpha: .12),
                          child: Text(s.initials,
                              style: TextStyle(
                                  fontWeight: .w700,
                                  color: AppColors.brand,
                                  fontSize: 12)),
                        ),
                        title: Text(s.fullName,
                            style: const TextStyle(fontWeight: .w600)),
                        subtitle: Text([
                          if (submitted) 'Submitted — marked',
                          if (!submitted) 'Not yet captured',
                          ?scanStatus,
                        ].join(' · ')),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (scan.isNotEmpty)
                              IconButton(
                                tooltip: 'View scanned page',
                                icon: const Icon(Icons.image_outlined),
                                onPressed: () => _viewScan(scan.first),
                              ),
                            IconButton(
                              tooltip: 'Scan answer sheet',
                              icon: const Icon(Icons.photo_camera_outlined),
                              color: AppColors.brand,
                              onPressed: () async {
                                await Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => ScanCaptureScreen(
                                        assessment: a, student: s),
                                  ),
                                );
                                if (mounted) setState(() => _data = _load());
                              },
                            ),
                            submitted
                                ? Icon(Icons.check_circle,
                                    color: AppColors.success)
                                : const Icon(Icons.chevron_right),
                          ],
                        ),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  AnswerEntryScreen(assessment: a, student: s),
                            ),
                          );
                          setState(() => _data = _load());
                        },
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
}

class AnswerEntryScreen extends StatefulWidget {
  const AnswerEntryScreen(
      {super.key, required this.assessment, required this.student});

  final Assessment assessment;
  final Student student;

  @override
  State<AnswerEntryScreen> createState() => _AnswerEntryScreenState();
}

class _AnswerEntryScreenState extends State<AnswerEntryScreen> {
  final Map<String, String> _answers = {};
  final Map<String, double> _teacherMarks = {};
  bool _saving = false;

  double get _potentialEarned =>
      computeEarned(widget.assessment.questions, _answers, _teacherMarks);

  Future<void> _submit() async {
    setState(() => _saving = true);
    try {
      await AssessmentRepository().submit(
        assessment: widget.assessment,
        studentId: widget.student.id,
        answers: _answers,
        teacherMarks: _teacherMarks,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      svSnack(context, 'Could not save answers. Please try again.',
          error: true);
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            '${widget.student.fullName}: ${_potentialEarned.toStringAsFixed(1)} / ${widget.assessment.totalMarks.toStringAsFixed(1)} marks'),
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.assessment;
    return Scaffold(
      appBar: AppBar(title: Text(widget.student.fullName)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: AppTheme.brand.withValues(alpha: .08),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: .start,
                children: [
                  Text(a.title,
                      style:
                          const TextStyle(fontWeight: .w700, fontSize: 15)),
                  const SizedBox(height: 4),
                  Text('Objective questions are auto-marked. '
                      'Enter marks for written answers.',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.body)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final q in a.questions)
            _questionCard(q),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _submit,
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16)),
            child: _saving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text('Save & mark — ${_potentialEarned.toStringAsFixed(1)} / '
                    '${a.totalMarks.toStringAsFixed(1)}'),
          ),
        ],
      ),
    );
  }

  Widget _questionCard(Question q) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: .start,
          children: [
            Text('${q.marks.toStringAsFixed(0)} marks · ${q.type.label}',
                style: TextStyle(fontSize: 12, color: AppColors.muted)),
            const SizedBox(height: 6),
            Text(q.stem, style: const TextStyle(fontWeight: .w600)),
            const SizedBox(height: 10),
            if (q.type == QuestionType.mcq)
              RadioGroup<String>(
                groupValue: _answers[q.id],
                onChanged: (v) => setState(() {
                  if (v != null) _answers[q.id] = v;
                }),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final option in q.options)
                      RadioListTile<String>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(option),
                        value: option,
                      ),
                  ],
                ),
              )
            else if (q.type == QuestionType.trueFalse)
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'True', label: Text('True')),
                  ButtonSegment(value: 'False', label: Text('False')),
                ],
                selected: {_answers[q.id] ?? 'True'},
                onSelectionChanged: (s) =>
                    setState(() => _answers[q.id] = s.first),
              )
            else ...[
              TextField(
                decoration: const InputDecoration(
                    labelText: 'Student answer (scan result / transcription)'),
                onChanged: (v) => _answers[q.id] = v.trim(),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Teacher mark',
                      style: TextStyle(color: AppColors.body),
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: InputDecoration(
                        isDense: true,
                        suffixText: '/ ${q.marks.toStringAsFixed(0)}',
                      ),
                      onChanged: (v) => setState(() {
                        final val = double.tryParse(v);
                        _teacherMarks[q.id] =
                            (val ?? 0).clamp(0, q.marks).toDouble();
                      }),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}