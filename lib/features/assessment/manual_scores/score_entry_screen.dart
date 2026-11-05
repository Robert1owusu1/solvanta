import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/assessment.dart';
import '../../../core/models/student.dart';
import '../../../core/models/submission.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_kit.dart';
import '../../students/students_repository.dart';
import '../assessment_repository.dart';
import 'score_bulk_upload_screen.dart';

/// Single manual score entry: an assessment's class roster as a list, each row
/// with a score field, an absent toggle and a remark field. Saving is
/// offline-first through [AssessmentRepository.recordScore].
class ScoreEntryScreen extends StatefulWidget {
  const ScoreEntryScreen({super.key, required this.assessment});

  final Assessment assessment;

  @override
  State<ScoreEntryScreen> createState() => _ScoreEntryScreenState();
}

class _RowState {
  final TextEditingController score;
  final TextEditingController remark;
  bool absent;
  SubmissionSource source;
  _RowState(this.score, this.remark, this.absent, this.source);
}

class _ScoreEntryScreenState extends State<ScoreEntryScreen> {
  final _repo = AssessmentRepository();
  late Future<List<Student>> _future;
  final _rows = <String, _RowState>{};
  List<Student> _roster = const [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    for (final r in _rows.values) {
      r.score.dispose();
      r.remark.dispose();
    }
    super.dispose();
  }

  Future<List<Student>> _load() async {
    final roster = await StudentsRepository().byClass(widget.assessment.classId);
    _roster = roster;
    final subs = await _repo.submissions();
    for (final s in roster) {
      AssessmentSubmission? existing;
      for (final x in subs) {
        if (x.assessmentId == widget.assessment.id && x.studentId == s.id) {
          existing = x;
          break;
        }
      }
      _rows[s.id] = _RowState(
        TextEditingController(
            text: existing == null || existing.absent
                ? ''
                : _trim(existing.earned)),
        TextEditingController(text: existing?.remark ?? ''),
        existing?.absent ?? false,
        existing?.source ?? SubmissionSource.online,
      );
    }
    return roster;
  }

  String _trim(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  Future<void> _saveAll(List<Student> roster) async {
    final max = widget.assessment.effectiveTotal;
    // Validate first so nothing is written when a field is out of range.
    for (final s in roster) {
      final r = _rows[s.id]!;
      if (r.absent) continue;
      final text = r.score.text.trim();
      if (text.isEmpty) continue;
      final v = double.tryParse(text.replaceAll(',', '.'));
      if (v == null || v < 0 || v > max) {
        svSnack(context,
            '${s.fullName}: score must be a number between 0 and ${_trim(max)}.',
            error: true);
        return;
      }
    }

    // A row already marked by AI needs an explicit override confirmation.
    var overrideAll = false;
    final overridesNeeded = roster.where((s) {
      final r = _rows[s.id]!;
      final touched = r.absent || r.score.text.trim().isNotEmpty;
      return touched && r.source == SubmissionSource.ai;
    }).toList();
    if (overridesNeeded.isNotEmpty) {
      overrideAll = await svConfirm(
        context,
        title: 'Override AI-marked scores?',
        message:
            '${overridesNeeded.length} of these scores were marked by AI. '
            'Saving will replace them with your manual entry.',
        confirmLabel: 'Override',
      );
      if (!overrideAll) return;
    }

    setState(() => _saving = true);
    var saved = 0;
    for (final s in roster) {
      final r = _rows[s.id]!;
      final text = r.score.text.trim();
      if (!r.absent && text.isEmpty) continue; // nothing to record
      final v = r.absent ? null : double.tryParse(text.replaceAll(',', '.'));
      await _repo.recordScore(
        assessment: widget.assessment,
        studentId: s.id,
        score: v,
        absent: r.absent,
        remark: r.remark.text.trim(),
        override: r.source == SubmissionSource.ai && overrideAll,
      );
      saved++;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    svSnack(context, 'Saved $saved score${saved == 1 ? '' : 's'}.');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.assessment;
    return Scaffold(
      appBar: SvScreenHeader(
        title: 'Enter scores',
        subtitle: '${a.title} · out of ${_trim(a.effectiveTotal)}',
        actions: [
          IconButton(
            tooltip: 'Bulk upload',
            icon: const Icon(Icons.upload_file, color: Colors.white),
            onPressed: () async {
              // The roster is already loaded by [_future]; use it directly so
              // there is no async gap before this context use.
              final changed = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) =>
                      ScoreBulkUploadScreen(assessment: a, roster: _roster),
                ),
              );
              if (changed == true && mounted) {
                setState(() => _future = _load());
              }
            },
          ),
        ],
      ),
      floatingActionButton: FutureBuilder<List<Student>>(
        future: _future,
        builder: (context, snap) {
          final roster = snap.data ?? const <Student>[];
          if (roster.isEmpty) return const SizedBox.shrink();
          return FloatingActionButton.extended(
            onPressed: _saving ? null : () => _saveAll(roster),
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save),
            label: Text(_saving ? 'Saving…' : 'Save scores'),
          );
        },
      ),
      body: FutureBuilder<List<Student>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SvListSkeleton();
          }
          if (snap.hasError) {
            return SvErrorState(
              message: 'Could not load the class roster',
              onRetry: () => setState(() => _future = _load()),
            );
          }
          final roster = snap.data ?? const <Student>[];
          if (roster.isEmpty) {
            return const SvEmptyState(
              icon: Icons.people_outline,
              title: 'No pupils in this class',
              message: 'Register students into the class first.',
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 110),
            itemCount: roster.length,
            itemBuilder: (context, i) => _row(roster[i], i),
          );
        },
      ),
    );
  }

  Widget _row(Student s, int i) {
    final r = _rows[s.id]!;
    return SvEntrance(
      delay: Duration(milliseconds: 30 * i.clamp(0, 12)),
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 5),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.fullName,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14)),
                        if (s.admissionNo.isNotEmpty)
                          Text(s.admissionNo,
                              style: TextStyle(
                                  fontSize: 11, color: AppColors.muted)),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 92,
                    child: TextField(
                      controller: r.score,
                      enabled: !r.absent,
                      textAlign: TextAlign.center,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.,]')),
                      ],
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: r.absent ? '—' : 'Score',
                        suffixText:
                            '/${_trim(widget.assessment.effectiveTotal)}',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: r.remark,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Remark (optional)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Absent',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.body)),
                      Switch(
                        value: r.absent,
                        onChanged: (v) => setState(() => r.absent = v),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
