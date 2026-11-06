import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/billing.dart';
import '../../core/models/capabilities.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';

/// Super-admin "Plans & Pricing" (Phase 4). The platform ships in **testing**
/// mode — free for everyone, usage still counted — and this screen is where the
/// super admin later turns pricing on and shapes the plans. Talks to the server
/// directly ([ApiClient]).
class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key, this.client});

  final ApiClient? client;

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

/// The features shown as per-plan toggles (the ones an independent teacher can
/// actually be granted or denied).
const _togglableFeatures = <String, String>{
  Feature.markingAi: 'AI marking',
  Feature.scoresManual: 'Manual scores',
  Feature.scoresBulkUpload: 'Bulk score upload',
  Feature.scoreSheet: 'Score sheet',
  Feature.exportXlsx: 'Excel export',
  Feature.exportPdf: 'PDF export',
  Feature.questionBank: 'Question bank',
  Feature.aiQuestionGen: 'AI question generator',
  Feature.analyticsClass: 'Class analytics',
};

class _PlansScreenState extends State<PlansScreen> {
  ApiClient get _api => widget.client ?? ApiClient();
  bool get _online => widget.client != null || ApiClient.isConfigured;

  late Future<(PlatformSettings, List<Plan>)> _data =
      _online ? _load() : Future.error('offline');

  Future<(PlatformSettings, List<Plan>)> _load() async {
    final s = PlatformSettings.fromJson(
        await _api.get('/api/platform/billing') as Map<String, dynamic>);
    final plans = (await _api.get('/api/plans') as List)
        .cast<Map<String, dynamic>>()
        .map(Plan.fromJson)
        .toList();
    return (s, plans);
  }

  void _reload() => setState(() => _data = _load());

  void _snack(String m, {bool error = false}) {
    if (mounted) svSnack(context, m, error: error);
  }

  Future<void> _saveSettings(PlatformSettings s) async {
    if (s.isLive &&
        !await svConfirm(context,
            title: 'Switch to live billing?',
            message:
                'Teachers will be charged from ${s.liveStartDate.isEmpty ? 'now' : s.liveStartDate}. '
                'Usage is already being counted. You can switch back to testing at any time.',
            confirmLabel: 'Go live')) {
      return;
    }
    try {
      await _api.put('/api/platform/billing', s.toJson());
      _snack('Billing settings saved.');
      _reload();
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    }
  }

