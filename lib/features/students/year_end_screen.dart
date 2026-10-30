import 'package:flutter/material.dart';

import '../../core/models/grading.dart';
import '../../core/models/promotion.dart';
import '../../core/models/student.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../reports/report_card_pdf.dart';
import '../reports/report_card_source.dart';
import 'promotions_repository.dart';

/// End of the academic year: every student's full-year average and the
/// decision the school's rules give (promote / repeat / complete), with the
/// in-between cases left for the headteacher to choose. Applying moves the
/// students — once per student per year. Only open in Term 3.
class YearEndPromotionsScreen extends StatefulWidget {
  const YearEndPromotionsScreen({super.key});

  @override
  State<YearEndPromotionsScreen> createState() =>
      _YearEndPromotionsScreenState();
}

class _Row {
  _Row(this.student, this.card, this.applied);

  final Student student;
  final ReportCardData card;
  final PromotionRecord? applied;

  /// The headteacher's choice where the rules leave it open.
  YearOutcome? chosen;

  YearOutcome? get decision =>
      card.outcome == YearOutcome.review ? chosen : (card.outcome ?? chosen);
}

class _YearEndPromotionsScreenState extends State<YearEndPromotionsScreen> {
  late Future<({ReportCardSource source, List<_Row> rows, String actor})> _data;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<({ReportCardSource source, List<_Row> rows, String actor})>
  _load() async {
    final source = await ReportCardSource.load();
    final applied = await PromotionsRepository().appliedFor(source.term.year);
    final user = await AuthRepository().currentUser();
    final rows =
        [
          for (final s in source.students)
            if (s.status == 'Active' || applied.containsKey(s.id))
              _Row(s, source.cardFor(s), applied[s.id]),
        ]..sort((a, b) {
          final c = a.card.classId.compareTo(b.card.classId);
          return c != 0 ? c : a.student.fullName.compareTo(b.student.fullName);
        });
    return (source: source, rows: rows, actor: user?.name ?? 'Admin');
  }

