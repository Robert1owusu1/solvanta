import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/models/assessment.dart';
import '../../../core/models/class_room.dart';
import '../../../core/models/grading.dart';
import '../../../core/models/school_term.dart';
import '../../../core/models/student.dart';
import '../../../core/models/submission.dart';
import '../../../core/models/subjects.dart';
import '../../../core/platform/file_share.dart';
import '../../../core/storage/local_store.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_kit.dart';
import '../assessment_repository.dart';
import '../capture_screen.dart';
import '../manual_scores/score_entry_screen.dart';
import 'score_sheet.dart';

/// The score sheet (gradebook) for a class and subject: students × assessments,
/// each cell the score out of the max and marked AI / Manual / Absent, with a
/// weighted term total, grade and class position. Tapping a cell opens manual
/// entry for that assessment; tapping a column header opens the assessment.
class ScoreSheetScreen extends StatefulWidget {
  const ScoreSheetScreen({super.key, this.initialClassId, this.initialSubjectId});

  final String? initialClassId;
  final String? initialSubjectId;

  @override
  State<ScoreSheetScreen> createState() => _ScoreSheetScreenState();
}

class _Data {
  final List<ClassRoom> classes;
  final List<Student> students;
  final List<Assessment> assessments;
  final List<AssessmentSubmission> subs;
  final SchoolTerm currentTerm;
  final List<FinishedTerm> history;
  const _Data(this.classes, this.students, this.assessments, this.subs,
      this.currentTerm, this.history);
}

class _ScoreSheetScreenState extends State<ScoreSheetScreen> {
  final _repo = AssessmentRepository();
  final _store = LocalStore();
  late Future<_Data> _future;

  String? _classId;
  String _subjectId = 'MATH';
  AssessmentType? _typeFilter;
  String _termName = ''; // '' → current term

  @override
  void initState() {
    super.initState();
    _classId = widget.initialClassId;
    if (widget.initialSubjectId != null) _subjectId = widget.initialSubjectId!;
    _future = _load();
  }

  Future<_Data> _load() async {
    final classes = await _store.loadClasses();
    final students = await _store.loadStudents();
    final assessments = await _repo.assessments();
    final subs = await _repo.submissions();
    final term = await _store.loadTerm();
    final history = await _store.loadTermHistory();
    _classId ??= classes.isNotEmpty ? classes.first.id : null;
    return _Data(classes, students, assessments, subs, term, history);
  }

  void _reload() => setState(() => _future = _load());

  /// Builds the sheet for the current filters from loaded data.
  ScoreSheet? _sheet(_Data d) {
    final classId = _classId;
    if (classId == null) return null;
    // The term window + grading in force: a finished term carries its own.
    var term = d.currentTerm;
    var isCurrent = true;
    GradingScheme scheme = SchoolGrading.current.schemeFor(classId, d.classes);
    if (_termName.isNotEmpty && _termName != d.currentTerm.name) {
      for (final ft in d.history) {
        if (ft.term.name == _termName) {
          term = ft.term;
          isCurrent = false;
          scheme = ft.grading.schemeFor(classId, d.classes);
          break;
        }
      }
    }
    return buildScoreSheet(
      classId: classId,
      subjectId: _subjectId,
      assessments: d.assessments,
      students: d.students,
      subs: d.subs,
      scheme: scheme,
      term: term,
      isCurrent: isCurrent,
      typeFilter: _typeFilter,
    );
  }

