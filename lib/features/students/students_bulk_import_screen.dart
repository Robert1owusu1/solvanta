import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/models/class_room.dart';
import '../../core/models/student.dart';
import '../../core/platform/file_share.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import 'students_io.dart';
import 'students_repository.dart';

/// Bulk-register students from a filled-in CSV/XLSX — the same
/// preview-then-confirm pattern as scores and payments. For school admins and
/// independent teachers setting up a class quickly.
class StudentsBulkImportScreen extends StatefulWidget {
  const StudentsBulkImportScreen({super.key});

  @override
  State<StudentsBulkImportScreen> createState() =>
      _StudentsBulkImportScreenState();
}

class _StudentsBulkImportScreenState extends State<StudentsBulkImportScreen> {
  final _repo = StudentsRepository();
  final _pasted = TextEditingController();
  List<ClassRoom> _classes = const [];
  List<Student> _existing = const [];
  List<StudentPreviewRow>? _preview;
  bool _saving = false;
  late final Future<void> _loaded = _load();

  @override
  void dispose() {
    _pasted.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _classes = await _repo.classes();
    _existing = await _repo.all();
  }

  Future<void> _downloadCsv() async => saveAndShareFile(
        Uint8List.fromList(utf8.encode(studentTemplateCsv(_classes))),
        'students-template.csv',
        'text/csv',
      );

  Future<void> _downloadXlsx() async => saveAndShareFile(
        studentTemplateXlsx(_classes),
        'students-template.xlsx',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );

  void _show(List<StudentUploadRow> rows, {required String hint}) {
    if (rows.isEmpty) {
      svSnack(context, hint, error: true);
      return;
    }
    setState(() => _preview = buildStudentPreview(
        classes: _classes, existing: _existing, rows: rows));
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
          ? parseStudentXlsx(bytes)
          : parseStudentCsv(utf8.decode(bytes, allowMalformed: true)),
      hint: 'No rows found in "${f.name}" (need the firstName,… header).',
    );
  }

  Future<void> _confirm() async {
    final preview = _preview;
    if (preview == null) return;
    final writable = preview.where((r) => r.willWrite).toList();
    if (writable.isEmpty) {
      svSnack(context, 'Nothing to add — fix the rows flagged in red.',
          error: true);
      return;
    }
    if (!await svConfirm(context,
        title: 'Register ${writable.length} student(s)?',
        message: 'They will be added to their classes.',
        confirmLabel: 'Register')) {
      return;
    }
    setState(() => _saving = true);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    var done = 0;
    for (var i = 0; i < writable.length; i++) {
      final r = writable[i];
      await _repo.saveStudent(Student(
        id: 'STU-$stamp-$i',
        firstName: r.firstName,
        lastName: r.lastName,
        gender: r.gender,
        dateOfBirth: '',
        admissionDate: '',
        admissionNo: r.admissionNo,
        classId: r.classId,
        schoolId: _existing.isNotEmpty ? _existing.first.schoolId : '',
      ));
      done++;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    svSnack(context, 'Registered $done student(s).');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SvScreenHeader(
          title: 'Import students', subtitle: 'Register a class in one go'),
      body: FutureBuilder<void>(
        future: _loaded,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SvListSkeleton();
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            children: [
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
                  hintText: 'firstName,lastName,gender,admissionNo,classId\n…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _show(parseStudentCsv(_pasted.text),
                    hint: 'Paste the filled-in template, header row included.'),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Preview pasted text'),
              ),
              if (_preview != null) ...[
                const SizedBox(height: 22),
                _summary(summarizeStudents(_preview!)),
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
                  label: Text(_saving ? 'Registering…' : 'Confirm & register'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _summary(StudentPreviewSummary s) {
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
    ]);
  }

  Widget _row(StudentPreviewRow row) {
    final (color, icon) = switch (row.status) {
      StudentRowStatus.valid => (AppColors.success, Icons.check_circle),
      StudentRowStatus.warning => (AppColors.warning, Icons.warning_amber),
      StudentRowStatus.error => (AppColors.danger, Icons.error_outline),
    };
    final name = [row.raw.firstName, row.raw.lastName]
        .where((s) => s.trim().isNotEmpty)
        .join(' ');
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
            Text('Row ${row.line} · ${name.isEmpty ? '—' : name}',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            Text(row.message,
                style: TextStyle(fontSize: 11, color: AppColors.body)),
          ]),
        ),
        if (row.willWrite)
          Text('${row.classId} · ${row.gender}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
      ]),
    );
  }
}
