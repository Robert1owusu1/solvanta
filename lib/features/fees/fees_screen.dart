import 'package:flutter/material.dart';

import '../../core/models/student.dart';
import '../../core/models/user.dart';
import '../../core/responsive.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/data_table.dart';
import '../../core/ui/ui_kit.dart';
import '../students/students_repository.dart';
import 'fee_models.dart';
import 'fees_repository.dart';
import 'invoice_detail_screen.dart';

// ---------------------------------------------------------------------------
// Admin fees dashboard: whole-school totals, searchable/filterable invoice
// list, tap-through to the invoice detail (line items, payments, receipts).
// Offline-first: every read comes from the local fees store.
// ---------------------------------------------------------------------------

/// One successful load of the admin fees dashboard.
typedef _AdminFeesData = ({
  List<Invoice> invoices,
  List<Student> students,
  FeesTotals totals,
});

/// Invoice status filter chips; index 0 (`All`) disables the filter.
const _statusFilters = ['All', 'Due', 'Partial', 'Overdue', 'Paid'];

/// Fees & Payments module screen for bursars and school admins: school-wide
/// totals summary, search + status chips over every invoice, and tap-through
/// to [InvoiceDetailScreen]. Staff-only — other roles get a restricted state.
class FeesScreen extends StatefulWidget {
  const FeesScreen({super.key, required this.user});

  /// Signed-in staff member (gates the record-payment action).
  final User user;

  @override
  State<FeesScreen> createState() => _FeesScreenState();
}