  Future<void> _exportXlsx(ScoreSheet sheet) async {
    final bytes = scoreSheetXlsx(sheet);
    await saveAndShareFile(bytes, 'score-sheet-${sheet.classId}-${sheet.subjectId}.xlsx',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
  }

  Future<void> _exportPdf(ScoreSheet sheet) async {
    final bytes = await scoreSheetPdf(sheet);
    await saveAndShareFile(bytes, 'score-sheet-${sheet.classId}-${sheet.subjectId}.pdf',
        'application/pdf');
  }

  Future<void> _exportCsv(ScoreSheet sheet) async {
    final buf = StringBuffer()
      ..writeln('Student,Admission,'
          '${sheet.columns.map((c) => '"${c.title} (/${c.total})"').join(',')},'
          'Term total,Grade,Position');
    for (final row in sheet.rows) {
      buf.writeln([
        '"${row.student.fullName}"',
        row.student.admissionNo,
        for (final c in row.cells)
          c.absent ? 'Absent' : (c.present ? c.earned.toString() : ''),
        row.hasTotal ? '${row.termTotal.toStringAsFixed(1)}%' : '',
        row.hasTotal ? row.grade : '',
        row.position > 0 ? '${row.position}' : '',
      ].join(','));
    }
    await saveAndShareFile(Uint8List.fromList(utf8.encode(buf.toString())),
        'score-sheet-${sheet.classId}-${sheet.subjectId}.csv', 'text/csv');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(
        title: 'Score sheet',
        subtitle: 'Gradebook by class & subject',
        actions: [
          FutureBuilder<_Data>(
            future: _future,
            builder: (context, snap) {
              final d = snap.data;
              if (d == null) return const SizedBox.shrink();
              final sheet = _sheet(d);
              if (sheet == null || sheet.rows.isEmpty) {
                return const SizedBox.shrink();
              }
              return PopupMenuButton<String>(
                icon: const Icon(Icons.download, color: Colors.white),
                tooltip: 'Download',
                onSelected: (v) {
                  switch (v) {
                    case 'xlsx':
                      _exportXlsx(sheet);
                    case 'pdf':
                      _exportPdf(sheet);
                    case 'csv':
                      _exportCsv(sheet);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'xlsx', child: Text('Download .xlsx')),
                  PopupMenuItem(value: 'pdf', child: Text('Download PDF')),
                  PopupMenuItem(value: 'csv', child: Text('Download .csv')),
                ],
              );
            },
          ),
        ],
      ),
      body: FutureBuilder<_Data>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SvListSkeleton();
          }
          if (snap.hasError) {
            return SvErrorState(
                message: 'Could not load the score sheet', onRetry: _reload);
          }
          final d = snap.data!;
          return Column(
            children: [
              _filters(d),
              const Divider(height: 1),
              Expanded(child: _grid(d)),
            ],
          );
        },
      ),
    );
  }

  Widget _filters(_Data d) {
    final termNames = <String>['', for (final ft in d.history) ft.term.name];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          _dropdown<String>(
            label: 'Class',
            value: _classId,
            items: [
              for (final c in d.classes)
                DropdownMenuItem(value: c.id, child: Text(c.displayName)),
            ],
            onChanged: (v) => setState(() => _classId = v),
          ),
          const SizedBox(width: 10),
          _dropdown<String>(
            label: 'Subject',
            value: _subjectId,
            items: [
              for (final s in subjects)
                DropdownMenuItem(value: s.id, child: Text(s.name)),
            ],
            onChanged: (v) => setState(() => _subjectId = v ?? 'MATH'),
          ),
          const SizedBox(width: 10),
          _dropdown<AssessmentType?>(
            label: 'Type',
            value: _typeFilter,
            items: [
              const DropdownMenuItem(value: null, child: Text('All types')),
              for (final t in AssessmentType.values)
                DropdownMenuItem(value: t, child: Text(t.label)),
            ],
            onChanged: (v) => setState(() => _typeFilter = v),
          ),
          const SizedBox(width: 10),
          _dropdown<String>(
            label: 'Term',
            value: _termName,
            items: [
              for (final name in termNames)
                DropdownMenuItem(
                    value: name,
                    child: Text(name.isEmpty ? d.currentTerm.name : name)),
            ],
            onChanged: (v) => setState(() => _termName = v ?? ''),
          ),
        ],
      ),
    );
  }

  Widget _dropdown<T>({
    required String label,
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return SizedBox(
      width: 190,
      child: DropdownButtonFormField<T>(
        isExpanded: true,
        initialValue: value,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: items,
        onChanged: onChanged,
      ),
    );
  }

  Widget _grid(_Data d) {
    final sheet = _sheet(d);
    if (sheet == null) {
      return const SvEmptyState(
          icon: Icons.grid_on, title: 'Pick a class and subject');
    }
    if (sheet.columns.isEmpty) {
      return const SvEmptyState(
        icon: Icons.assignment_outlined,
        title: 'No assessments',
        message: 'There are no assessments for this class, subject and term yet.',
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(12),
        child: DataTable(
          headingRowHeight: 56,
          columnSpacing: 18,
          columns: [
            const DataColumn(label: Text('Student')),
            for (final col in sheet.columns)
              DataColumn(
                label: InkWell(
                  onTap: () => _openAssessment(col.assessment),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 110),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(col.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text('/${_fmt(col.total)}${col.isExam ? ' · exam' : ''}',
                            style: TextStyle(fontSize: 10, color: AppColors.muted)),
                      ],
                    ),
                  ),
                ),
              ),
            const DataColumn(label: Text('Term total'), numeric: true),
            const DataColumn(label: Text('Grade')),
            const DataColumn(label: Text('Pos'), numeric: true),
          ],
          rows: [
            for (final row in sheet.rows) _dataRow(sheet, row),
          ],
        ),
      ),
    );
  }

  DataRow _dataRow(ScoreSheet sheet, SheetRow row) {
    return DataRow(cells: [
      DataCell(Text(row.student.fullName,
          style: const TextStyle(fontWeight: FontWeight.w600))),
      for (var i = 0; i < row.cells.length; i++)
        DataCell(
          _cellWidget(row.cells[i]),
          onTap: () => _openCell(sheet.columns[i].assessment),
        ),
      DataCell(Text(row.hasTotal ? '${_fmt(row.termTotal)}%' : '—')),
      DataCell(Text(row.hasTotal ? row.grade : '—',
          style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.brand))),
      DataCell(Text(row.position > 0 ? '${row.position}' : '—')),
    ]);
  }

  Widget _cellWidget(SheetCell c) {
    if (!c.present) {
      // Empty cells are highlighted so gaps are obvious.
      return Container(
        width: 56,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text('—', style: TextStyle(color: AppColors.muted)),
      );
    }
    if (c.absent) {
      return _tag('Abs', AppColors.muted);
    }
    final color = c.source == SubmissionSource.ai
        ? AppColors.brand
        : AppColors.success;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_fmt(c.earned),
            style: const TextStyle(fontWeight: FontWeight.w700)),
        Text(c.source == SubmissionSource.ai ? 'AI' : 'Manual',
            style: TextStyle(fontSize: 9, color: color)),
      ],
    );
  }

  Widget _tag(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: color)),
      );

  String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  Future<void> _openCell(Assessment a) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ScoreEntryScreen(assessment: a)),
    );
    if (changed == true && mounted) _reload();
  }

  void _openAssessment(Assessment a) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => a.isScoreOnly
            ? ScoreEntryScreen(assessment: a)
            : CaptureScreen(assessment: a),
      ),
    );
  }
}
