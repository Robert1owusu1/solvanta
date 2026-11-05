import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/models/student.dart';
import '../../core/platform/file_share.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../students/students_repository.dart';
import 'fee_models.dart';
import 'fees_repository.dart';
import 'payments_io.dart';

/// Record many payments at once from a filled-in CSV/XLSX. The school collects
/// fees its own way, then uploads what it received here — each row is previewed
/// (valid / warning / error) before anything is written, and only the writable
/// rows are recorded (offline-first, through [FeesRepository.recordPayment]).
class PaymentsBulkUploadScreen extends StatefulWidget {
  const PaymentsBulkUploadScreen({super.key, required this.recordedBy});

  final String recordedBy;

  @override
  State<PaymentsBulkUploadScreen> createState() =>
      _PaymentsBulkUploadScreenState();
}

class _PaymentsBulkUploadScreenState extends State<PaymentsBulkUploadScreen> {
  final _repo = FeesRepository();
  final _pasted = TextEditingController();
  List<Student> _students = const [];
  List<Invoice> _invoices = const [];
  List<PaymentPreviewRow>? _preview;
  bool _saving = false;
  late final Future<void> _loaded = _load();

  @override
  void dispose() {
    _pasted.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _students = await StudentsRepository().all();
    _invoices = await _repo.invoices();
  }

  Future<void> _downloadCsv() async {
    await saveAndShareFile(
      Uint8List.fromList(utf8.encode(paymentTemplateCsv(_students, _invoices))),
      'payments-template.csv',
      'text/csv',
    );
  }

  Future<void> _downloadXlsx() async {
    await saveAndShareFile(
      paymentTemplateXlsx(_students, _invoices),
      'payments-template.xlsx',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
  }

  void _show(List<PaymentUploadRow> rows, {required String emptyHint}) {
    if (rows.isEmpty) {
      svSnack(context, emptyHint, error: true);
      return;
    }
    setState(() => _preview = buildPaymentPreview(
        students: _students, invoices: _invoices, rows: rows));
  }

  Future<void> _pickFile() async {
    final files = await FilePickerPlatform.instance.pickFiles(
        type: FileType.custom, allowedExtensions: const ['csv', 'xlsx']);
    if (!mounted || files.isEmpty) return;
    final f = files.first;
    final Uint8List bytes;
    try {
      bytes = await f.readAsBytes();
    } catch (_) {
      if (mounted) svSnack(context, 'Could not read "${f.name}".', error: true);
      return;
    }
    if (!mounted) return;
    final ext = (f.extension ?? '').toLowerCase();
    _show(
      ext == 'xlsx'
          ? parsePaymentXlsx(bytes)
          : parsePaymentCsv(utf8.decode(bytes, allowMalformed: true)),
      emptyHint: 'No rows found in "${f.name}" (need the studentId,… header).',
    );
  }

  Future<void> _confirm() async {
    final preview = _preview;
    if (preview == null) return;
    final writable = preview.where((r) => r.willWrite).toList();
    if (writable.isEmpty) {
      svSnack(context, 'Nothing to record — fix the rows flagged in red.',
          error: true);
      return;
    }
    final s = summarizePayments(preview);
    if (!await svConfirm(context,
        title: 'Record ${writable.length} payment(s)?',
        message: 'Totalling ${svCedis(s.totalPesewasAmount)}.'
            '${s.error > 0 ? ' ${s.error} row(s) with errors will be skipped.' : ''}',
        confirmLabel: 'Record')) {
      return;
    }
    setState(() => _saving = true);
    var done = 0, failed = 0;
    for (final r in writable) {
      try {
        await _repo.recordPayment(
          invoiceId: r.invoiceId!,
          amount: r.amount,
          method: r.method,
          reference: r.reference,
          recordedBy: widget.recordedBy,
        );
        done++;
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() => _saving = false);
    svSnack(context,
        'Recorded $done payment(s)${failed > 0 ? ', $failed could not be recorded' : ''}.',
        error: failed > 0);
    Navigator.of(context).pop(done > 0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SvScreenHeader(
        title: 'Upload payments',
        subtitle: 'Record fees collected your own way',
      ),
      body: FutureBuilder<void>(
        future: _loaded,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SvListSkeleton();
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            children: [
              Text(
                'SOLVANTA does not take money. Collect fees your own way (cash, '
                'mobile money, bank), then record what you received here.',
                style: TextStyle(fontSize: 13, color: AppColors.body),
              ),
              const SizedBox(height: 16),
              Text('1 · Download the template',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: AppColors.ink)),
              const SizedBox(height: 8),
              Wrap(spacing: 10, children: [
                OutlinedButton.icon(
                    onPressed: _downloadXlsx,
                    icon: const Icon(Icons.grid_on, size: 18),
                    label: const Text('.xlsx template')),
                OutlinedButton.icon(
                    onPressed: _downloadCsv,
                    icon: const Icon(Icons.description_outlined, size: 18),
                    label: const Text('.csv template')),
              ]),
              const SizedBox(height: 22),
              Text('2 · Upload the filled-in sheet',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: AppColors.ink)),
              const SizedBox(height: 8),
              FilledButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Choose .xlsx or .csv file')),
              const SizedBox(height: 14),
              TextField(
                controller: _pasted,
                minLines: 3,
                maxLines: 10,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  hintText:
                      'studentId,admissionNo,studentName,invoiceId,amount,method,reference\n…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _show(parsePaymentCsv(_pasted.text),
                    emptyHint: 'Paste the filled-in template, header row included.'),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Preview pasted text'),
              ),
              if (_preview != null) ...[
                const SizedBox(height: 22),
                _summary(summarizePayments(_preview!)),
                const SizedBox(height: 10),
                for (final row in _preview!) _row(row),
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
                  label: Text(_saving ? 'Recording…' : 'Confirm & record'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _summary(PaymentPreviewSummary s) {
    Widget chip(String label, int n, Color c) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
              color: c.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(10)),
          child: Text('$n $label',
              style: TextStyle(
                  color: c, fontWeight: FontWeight.w700, fontSize: 12)),
        );
    return Wrap(spacing: 8, children: [
      chip('valid', s.valid, AppColors.success),
      chip('warning', s.warning, AppColors.warning),
      chip('error', s.error, AppColors.danger),
      if (s.valid > 0)
        chip('total ${svCedis(s.totalPesewasAmount)}', 0, AppColors.brand),
    ]);
  }

  Widget _row(PaymentPreviewRow row) {
    final (color, icon) = switch (row.status) {
      PaymentRowStatus.valid => (AppColors.success, Icons.check_circle),
      PaymentRowStatus.warning => (AppColors.warning, Icons.warning_amber),
      PaymentRowStatus.error => (AppColors.danger, Icons.error_outline),
    };
    final who = row.studentName ??
        (row.raw.studentId.isNotEmpty ? row.raw.studentId : row.raw.admissionNo);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .3)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Row ${row.line} · ${who.isEmpty ? '—' : who}',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            Text(row.message,
                style: TextStyle(fontSize: 11, color: AppColors.body)),
          ]),
        ),
        if (row.willWrite)
          Text('${svCedis(row.amount)} · ${row.method.label}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
      ]),
    );
  }
}