class _FeesScreenState extends State<FeesScreen> {
  late Future<_AdminFeesData> _data;
  String _query = '';
  int _filter = 0;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_AdminFeesData> _load() async {
    final repo = FeesRepository();
    final invoices = await repo.invoices();
    final totals = await repo.schoolTotals();
    List<Student> students;
    try {
      students = await StudentsRepository().all();
    } catch (e) {
      // Names are decoration here — invoices still render with their ids.
      debugPrint('[Fees] students unavailable for list: $e');
      students = const <Student>[];
    }
    return (invoices: invoices, students: students, totals: totals);
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() => _data = next);
    await next;
  }

  Future<void> _open(Invoice invoice) async {
    svHaptic(SvHaptic.light);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => InvoiceDetailScreen(
          invoiceId: invoice.id,
          canRecord: widget.user.isSchoolStaff,
          recordedBy: widget.user.name,
        ),
      ),
    );
    if (!mounted) return;
    setState(() { _data = _load(); });
  }

  List<Invoice> _filtered(_AdminFeesData data) {
    final q = _query.trim().toLowerCase();
    final byId = _byId(data.students);
    return data.invoices.where((invoice) {
      if (_filter > 0 && invoice.resolveStatus().label != _statusFilters[_filter]) {
        return false;
      }
      if (q.isEmpty) return true;
      final student = byId[invoice.studentId];
      final haystack = [
        invoice.id,
        invoice.studentId,
        student?.fullName ?? '',
        student?.admissionNo ?? '',
        student?.classId ?? '',
      ].join(' ').toLowerCase();
      return haystack.contains(q);
    }).toList();
  }

  Map<String, Student> _byId(List<Student> students) => {
        for (final s in students) s.id: s,
      };

  @override
  Widget build(BuildContext context) {
    if (!widget.user.isSchoolStaff) {
      return Scaffold(
        appBar: const SvScreenHeader(title: 'Fees & Payments'),
        body: const SvEmptyState(
          icon: Icons.lock_outline,
          title: 'Fee management is restricted',
          message: 'Payments are handled by the bursar and school admins. '
              'Ask the school office if you need cashier access.',
        ),
      );
    }
    return Scaffold(
      appBar: const SvScreenHeader(
        title: 'Fees & Payments',
        subtitle: 'Bills, payments & receipts',
      ),
      body: FutureBuilder<_AdminFeesData>(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return ListView(
              children: const [
                SvCardSkeleton(),
                SvListSkeleton(rows: 6),
              ],
            );
          }
          if (snap.hasError) {
            return SvErrorState(
              message: 'Could not load fees for this school.',
              onRetry: _refresh,
            );
          }
          final data = snap.data;
          if (data == null) {
            return const SvEmptyState(
              icon: Icons.account_balance_wallet,
              title: 'No fee data yet',
              message: 'Invoices appear here once the term charges are set.',
            );
          }
          final shown = _filtered(data);
          final byId = _byId(data.students);
          return Column(
            children: [
              _totalsCard(data.totals),
              SvSearchField(
                hint: 'Search by student, invoice or class',
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 10),
              SvFilterChips(
                options: [
                  for (var i = 0; i < _statusFilters.length; i++)
                    SvFilterOption(_statusFilters[i], selected: _filter == i),
                ],
                onSelected: (i) {
                  svHaptic(SvHaptic.selection);
                  setState(() => _filter = i);
                },
              ),
              const SizedBox(height: 4),
              const SvSectionTitle('Invoices'),
              Expanded(
                child: shown.isEmpty
                    ? (data.invoices.isEmpty
                        ? const SvEmptyState(
                            icon: Icons.receipt_long,
                            title: 'No invoices yet',
                            message:
                                'Bills appear here as soon as the term charges '
                                'are applied to students.',
                          )
                        : const SvEmptyState(
                            icon: Icons.search_off_outlined,
                            title: 'No invoices match',
                            message:
                                'Try a different search term or status filter.',
                          ))
                    : MediaQuery.sizeOf(context).width >= Breakpoints.largeTablet
                        // Desktop: the invoices as a sortable table.
                        ? SvDataTable<Invoice>(
                            rows: shown,
                            onOpen: _open,
                            columns: [
                              SvColumn(
                                label: 'Student',
                                flex: 4,
                                sortKey: (i) => (byId[i.studentId]?.fullName ?? i.studentId).toLowerCase(),
                                cell: (i) => Text(byId[i.studentId]?.fullName ?? i.studentId,
                                    style: const TextStyle(fontWeight: FontWeight.w700)),
                              ),
                              SvColumn(label: 'Class', flex: 1, sortKey: (i) => byId[i.studentId]?.classId ?? '',
                                  cell: (i) => Text(byId[i.studentId]?.classId ?? '–')),
                              SvColumn(label: 'Invoice', sortKey: (i) => i.id, cell: (i) => Text(i.id)),
                              SvColumn(label: 'Total', numeric: true, sortKey: (i) => i.total,
                                  cell: (i) => Text(svCedis(i.total))),
                              SvColumn(label: 'Paid', numeric: true, sortKey: (i) => i.amountPaid,
                                  cell: (i) => Text(svCedis(i.amountPaid))),
                              SvColumn(label: 'Balance', numeric: true, sortKey: (i) => i.balance,
                                  cell: (i) => Text(svCedis(i.balance), style: const TextStyle(fontWeight: FontWeight.w700))),
                              SvColumn(label: 'Due', sortKey: (i) => i.dueDate, cell: (i) => Text(i.dueDate)),
                              SvColumn(label: 'Status', sortKey: (i) => i.resolveStatus().index,
                                  cell: (i) => invoiceStatusChip(i.resolveStatus())),
                            ],
                          )
                        : SvRefresh(
                        onRefresh: _refresh,
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: shown.length,
                          itemBuilder: (context, i) => feesEntrance(
                            i,
                            SvPressScale(
                              child: _invoiceTile(shown[i], byId),
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Summary card: billed / collected / outstanding + overdue position.
  /// Money stays neutral navy; only the overdue status carries danger.
  Widget _totalsCard(FeesTotals totals) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _figure('Billed', svCedis(totals.billed), AppColors.ink),
              _figure('Collected', svCedis(totals.collected), AppColors.ink),
              _figure(
                'Outstanding',
                svCedis(totals.outstanding),
                AppColors.brand,
              ),
            ],
          ),
          if (totals.overdueCount > 0) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 10),
            svStatus(
              '${totals.overdueCount} overdue · '
              '${svCedis(totals.overdueAmount)}',
              Icons.error_outline,
              AppColors.danger,
            ),
          ],
        ],
      ),
    );
  }

  Widget _figure(String label, String value, Color color) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ],
        ),
      );

  Widget _invoiceTile(Invoice invoice, Map<String, Student> byId) {
    final student = byId[invoice.studentId];
    return SvAvatarTile(
      title: student?.fullName ?? invoice.studentId,
      initials: student?.initials,
      icon: Icons.receipt_long,
      meta: '${invoice.id} · Balance ${svCedis(invoice.balance)} · '
          'Due ${invoice.dueDate}',
      chip: invoiceStatusChip(invoice.resolveStatus()),
      avatarColor: AppTheme.brand,
      onTap: () => _open(invoice),
    );
  }
}
