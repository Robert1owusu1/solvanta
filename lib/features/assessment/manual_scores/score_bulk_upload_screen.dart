import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/models/assessment.dart';
import '../../../core/models/student.dart';
import '../../../core/platform/file_share.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_kit.dart';
import '../assessment_repository.dart';
import 'score_io.dart';

/// Bulk manual score upload. The teacher downloads a template (prefilled with
/// the roster), fills it in, then pastes the completed sheet back. Every row is
/// previewed as valid / warning / error before anything is saved, and only the
/// writable rows are sent — so the server's atomic batch never half-applies.
///
/// A completed `.xlsx` can be pasted as its raw text too, but the simplest path
/// on web and mobile (no file-picker dependency in this project) is to paste
/// the `.csv`.
class ScoreBulkUploadScreen extends StatefulWidget {
  const ScoreBulkUploadScreen({
    super.key,
    required this.assessment,
    required this.roster,
  });

  final Assessment assessment;
  final List<Student> roster;

  @override
  State<ScoreBulkUploadScreen> createState() => _ScoreBulkUploadScreenState();
}

class _ScoreBulkUploadScreenState extends State<ScoreBulkUploadScreen> {
  final _pasted = TextEditingController();
  List<ScorePreviewRow>? _preview;
  bool _saving = false;

  @override
  void dispose() {
    _pasted.dispose();
    super.dispose();
  }

  Future<void> _downloadCsv() async {
    final csv = scoreTemplateCsv(widget.assessment, widget.roster);
    await saveAndShareFile(
      Uint8List.fromList(utf8.encode(csv)),
      'scores-${widget.assessment.id}.csv',
      'text/csv',
    );
  }

  Future<void> _downloadXlsx() async {
    final bytes = scoreTemplateXlsx(widget.assessment, widget.roster);
    await saveAndShareFile(
      bytes,
      'scores-${widget.assessment.id}.xlsx',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
  }

  void _showPreview(List<ScoreUploadRow> rows, {required String emptyHint}) {
    if (rows.isEmpty) {
      svSnack(context, emptyHint, error: true);
      return;
    }
    setState(() {
      _preview = buildScorePreview(
        assessment: widget.assessment,
        roster: widget.roster,
        rows: rows,
      );
    });
  }

  void _previewPasted() {
    _showPreview(
      parseScoreCsv(_pasted.text),
      emptyHint: 'No rows found. Paste the filled-in template, including its '
          'studentId,admissionNo,… header line.',
    );
  }

  Future<void> _pickFile() async {
    final files = await FilePickerPlatform.instance.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv', 'xlsx'],
    );
    if (!mounted || files.isEmpty) return;
    final file = files.first;
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      if (!mounted) return;
      svSnack(context, 'Could not read "${file.name}".', error: true);
      return;
    }
    if (!mounted) return;
    final ext = (file.extension ?? '').toLowerCase();
    final rows = ext == 'xlsx'
        ? parseScoreXlsx(bytes)
        : parseScoreCsv(utf8.decode(bytes, allowMalformed: true));
    _showPreview(
      rows,
      emptyHint: 'No scores found in "${file.name}". Make sure it has the '
          'studentId,admissionNo,… header row.',
    );
  }

  Future<void> _confirm() async {
    final preview = _preview;
    if (preview == null) return;
    final payload = scorePayload(preview);
    if (payload.isEmpty) {
      svSnack(context, 'Nothing to save — fix the rows flagged in red.',
          error: true);
      return;
    }
    final summary = summarizePreview(preview);
    final ok = await svConfirm(
      context,
      title: 'Save ${payload.length} score${payload.length == 1 ? '' : 's'}?',
      message: summary.error > 0
          ? '${summary.error} row(s) have errors and will be skipped. '
              '${payload.length} will be saved.'
          : '${payload.length} score(s) will be saved.',
      confirmLabel: 'Save',
    );
    if (!ok) return;

    setState(() => _saving = true);
    try {
      await AssessmentRepository().bulkRecordScores(
        assessment: widget.assessment,
        rows: payload,
      );
      if (!mounted) return;
      svSnack(context, 'Saved ${payload.length} score(s).');
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      svSnack(context, 'Could not save the scores. Please try again.',
          error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(
        title: 'Bulk upload scores',
        subtitle: widget.assessment.title,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Text('1 · Download the template',
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: AppColors.ink)),
          const SizedBox(height: 4),
          Text(
            'The template is prefilled with your class roster. Fill the '
            'score, absent and remark columns, then paste it back below.',
            style: TextStyle(fontSize: 12, color: AppColors.body),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: _downloadXlsx,
                icon: const Icon(Icons.grid_on, size: 18),
                label: const Text('.xlsx template'),
              ),
              OutlinedButton.icon(
                onPressed: _downloadCsv,
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text('.csv template'),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text('2 · Upload the filled-in sheet',
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: AppColors.ink)),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _pickFile,
            icon: const Icon(Icons.upload_file),
            label: const Text('Choose .xlsx or .csv file'),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('or paste it',
                    style: TextStyle(fontSize: 12, color: AppColors.muted)),
              ),
              const Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _pasted,
            minLines: 4,
            maxLines: 12,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              hintText:
                  'studentId,admissionNo,studentName,score,absent,remark\n…',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _previewPasted,
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Preview pasted text'),
          ),
          if (_preview != null) ...[
            const SizedBox(height: 22),
            _summaryBar(summarizePreview(_preview!)),
            const SizedBox(height: 10),
            for (final row in _preview!) _previewRow(row),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _saving ? null : _confirm,
              style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save),
              label: Text(_saving ? 'Saving…' : 'Confirm & save'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _summaryBar(ScorePreviewSummary s) {
    Widget chip(String label, int n, Color c) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: c.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text('$n $label',
              style: TextStyle(
                  color: c, fontWeight: FontWeight.w700, fontSize: 12)),
        );
    return Wrap(
      spacing: 8,
      children: [
        chip('valid', s.valid, AppColors.success),
        chip('warning', s.warning, AppColors.warning),
        chip('error', s.error, AppColors.danger),
      ],
    );
  }

  Widget _previewRow(ScorePreviewRow row) {
    final (color, icon) = switch (row.status) {
      ScoreRowStatus.valid => (AppColors.success, Icons.check_circle),
      ScoreRowStatus.warning => (AppColors.warning, Icons.warning_amber),
      ScoreRowStatus.error => (AppColors.danger, Icons.error_outline),
    };
    final who = row.resolvedStudentName ??
        (row.raw.studentId.isNotEmpty
            ? row.raw.studentId
            : row.raw.admissionNo.isNotEmpty
                ? row.raw.admissionNo
                : row.raw.studentName);
    final value = row.absent
        ? 'Absent'
        : row.score != null
            ? row.score.toString()
            : row.raw.scoreText;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Row ${row.line} · ${who.isEmpty ? '—' : who}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13)),
                Text(row.message,
                    style: TextStyle(fontSize: 11, color: AppColors.body)),
              ],
            ),
          ),
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: AppColors.ink)),
        ],
      ),
    );
  }
}