  Future<void> _savePlan(Plan p, {bool create = false}) async {
    try {
      if (create) {
        await _api.post('/api/plans', p.toJson());
      } else {
        await _api.put('/api/plans/${p.id}', p.toJson());
      }
      if (mounted) Navigator.of(context).pop();
      _snack('Plan saved.');
      _reload();
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(
          title: 'Plans & Pricing', subtitle: 'Platform billing (super admin)'),
      floatingActionButton: _online
          ? FloatingActionButton.extended(
              onPressed: () => _editPlan(
                  const Plan(id: '', name: 'New plan', kind: 'independent'),
                  create: true),
              icon: const Icon(Icons.add),
              label: const Text('New plan'),
            )
          : null,
      body: !_online
          ? const SvEmptyState(
              icon: Icons.cloud_off,
              title: 'Server required',
              message: 'Plans & pricing live on the server.')
          : FutureBuilder<(PlatformSettings, List<Plan>)>(
              future: _data,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const SvListSkeleton();
                }
                if (snap.hasError) {
                  return SvErrorState(
                      message: 'Could not load plans', onRetry: _reload);
                }
                final (settings, plans) = snap.data!;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
                  children: [
                    _billingCard(settings),
                    const SizedBox(height: 18),
                    Text('Plans',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, color: AppColors.ink)),
                    const SizedBox(height: 8),
                    for (final p in plans) _planCard(p),
                  ],
                );
              },
            ),
    );
  }

  Widget _billingCard(PlatformSettings s) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Billing mode',
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: AppColors.ink)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'testing', label: Text('Testing (free)')),
                ButtonSegment(value: 'live', label: Text('Live')),
              ],
              selected: {s.billingMode},
              showSelectedIcon: false,
              onSelectionChanged: (sel) =>
                  _saveSettings(s.copyWith(billingMode: sel.first)),
            ),
            const SizedBox(height: 8),
            Text(
              s.isLive
                  ? 'Live from ${s.liveStartDate.isEmpty ? 'now' : s.liveStartDate} · grace ${s.graceDays} days'
                  : 'Free access for everyone. Usage is still counted so you can price from real numbers.',
              style: TextStyle(fontSize: 12, color: AppColors.body),
            ),
            const SizedBox(height: 8),
            Text(
              'The free tier is self-serve. Paid plans are arranged with the '
              'school directly — SOLVANTA does not take payments in-app. '
              'Prices here are for quoting; schools pay you their own way.',
              style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _planCard(Plan p) {
    // Live preview for a teacher with 45 students.
    const sample = 45;
    final month = formatGhs(p.pricePerStudentMonth * sample);
    final term = formatGhs(p.pricePerStudentTerm * sample);
    return Card(
      child: ListTile(
        title: Text(p.name,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${p.kind}${p.isFreeTier ? ' · free tier' : ''}'
                '${p.active ? '' : ' · inactive'}'),
            Text('A teacher with $sample students pays $month / month or $term / term',
                style: TextStyle(fontSize: 12, color: AppColors.body)),
          ],
        ),
        trailing: const Icon(Icons.edit_outlined),
        onTap: () => _editPlan(p),
      ),
    );
  }

  Future<void> _editPlan(Plan plan, {bool create = false}) async {
    final name = TextEditingController(text: plan.name);
    final month = TextEditingController(
        text: (plan.pricePerStudentMonth / 100).toStringAsFixed(2));
    final term = TextEditingController(
        text: (plan.pricePerStudentTerm / 100).toStringAsFixed(2));
    final maxStudents = TextEditingController(
        text: plan.limits['max_students']?.toString() ?? '');
    final features = {..._togglableFeatures.keys.fold<Map<String, bool>>(
        {}, (m, k) => m..[k] = plan.includes(k))};
    var active = plan.active;
    var kind = plan.kind.isEmpty ? 'independent' : plan.kind;
    var freeTier = plan.isFreeTier;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16),
        child: StatefulBuilder(
          builder: (ctx, setSheet) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(create ? 'New plan' : 'Edit plan',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 10),
                if (create) ...[
                  Text('Who the plan is for',
                      style: TextStyle(fontSize: 12, color: AppColors.body)),
                  const SizedBox(height: 6),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'independent',
                          label: Text('Independent teacher')),
                      ButtonSegment(value: 'school', label: Text('School')),
                    ],
                    selected: {kind},
                    showSelectedIcon: false,
                    onSelectionChanged: (sel) =>
                        setSheet(() => kind = sel.first),
                  ),
                  const SizedBox(height: 10),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: freeTier,
                  onChanged: (v) => setSheet(() => freeTier = v),
                  title: const Text('Free tier (self-serve, price ignored)'),
                ),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: month,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'GHS / student / month'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: term,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'GHS / student / term'),
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                TextField(
                  controller: maxStudents,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Max students',
                    hintText: 'Leave empty for unlimited',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: active,
                  onChanged: (v) => setSheet(() => active = v),
                  title: const Text('Active'),
                ),
                const Divider(),
                Text('Features included',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: AppColors.ink)),
                for (final e in _togglableFeatures.entries)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: features[e.key] ?? false,
                    onChanged: (v) =>
                        setSheet(() => features[e.key] = v ?? false),
                    title: Text(e.value),
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      final ms = int.tryParse(maxStudents.text.trim());
                      final priceMonth =
                          ((double.tryParse(month.text.trim()) ?? 0) * 100)
                              .round();
                      final priceTerm =
                          ((double.tryParse(term.text.trim()) ?? 0) * 100)
                              .round();
                      final limits = {
                        'max_students': ms, // null when empty → unlimited
                      };
                      // Editing keeps the plan's id and kind; creating uses the
                      // chosen kind.
                      final updated = create
                          ? Plan(
                              id: '',
                              name: name.text.trim(),
                              kind: kind,
                              isFreeTier: freeTier,
                              active: active,
                              pricePerStudentMonth: priceMonth,
                              pricePerStudentTerm: priceTerm,
                              features: features,
                              limits: limits,
                            )
                          : plan.copyWith(
                              name: name.text.trim(),
                              isFreeTier: freeTier,
                              active: active,
                              pricePerStudentMonth: priceMonth,
                              pricePerStudentTerm: priceTerm,
                              features: features,
                              limits: limits,
                            );
                      _savePlan(updated, create: create);
                    },
                    child: const Text('Save plan'),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
    name.dispose();
    month.dispose();
    term.dispose();
    maxStudents.dispose();
  }
}
