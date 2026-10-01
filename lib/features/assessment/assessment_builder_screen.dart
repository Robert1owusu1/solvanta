import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/class_room.dart';
import '../../core/models/question.dart';
import '../../core/models/subjects.dart';
import '../../core/models/user.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'assessment_repository.dart';
import 'question_editor_screen.dart';

class AssessmentBuilderScreen extends StatefulWidget {
  const AssessmentBuilderScreen({super.key, this.presets});

  final AssessmentBuilderPresets? presets;

  @override
  State<AssessmentBuilderScreen> createState() => _AssessmentBuilderScreenState();
}

class AssessmentBuilderPresets {
  final String topicTitle;
  final AssessmentType type;

  const AssessmentBuilderPresets({
    this.topicTitle = '',
    this.type = AssessmentType.exercise,
  });
}

class _AssessmentBuilderScreenState extends State<AssessmentBuilderScreen> {
  late final TextEditingController _title;
  final _repo = AssessmentRepository();
  String _subjectId = 'MATH';
  late AssessmentType _type;
  User? _user;
  late Set<AssessmentType> _allowed;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.presets?.topicTitle ?? '');
    _type = widget.presets?.type ?? AssessmentType.exercise;
    _allowed = AssessmentType.values.toSet();
    _loadUser();
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    final user = await AuthRepository().currentUser();
    if (!mounted) return;
    final allowed = AssessmentType.values
        .where((t) => user?.role.canCreateAssessmentOf(t) ?? true)
        .toSet();
    setState(() {
      _user = user;
      _allowed = allowed;
    });
    // Restricted preset — e.g. a teacher opening the intervention
    // re-assessment builder (preset: Remedial): say why instead of silently
    // downgrading the type.
    final preset = widget.presets;
    if (preset != null &&
        user != null &&
        !user.role.canCreateAssessmentOf(preset.type)) {
      svSnack(context,
          'Only school admins and headteachers can create '
          '${preset.type.label} assessments.',
          error: true);
      Navigator.of(context).pop(false);
    }
  }

  String? _classId;
  List<Question> _selected = [];

  Future<void> _generateBlueprint() async {
    final bank = await _repo.bank();
    final picked = _repo.blueprintPick(
        from: bank, subjectId: _subjectId, count: 5);
    if (!mounted) return;
    final merged = <String, Question>{};
    for (final q in _selected) {
      merged[q.id] = q;
    }
    for (final q in picked) {
      merged[q.id] = q;
    }
    setState(() => _selected = merged.values.toList());
  }

  Future<void> _addQuestion() async {
    final q = await Navigator.of(context).push<Question>(
      MaterialPageRoute(builder: (_) => const QuestionEditorScreen()),
    );
    if (q != null && mounted) {
      setState(() => _selected = [..._selected, q]);
    }
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a title')));
      return;
    }
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Add at least one question before saving. Publishers without '
              'questions crash for students, so we won\'t create one.'),
          backgroundColor: AppColors.danger,
        ),
      );
      return;
    }
    final user = await AuthRepository().currentUser();
    if (user == null || !user.role.canCreateAssessmentOf(_type)) {
      if (!mounted) return;
      svSnack(context,
          'Only school admins and headteachers can create '
          '${_type.label} assessments.',
          error: true);
      return;
    }
    final now = DateTime.now();
    final date =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final assessment = Assessment(
      id: 'ASSMT-${DateTime.now().millisecondsSinceEpoch}',
      title: _title.text.trim(),
      type: _type,
      subjectId: _subjectId,
      classId: _classId ?? 'JHS2A',
      date: date,
      createdBy: user.name,
      questions: _selected,
    );
    await _repo.saveAssessment(assessment);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New assessment')),
      body: FutureBuilder<List<ClassRoom>>(
        future: StudentsRepository().classes(),
        builder: (context, snap) {
          final classes = snap.data ?? [];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: _subjectId,
                decoration: const InputDecoration(labelText: 'Subject'),
                items: [
                  for (final s in subjects)
                    DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: (v) => setState(() => _subjectId = v ?? 'MATH'),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<AssessmentType>(
                initialValue: _allowed.contains(_type) ? _type : null,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [
                  for (final t in _allowed.toList()
                    ..sort((a, b) => a.index.compareTo(b.index)))
                    DropdownMenuItem(value: t, child: Text(t.label)),
                ],
                onChanged: (v) =>
                    setState(() => _type = v ?? AssessmentType.exercise),
              ),
              if (_user != null && !_user!.role.canCreateExams)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Exams (Mid-Term, End-of-Term, Mock) and formal '
                    'Diagnostic / Remedial assessments are created by your '
                    'school admin.',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.body),
                  ),
                ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: _classId,
                decoration: const InputDecoration(labelText: 'Class'),
                items: [
                  for (final c in classes)
                    DropdownMenuItem(value: c.id, child: Text(c.displayName)),
                ],
                onChanged: (v) => setState(() => _classId = v),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text(
                        'Questions (${_selected.length}) · ${_selected.fold<double>(0, (s, q) => s + q.marks)} marks',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: .w700)),
                  ),
                  TextButton(
                    onPressed: _generateBlueprint,
                    child: const Text('Add from bank'),
                  ),
                  TextButton(
                    onPressed: _addQuestion,
                    child: const Text('+ New'),
                  ),
                ],
              ),
              if (_selected.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
child: Text('No questions yet. Use "Add from bank" to '
                    'auto-select from the question bank by subject, or add '
                    'your own.',
                      style: TextStyle(color: AppColors.muted)),
                ),
              for (final q in _selected)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    dense: true,
                    title: Text(q.stem,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '${q.type.label} · ${q.topic} · ${q.marks.toStringAsFixed(0)} marks · ${q.difficulty}/3'),
                    trailing: IconButton(
                      tooltip: 'Remove ${q.topic} from this paper',
                      icon: Icon(Icons.remove_circle_outline,
                          color: AppColors.danger),
                      onPressed: () => setState(() =>
                          _selected = _selected.where((x) => x.id != q.id).toList()),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _save,
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16)),
                child: const Text('Save assessment'),
              ),
            ],
          );
        },
      ),
    );
  }
}