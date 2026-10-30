import 'package:flutter/material.dart';

import '../../core/models/class_room.dart';
import '../../core/models/grading.dart';
import '../../core/models/subjects.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../audit/audit_repository.dart';
import '../auth/auth_repository.dart';
import 'admin_repository.dart';
import 'grading_repository.dart';

/// The school's grading and scoring set-up: one scheme per range of classes
/// (pre-school, primary, JHS…), each with its own class-score / exam split,
/// grade bands and aggregate rule. Report cards pick the scheme for the
/// student's class. Only the school admin can change it; everyone else sees
/// it read-only (the server enforces the same).
class GradingSettingsScreen extends StatefulWidget {
  const GradingSettingsScreen({super.key});

  @override
  State<GradingSettingsScreen> createState() => _GradingSettingsScreenState();
}

class _GradingSettingsScreenState extends State<GradingSettingsScreen> {
  late Future<void> _loading;
  GradingConfig _config = GradingConfig.fallback;
  List<ClassRoom> _classes = const [];
  bool _canEdit = false;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loading = _load();
  }

  Future<void> _load() async {
    final config = await GradingRepository().config();
    final classes = await AdminRepository().classes();
    final user = await AuthRepository().currentUser();
    if (!mounted) return;
    setState(() {
      _config = config;
      _classes = classes;
      _canEdit = user?.role.canManageGrading ?? false;
      _dirty = false;
    });
  }

  /// Class levels (`JHS1`, `B4`) from the class list, sorted.
  List<String> get _levels =>
      {for (final c in _classes) c.name.toUpperCase()}.toList()..sort();

  void _replace(List<GradingScheme> schemes) => setState(() {
        _config = GradingConfig(
          schoolId: _config.schoolId,
          schemes: schemes,
          updatedAt: _config.updatedAt,
          updatedBy: _config.updatedBy,
        );
        _dirty = true;
      });

  Future<void> _edit({GradingScheme? existing, GradingScheme? preset}) async {
    final start = existing ??
        (preset ?? letterPreset).copyWith(
          name: '',
          classNames: const [],
          isDefault: false,
        );
    final id = existing?.id ?? 'scheme-${DateTime.now().millisecondsSinceEpoch}';
    final taken = <String, String>{
      for (final s in _config.schemes)
        if (s.id != existing?.id)
          for (final n in s.classNames) n: s.name,
    };
    final result = await Navigator.of(context).push<GradingScheme>(
      MaterialPageRoute(
        builder: (_) => _SchemeEditor(
          initial: GradingScheme.fromJson({...start.toJson(), 'id': id}),
          levels: _levels,
          taken: taken,
          isOnlyScheme: _config.schemes.length <= 1 && existing != null,
        ),
      ),
    );
    if (result == null) return;
    final schemes = [
      for (final s in _config.schemes)
        if (s.id == result.id)
          result
        else if (result.isDefault && s.isDefault)
          s.copyWith(isDefault: false)
        else
          s,
      if (existing == null) result,
    ];
    _replace(schemes);
  }

  Future<void> _delete(GradingScheme scheme) async {
    if (scheme.isDefault) {
      _snack('Make another scheme the default before removing this one.');
      return;
    }
    final ok = await svConfirm(
      context,
      title: 'Remove "${scheme.name}"?',
      message: 'Its classes will follow the default scheme '
          '"${_config.defaultScheme.name}" once you save.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok) return;
    _replace([
      for (final s in _config.schemes)
        if (s.id != scheme.id) s,
    ]);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final problem = await GradingRepository().save(_config);
    if (problem == null) {
      await AuditRepository().log(
        action: 'grading.update',
        actor: 'Admin',
        target: _config.schoolId,
        detail: 'Grading set-up saved (${_config.schemes.length} scheme(s))',
        reason: 'Grading & scoring',
      );
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (problem == null) _dirty = false;
    });
    _snack(problem ?? 'Grading saved. New report cards will use it.');
  }

  void _snack(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return svConfirm(
      context,
      title: 'Discard changes?',
      message: "Your grading changes haven't been saved.",
      confirmLabel: 'Discard',
      destructive: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          setState(() => _dirty = false);
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: const SvScreenHeader(
          title: 'Grading & Scoring',
          subtitle: 'Score split and grades for each class range',
        ),
        body: FutureBuilder<void>(
          future: _loading,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SvListSkeleton();
            }
            if (snap.hasError) {
              return SvErrorState(
                title: "Couldn't load the grading set-up",
                onRetry: () => setState(() { _loading = _load(); }),
              );
            }
            final problem = _config.problem();
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                if (!_canEdit)
                  _Notice(
                    icon: Icons.lock_outline,
                    text: 'Only the school admin can change grading. '
                        'This is what report cards currently use.',
                  ),
                if (_config.updatedBy.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Last saved by ${_config.updatedBy}'
                      '${_config.updatedAt.isEmpty ? '' : ' · ${_config.updatedAt}'}',
                      style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                    ),
                  ),
                for (final s in _config.schemes)
                  _SchemeCard(
                    scheme: s,
                    canEdit: _canEdit,
                    onEdit: () => _edit(existing: s),
                    onDelete: () => _delete(s),
                  ),
                if (_canEdit) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: PopupMenuButton<GradingScheme>(
                      tooltip: 'Add a scheme',
                      onSelected: (p) => _edit(preset: p),
                      itemBuilder: (_) => [
                        for (final p in gradingPresets)
                          PopupMenuItem(
                            value: p,
                            child: Text('Start from ${p.name}'),
                          ),
                      ],
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add),
                            SizedBox(width: 6),
                            Flexible(
                              child: Text('Add scheme for other classes',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                if (_dirty && problem != null)
                  _Notice(icon: Icons.error_outline, text: problem, error: true),
              ],
            );
          },
        ),
        bottomNavigationBar: !_canEdit || !_dirty
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: SizedBox(
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: _saving || _config.problem() != null
                          ? null
                          : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(_saving ? 'Saving…' : 'Save grading'),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.error = false});

  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error ? AppColors.danger : AppColors.brand;
    return Container(
      margin: const EdgeInsets.only(bottom: 10, top: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _SchemeCard extends StatelessWidget {
  const _SchemeCard({
    required this.scheme,
    required this.canEdit,
    required this.onEdit,
    required this.onDelete,
  });

  final GradingScheme scheme;
  final bool canEdit;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: canEdit ? onEdit : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(scheme.name,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                  if (scheme.isDefault)
                    SvStatusBadge(
                      label: 'Default',
                      icon: Icons.star_outline,
                      color: AppColors.brand,
                    ),
                  if (canEdit)
                    PopupMenuButton<String>(
                      onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                        if (!scheme.isDefault)
                          const PopupMenuItem(
                              value: 'delete', child: Text('Remove')),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                scheme.classNames.isEmpty
                    ? 'Every class not listed in another scheme'
                    : 'Classes: ${scheme.classNames.join(', ')}'
                        '${scheme.isDefault ? ' (and any class not listed elsewhere)' : ''}',
                style: TextStyle(color: AppColors.muted),
              ),
              const SizedBox(height: 4),
              Text(scheme.summary),
              if (scheme.decidesPromotion || scheme.interventionBelow != null)
                Text(
                  'End of year: ${scheme.yearRulesLine}',
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                ),
              if (scheme.showAggregate)
                Text(
                  'Aggregate: ${scheme.coreSubjects.join(', ')}'
                  '${scheme.bestOthers > 0 ? ' + best ${scheme.bestOthers}' : ''}',
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// One scheme's editor
// ---------------------------------------------------------------------------

class _SchemeEditor extends StatefulWidget {
  const _SchemeEditor({
    required this.initial,
    required this.levels,
    required this.taken,
    required this.isOnlyScheme,
  });

  final GradingScheme initial;

  /// Class levels the school has (`JHS1`, `B4`…).
  final List<String> levels;

  /// Levels other schemes already use → that scheme's name.
  final Map<String, String> taken;

  /// The only scheme must stay the default.
  final bool isOnlyScheme;

  @override
  State<_SchemeEditor> createState() => _SchemeEditorState();
}

class _BandRow {
  _BandRow(GradeBand b)
      : min = TextEditingController(text: _num(b.min)),
        grade = TextEditingController(text: b.grade),
        remark = TextEditingController(text: b.remark);

  final TextEditingController min;
  final TextEditingController grade;
  final TextEditingController remark;

  GradeBand? get band {
    final m = double.tryParse(min.text.trim());
    return m == null ? null : GradeBand(m, grade.text.trim(), remark.text.trim());
  }

  void dispose() {
    min.dispose();
    grade.dispose();
    remark.dispose();
  }
}

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

class _SchemeEditorState extends State<_SchemeEditor> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initial.name);
  late final TextEditingController _otherLevel = TextEditingController();
  late final Set<String> _classNames = {...widget.initial.classNames};
  late bool _isDefault = widget.initial.isDefault || widget.isOnlyScheme;
  late double _classWeight = widget.initial.classWeight;
  late List<_BandRow> _bands = [for (final b in widget.initial.bands) _BandRow(b)];
  late bool _showAggregate = widget.initial.showAggregate;
  late Set<String> _cores = {...widget.initial.coreSubjects};
  late int _bestOthers = widget.initial.bestOthers;
  late final TextEditingController _promoteAt =
      TextEditingController(text: _opt(widget.initial.promoteAt));
  late final TextEditingController _repeatBelow =
      TextEditingController(text: _opt(widget.initial.repeatBelow));
  late final TextEditingController _interventionBelow =
      TextEditingController(text: _opt(widget.initial.interventionBelow));
  String? _error;

  static String _opt(double? v) => v == null ? '' : _num(v);

  @override
  void dispose() {
    _name.dispose();
    _otherLevel.dispose();
    _promoteAt.dispose();
    _repeatBelow.dispose();
    _interventionBelow.dispose();
    for (final b in _bands) {
      b.dispose();
    }
    super.dispose();
  }

  void _applyPreset(GradingScheme p) {
    setState(() {
      for (final b in _bands) {
        b.dispose();
      }
      _bands = [for (final b in p.bands) _BandRow(b)];
      _classWeight = p.classWeight;
      _showAggregate = p.showAggregate;
      _cores = {...p.coreSubjects};
      _bestOthers = p.bestOthers;
    });
  }

  void _addLevel() {
    final level = _otherLevel.text.trim().toUpperCase();
    if (level.isEmpty) return;
    final owner = widget.taken[level];
    if (owner != null) {
      setState(() => _error = '$level already follows "$owner".');
      return;
    }
    setState(() {
      _classNames.add(level);
      _otherLevel.clear();
      _error = null;
    });
  }

  GradingScheme? _build() {
    final bands = <GradeBand>[];
    for (final r in _bands) {
      final b = r.band;
      if (b == null) {
        setState(() => _error = 'Every band needs a lowest mark (0–100).');
        return null;
      }
      bands.add(b);
    }
    bands.sort((a, b) => b.min.compareTo(a.min));
    final grades = bands.every((b) => int.tryParse(b.grade) != null);
    final scheme = widget.initial.copyWith(
      name: _name.text.trim(),
      classNames: _classNames.toList()..sort(),
      isDefault: _isDefault,
      classWeight: _classWeight,
      examWeight: 100 - _classWeight,
      bands: bands,
      showAggregate: _showAggregate && grades,
      coreSubjects: _showAggregate && grades
          ? subjects.map((s) => s.id).where(_cores.contains).toList()
          : const [],
      bestOthers: _showAggregate && grades ? _bestOthers : 0,
    );
    // Blank turns a year rule off; anything else must be a number.
    double? rule(TextEditingController c) => double.tryParse(c.text.trim());
    for (final c in [_promoteAt, _repeatBelow, _interventionBelow]) {
      if (c.text.trim().isNotEmpty && rule(c) == null) {
        setState(() => _error = 'End-of-year marks must be numbers (0–100), '
            'or left blank.');
        return null;
      }
    }
    final withRules = scheme.withYearRules(
      promoteAt: rule(_promoteAt),
      repeatBelow: rule(_repeatBelow),
      interventionBelow: rule(_interventionBelow),
    );
    final problem = withRules.problem();
    if (problem != null) {
      setState(() => _error = problem);
      return null;
    }
    return withRules;
  }

  @override
  Widget build(BuildContext context) {
    final levels = {...widget.levels, ..._classNames}.toList()..sort();
    final numeric = _bands
        .every((r) => int.tryParse(r.grade.text.trim()) != null);
    return Scaffold(
      appBar: SvScreenHeader(
        title: widget.initial.name.isEmpty ? 'New scheme' : 'Edit scheme',
        subtitle: 'Applies to the classes you choose',
        actions: [
          PopupMenuButton<GradingScheme>(
            tooltip: 'Start from a preset',
            icon: const Icon(Icons.auto_fix_high, color: Colors.white),
            onSelected: _applyPreset,
            itemBuilder: (_) => [
              for (final p in gradingPresets)
                PopupMenuItem(value: p, child: Text('Use ${p.name}')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          TextField(
            controller: _name,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: 'Scheme name (e.g. Primary, JHS, Pre-school)',
              border: OutlineInputBorder(),
            ),
          ),
          const SvSectionTitle('Classes'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Default scheme'),
            subtitle: const Text(
                'Also used for any class not listed in another scheme'),
            value: _isDefault,
            onChanged: widget.isOnlyScheme || widget.initial.isDefault
                ? null
                : (v) => setState(() => _isDefault = v),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final l in levels)
                FilterChip(
                  label: Text(widget.taken[l] == null
                      ? l
                      : '$l · ${widget.taken[l]}'),
                  selected: _classNames.contains(l),
                  onSelected: widget.taken[l] != null
                      ? null
                      : (v) => setState(() =>
                          v ? _classNames.add(l) : _classNames.remove(l)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _otherLevel,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Another class level (e.g. KG1, B3)',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _addLevel(),
                ),
              ),
              IconButton(
                tooltip: 'Add class level',
                icon: const Icon(Icons.add),
                onPressed: _addLevel,
              ),
            ],
          ),
          const SvSectionTitle('Score split'),
          Text(
            'Class score ${_num(_classWeight)}%  ·  '
            'Exam ${_num(100 - _classWeight)}%',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          Slider(
            value: _classWeight,
            max: 100,
            divisions: 100,
            label: '${_num(_classWeight)} / ${_num(100 - _classWeight)}',
            onChanged: (v) => setState(() => _classWeight = v.roundToDouble()),
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final w in const [30.0, 40.0, 50.0, 60.0])
                ChoiceChip(
                  label: Text('${_num(w)}/${_num(100 - w)}'),
                  selected: _classWeight == w,
                  onSelected: (_) => setState(() => _classWeight = w),
                ),
            ],
          ),
          SvSectionTitle(
            'Grade bands',
            trailing: TextButton.icon(
              onPressed: () => setState(
                  () => _bands.add(_BandRow(const GradeBand(0, '', '')))),
              icon: const Icon(Icons.add),
              label: const Text('Band'),
            ),
          ),
          Text(
            'A total from the lowest mark up to the next band earns the grade. '
            'One band must start at 0.',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          for (final (i, r) in _bands.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 72,
                    child: TextField(
                      controller: r.min,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'From', isDense: true),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 64,
                    child: TextField(
                      controller: r.grade,
                      maxLength: 4,
                      decoration: const InputDecoration(
                          labelText: 'Grade', isDense: true, counterText: ''),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: r.remark,
                      maxLength: 24,
                      decoration: const InputDecoration(
                          labelText: 'Remark', isDense: true, counterText: ''),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove band',
                    icon: const Icon(Icons.close),
                    onPressed: _bands.length <= 1
                        ? null
                        : () => setState(() => _bands.removeAt(i).dispose()),
                  ),
                ],
              ),
            ),
          const SvSectionTitle('Aggregate'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Print an aggregate (e.g. BECE best 6)'),
            subtitle: Text(numeric
                ? 'Sum of the chosen core subjects plus the best others — '
                    'lower is better'
                : 'Needs whole-number grades (1, 2, 3…)'),
            value: _showAggregate && numeric,
            onChanged:
                numeric ? (v) => setState(() => _showAggregate = v) : null,
          ),
          if (_showAggregate && numeric) ...[
            const Text('Core subjects (always counted)',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final s in subjects)
                  FilterChip(
                    label: Text(s.name),
                    selected: _cores.contains(s.id),
                    onSelected: (v) => setState(
                        () => v ? _cores.add(s.id) : _cores.remove(s.id)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Expanded(child: Text('Plus the best other subjects')),
                IconButton(
                  tooltip: 'Fewer',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: _bestOthers <= 0
                      ? null
                      : () => setState(() => _bestOthers--),
                ),
                Text('$_bestOthers',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                IconButton(
                  tooltip: 'More',
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: _bestOthers >= 10
                      ? null
                      : () => setState(() => _bestOthers++),
                ),
              ],
            ),
          ],
          const SvSectionTitle('End of year'),
          Text(
            'Decided on the full-year average: each term counts its average '
            'out of 100 (Terms 1–3 make 300), and the year average is their '
            'mean. Leave a box blank to decide that by hand.',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          for (final (c, label, help) in [
            (
              _promoteAt,
              'Promote at (average or above)',
              'Printed on the Term 3 card as "Promoted to …"',
            ),
            (
              _repeatBelow,
              'Repeat below',
              'Between the two marks goes to the headteacher',
            ),
            (
              _interventionBelow,
              'Parent meeting below',
              'Asks the parents in, on reports from Term 2 on',
            ),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                controller: c,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: label,
                  helperText: help,
                  suffixText: '/ 100',
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          if (_error != null)
            _Notice(icon: Icons.error_outline, text: _error!, error: true),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: () {
                final s = _build();
                if (s != null) Navigator.of(context).pop(s);
              },
              child: const Text('Done'),
            ),
          ),
        ),
      ),
    );
  }
}
