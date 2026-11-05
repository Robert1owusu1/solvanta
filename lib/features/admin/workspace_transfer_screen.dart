import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/school.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';

/// Super-admin flow to move an independent teacher's workspace into a school:
/// pick the source workspace, review a dry-run preview (what moves + any
/// conflicts), resolve class clashes, then transfer. Talks to the server
/// directly ([ApiClient]) — a transfer that only happened on this device would
/// be meaningless.
class WorkspaceTransferScreen extends StatefulWidget {
  const WorkspaceTransferScreen({super.key, required this.target, this.client});

  final School target;
  final ApiClient? client;

  @override
  State<WorkspaceTransferScreen> createState() =>
      _WorkspaceTransferScreenState();
}

class _WorkspaceTransferScreenState extends State<WorkspaceTransferScreen> {
  ApiClient get _api => widget.client ?? ApiClient();

  late Future<List<School>> _workspaces = _loadWorkspaces();
  School? _source;
  Map<String, dynamic>? _preview;
  bool _busy = false;
  final _merge = <String>{}; // class ids to merge rather than create fresh

  Future<List<School>> _loadWorkspaces() async {
    final rows =
        (await _api.get('/api/schools') as List).cast<Map<String, dynamic>>();
    return [
      for (final r in rows)
        if ((r['kind'] as String?) == 'independent' && r['archived'] != true)
          School.fromJson(r),
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> _runPreview(School source) async {
    setState(() {
      _source = source;
      _preview = null;
      _merge.clear();
      _busy = true;
    });
    try {
      final res = await _api.post(
        '/api/schools/${widget.target.id}/transfers/preview',
        {'sourceSchoolId': source.id},
      ) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _preview = res);
    } on ApiException catch (e) {
      if (!mounted) return;
      svSnack(context, e.isNetwork ? "Couldn't reach the server." : e.message,
          error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _execute() async {
    final source = _source;
    if (source == null) return;
    final ok = await svConfirm(
      context,
      title: 'Transfer into ${widget.target.name}?',
      message:
          'This moves the workspace’s classes, students, assessments and '
          'scores into ${widget.target.name}, makes the teacher one of its '
          'teachers, and archives the workspace read-only. It cannot be undone.',
      confirmLabel: 'Transfer',
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await _api.post('/api/schools/${widget.target.id}/transfers', {
        'sourceSchoolId': source.id,
        'classDecisions': {for (final id in _merge) id: 'merge'},
      });
      if (!mounted) return;
      svSnack(context, 'Workspace transferred into ${widget.target.name}.');
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      svSnack(context, e.isNetwork ? "Couldn't reach the server." : e.message,
          error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(
        title: 'Transfer a workspace',
        subtitle: 'Into ${widget.target.name}',
      ),
      body: FutureBuilder<List<School>>(
        future: _workspaces,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SvListSkeleton();
          }
          if (snap.hasError) {
            return SvErrorState(
                message: 'Could not load workspaces',
                onRetry: () =>
                    setState(() => _workspaces = _loadWorkspaces()));
          }
          final workspaces = snap.data ?? const <School>[];
          if (workspaces.isEmpty) {
            return const SvEmptyState(
              icon: Icons.person_outline,
              title: 'No independent workspaces',
              message: 'There are no independent teacher workspaces to transfer.',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Text('1 · Choose the workspace',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: AppColors.ink)),
              const SizedBox(height: 8),
              for (final w in workspaces)
                Card(
                  child: ListTile(
                    leading: Icon(
                      _source?.id == w.id
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: _source?.id == w.id
                          ? AppColors.brand
                          : AppColors.muted,
                    ),
                    title: Text(w.name),
                    subtitle: Text(w.id),
                    onTap: _busy ? null : () => _runPreview(w),
                  ),
                ),
              if (_busy) ...[
                const SizedBox(height: 20),
                const Center(child: CircularProgressIndicator()),
              ],
              if (_preview != null && !_busy) ...[
                const SizedBox(height: 20),
                _previewView(_preview!),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _previewView(Map<String, dynamic> preview) {
    final counts = (preview['counts'] ?? const {}) as Map<String, dynamic>;
    final conflicts =
        ((preview['conflicts'] ?? const []) as List).cast<Map<String, dynamic>>();
    int n(String k) => (counts[k] as num?)?.toInt() ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('2 · What will move',
            style:
                TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _stat('Classes', n('classes')),
            _stat('Students', n('students')),
            _stat('Assessments', n('assessments')),
            _stat('Scores', n('scores')),
            _stat('Marking drafts', n('markingDrafts')),
            _stat('Scan images', n('scanImages')),
          ],
        ),
        const SizedBox(height: 18),
        if (conflicts.isEmpty)
          Row(children: [
            Icon(Icons.check_circle, color: AppColors.success, size: 18),
            const SizedBox(width: 8),
            const Expanded(child: Text('No conflicts.')),
          ])
        else ...[
          Text('3 · Resolve conflicts',
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: AppColors.ink)),
          const SizedBox(height: 8),
          for (final c in conflicts) _conflictTile(c),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _busy ? null : _execute,
          style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14)),
          icon: const Icon(Icons.swap_horiz),
          label: const Text('Transfer into this school'),
        ),
      ],
    );
  }

  Widget _conflictTile(Map<String, dynamic> c) {
    final kind = (c['kind'] ?? '') as String;
    final id = (c['id'] ?? '') as String;
    final detail = (c['detail'] ?? '') as String;
    if (kind == 'classNameClash') {
      final merging = _merge.contains(id);
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.warningBg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Class $id', style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(detail, style: TextStyle(fontSize: 12, color: AppColors.body)),
            const SizedBox(height: 4),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Create new')),
                ButtonSegment(value: true, label: Text('Merge')),
              ],
              selected: {merging},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() {
                if (s.first) {
                  _merge.add(id);
                } else {
                  _merge.remove(id);
                }
              }),
            ),
          ],
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.warningBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(Icons.warning_amber, color: AppColors.warning, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(detail)),
      ]),
    );
  }

  Widget _stat(String label, int value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('$value',
              style: TextStyle(
                  fontWeight: FontWeight.w800, color: AppColors.brand)),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 12, color: AppColors.body)),
        ]),
      );
}