  Future<void> _apply(
    ReportCardSource source,
    List<_Row> rows,
    String actor,
  ) async {
    final todo = [
      for (final r in rows)
        if (r.applied == null &&
            r.decision != null &&
            r.decision != YearOutcome.review)
          r,
    ];
    if (todo.isEmpty) return;
    int count(YearOutcome o) => todo.where((r) => r.decision == o).length;
    final skipped = rows
        .where(
          (r) =>
              r.applied == null &&
              (r.decision == null || r.decision == YearOutcome.review),
        )
        .length;
    final ok = await svConfirm(
      context,
      title: 'Apply end-of-year decisions?',
      message:
          'Promote ${count(YearOutcome.promoted)}, '
          'repeat ${count(YearOutcome.repeated)}, '
          'complete ${count(YearOutcome.completed)}'
          '${skipped == 0 ? '' : '; $skipped still to be decided will be left as they are'}.\n\n'
          'Students move to their new classes now. Each student can only be '
          'decided once for ${source.term.year}.',
      confirmLabel: 'Apply',
    );
    if (!ok || !mounted) return;
    setState(() => _applying = true);
    final n = await PromotionsRepository().apply(
      [
        for (final r in todo)
          YearEndDecision(
            student: r.student,
            classId: r.card.classId,
            outcome: r.decision!,
            average: r.card.year.average,
          ),
      ],
      year: source.term.year,
      classes: source.classes,
      actor: actor,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Applied $n end-of-year decision(s).')),
    );
    setState(() {
      _applying = false;
      _data = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SvScreenHeader(
        title: 'End-of-Year Promotions',
        subtitle: 'From the full-year average and the school\'s rules',
      ),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return SvErrorState(
              title: "Couldn't work out the year",
              onRetry: () => setState(() { _data = _load(); }),
            );
          }
          final data = snap.data;
          if (data == null) return const SvListSkeleton();
          final termThree = termNumber(data.source.term.name) == 3;
          final rows = data.rows;
          final pending = rows.where((r) => r.applied == null).toList();
          int n(YearOutcome? o) => pending.where((r) => r.decision == o).length;
          String? lastClass;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            children: [
              if (!termThree)
                _Banner(
                  'Promotions are decided at the end of Term 3. It is '
                  '${data.source.term.label} — this is the year so far.',
                ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _count('Promote', n(YearOutcome.promoted)),
                  _count('Repeat', n(YearOutcome.repeated)),
                  _count('Complete', n(YearOutcome.completed)),
                  _count('To decide', n(YearOutcome.review) + n(null)),
                  _count('Already applied', rows.length - pending.length),
                ],
              ),
              const SizedBox(height: 8),
              for (final r in rows) ...[
                if (r.card.classId != lastClass)
                  SvSectionTitle(lastClass = r.card.classId),
                _StudentTile(
                  row: r,
                  enabled: termThree && !_applying,
                  onChoose: (o) => setState(() => r.chosen = o),
                ),
              ],
            ],
          );
        },
      ),
      bottomNavigationBar: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          final data = snap.data;
          if (data == null ||
              termNumber(data.source.term.name) != 3 ||
              !data.rows.any(
                (r) =>
                    r.applied == null &&
                    r.decision != null &&
                    r.decision != YearOutcome.review,
              )) {
            return const SizedBox.shrink();
          }
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: SizedBox(
                height: 48,
                child: FilledButton.icon(
                  onPressed: _applying
                      ? null
                      : () => _apply(data.source, data.rows, data.actor),
                  icon: const Icon(Icons.upgrade),
                  label: Text(_applying ? 'Applying…' : 'Apply decisions'),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _count(String label, int n) => Chip(label: Text('$label: $n'));
}

class _Banner extends StatelessWidget {
  const _Banner(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.brand.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        Icon(Icons.info_outline, color: AppColors.brand),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

class _StudentTile extends StatelessWidget {
  const _StudentTile({
    required this.row,
    required this.enabled,
    required this.onChoose,
  });

  final _Row row;
  final bool enabled;
  final ValueChanged<YearOutcome> onChoose;

  @override
  Widget build(BuildContext context) {
    final card = row.card;
    final avg = card.year.average;
    final applied = row.applied;
    final open =
        applied == null &&
        (card.outcome == null || card.outcome == YearOutcome.review);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
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
                      Text(
                        row.student.fullName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        avg == null
                            ? 'No marks this year yet'
                            : 'Year average ${avg.toStringAsFixed(1)} · '
                                  '${card.year.formula}',
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                if (applied != null)
                  _tag(
                    '${applied.outcome.label}'
                    '${applied.toClassId.isEmpty || applied.toClassId == applied.classId ? '' : ' → ${applied.toClassId}'}',
                  )
                else if (!open)
                  _tag(
                    '${card.outcome!.label}'
                    '${card.promotedTo == null ? '' : ' → ${card.promotedTo}'}',
                  ),
              ],
            ),
            if (open && avg != null) ...[
              const SizedBox(height: 6),
              Text(
                card.outcome == YearOutcome.review
                    ? 'Between the promotion and repeat marks — choose:'
                    : 'No automatic rule for this class — choose:',
                style: const TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 4),
              SegmentedButton<YearOutcome>(
                emptySelectionAllowed: true,
                segments: const [
                  ButtonSegment(
                    value: YearOutcome.promoted,
                    label: Text('Promote'),
                  ),
                  ButtonSegment(
                    value: YearOutcome.repeated,
                    label: Text('Repeat'),
                  ),
                ],
                selected: {?row.chosen},
                onSelectionChanged: enabled
                    ? (s) {
                        if (s.isNotEmpty) onChoose(s.first);
                      }
                    : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tag(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: AppTheme.brand.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: AppColors.brand,
        fontWeight: FontWeight.w700,
        fontSize: 12.5,
      ),
    ),
  );
}
