import 'package:flutter/material.dart';

import '../../core/models/student.dart';
import '../../core/models/user.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../students/students_repository.dart';
import 'fee_models.dart';
import 'fees_repository.dart';
import 'invoice_detail_screen.dart';

// ---------------------------------------------------------------------------
// Parent / student fees portal: one child's totals, the term's published
// charges and their invoices (tap-through to the detail; the Record-payment
// action stays staff-only).
// ---------------------------------------------------------------------------

/// One successful load of a student's fees view.
typedef _StudentFeesData = ({
  FeesTotals totals,
  List<FeeStructure> structures,
  List<Invoice> invoices,
});

/// Fees view for a single [student], shown to staff (bursar/admin), to the
/// linked parent, or to the student themself. Any other pairing renders a
/// friendly restricted state — never somebody else's numbers.
class StudentFeesScreen extends StatefulWidget {
  const StudentFeesScreen({
    super.key,
    required this.user,
    required this.student,
    this.showAppBar = true,
  });

  /// Signed-in user requesting the view (used for the role gate).
  final User user;

  /// Student whose fees are shown.
  final Student student;

  /// Set to false when embedded under another scaffold (child switcher).
  final bool showAppBar;

  @override
  State<StudentFeesScreen> createState() => _StudentFeesScreenState();
}

class _StudentFeesScreenState extends State<StudentFeesScreen> {
  late Future<_StudentFeesData> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  /// Role gate: staff always; parents only their linked children; students
  /// only themselves.
  bool get _allowed {
    final user = widget.user;
    if (user.isSchoolStaff) return true;
    if (user.role.isParent) {
      return user.studentIds.contains(widget.student.id) ||
          widget.student.parentUserId == user.id;
    }
    if (user.role.isStudent) {
      return user.id.replaceFirst('USR-', '') == widget.student.id;
    }
    return false;
  }

  Future<_StudentFeesData> _load() async {
    final repo = FeesRepository();
    final totals = await repo.totalsForStudent(widget.student.id);
    final structures = await repo.structuresForStudent(widget.student);
    final invoices = await repo.invoicesForStudent(widget.student.id);
    return (totals: totals, structures: structures, invoices: invoices);
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() => _data = next);
    await next;
  }

  Future<void> _openInvoice(Invoice invoice) async {
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
    setState(() => _data = _load());
  }

  Widget _restricted() => Scaffold(
        appBar: widget.showAppBar
            ? const SvScreenHeader(title: 'My Fees')
            : null,
        body: const SvEmptyState(
          icon: Icons.lock_outline,
          title: 'Access restricted',
          message: 'You can only see fees for your own children or yourself. '
              'Ask the school office if you need access.',
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (!_allowed) return _restricted();
    final body = FutureBuilder<_StudentFeesData>(
      future: _data,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return ListView(
            children: const [
              SvCardSkeleton(),
              SvListSkeleton(rows: 5),
            ],
          );
        }
        if (snap.hasError) {
          return SvErrorState(
            message: 'Could not load fees for ${widget.student.fullName}.',
            onRetry: _refresh,
          );
        }
        final data = snap.data;
        if (data == null) {
          return const SvEmptyState(
            icon: Icons.account_balance_wallet,
            title: 'No fee data yet',
            message: 'Charges and invoices appear here once the bursar '
                'publishes them.',
          );
        }
        final bothEmpty = data.structures.isEmpty && data.invoices.isEmpty;
        return Column(
          children: [
            _totalsCard(data.totals),
            Expanded(
              child: bothEmpty
                  ? const SvEmptyState(
                      icon: Icons.receipt_long,
                      title: 'Nothing due yet',
                      message: 'This student has no published charges or '
                          'invoices for the current term.',
                    )
                  : SvRefresh(
                      onRefresh: _refresh,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SvSectionTitle('Term charges'),
                          if (data.structures.isEmpty)
                            _hint('No charges published for this term yet.')
                          else
                            for (var i = 0; i < data.structures.length; i++)
                              feesEntrance(
                                i,
                                SvPressScale(
                                  child: _structureTile(data.structures[i]),
                                ),
                              ),
                          const SvSectionTitle('Invoices'),
                          if (data.invoices.isEmpty)
                            _hint(
                              'No invoice raised for '
                              '${widget.student.firstName} yet.',
                            )
                          else
                            for (var i = 0; i < data.invoices.length; i++)
                              feesEntrance(
                                i,
                                SvPressScale(
                                  child: _invoiceTile(data.invoices[i]),
                                ),
                              ),
                          const SizedBox(height: 20),
                        ],
                      ),
                    ),
            ),
          ],
        );
      },
    );
    if (!widget.showAppBar) return body;
    return Scaffold(
      appBar: SvScreenHeader(
        title: 'Fees & Payments',
        subtitle: widget.student.fullName,
      ),
      body: body,
    );
  }

  /// Totals card: billed / paid / balance, money kept navy; the overdue
  /// position is the only danger-coloured element (glyph + text).
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
              _figure('Paid', svCedis(totals.collected), AppColors.ink),
              _figure('Balance', svCedis(totals.outstanding), AppColors.brand),
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

  Widget _hint(String message) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
        child: Text(
          message,
          style: TextStyle(
            fontSize: 13,
            color: AppColors.muted,
            height: 1.4,
          ),
        ),
      );

  Widget _structureTile(FeeStructure fee) {
    final scope = fee.classId == FeeStructure.allClasses
        ? 'All classes'
        : fee.classId;
    return SvAvatarTile(
      title: fee.name,
      meta: '$scope · Due ${fee.dueDate}',
      icon: Icons.account_balance_wallet,
      avatarColor: AppTheme.brand,
      trailing: Text(
        svCedis(fee.amount),
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 14,
          color: AppTheme.brand,
        ),
      ),
    );
  }

  Widget _invoiceTile(Invoice invoice) {
    return SvAvatarTile(
      title: 'Invoice ${invoice.id}',
      icon: Icons.receipt_long,
      meta: 'Balance ${svCedis(invoice.balance)} · '
          'Due ${invoice.dueDate}',
      chip: invoiceStatusChip(invoice.resolveStatus()),
      avatarColor: AppTheme.brand,
      onTap: () => _openInvoice(invoice),
    );
  }
}

// ---------------------------------------------------------------------------
// Multi-child wrapper (parent portal)
// ---------------------------------------------------------------------------

/// Wrapper for parents with more than one linked child: shows the fees view
/// of the selected child with a switcher in the app bar, mirroring the
/// parent dashboard's child switcher.
class ChildFeesScreen extends StatefulWidget {
  const ChildFeesScreen({super.key, required this.user});

  /// Signed-in parent.
  final User user;

  @override
  State<ChildFeesScreen> createState() => _ChildFeesScreenState();
}

class _ChildFeesScreenState extends State<ChildFeesScreen> {
  late Future<List<Student>> _children;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _children = _load();
  }

  Future<List<Student>> _load() async {
    final linked =
        await StudentsRepository().byParentUserAll(widget.user.id);
    final extra = await StudentsRepository().byParentAll(widget.user);
    final seen = <String>{};
    final children = <Student>[];
    for (final s in [...linked, ...extra]) {
      if (seen.add(s.id)) children.add(s);
    }
    return children;
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() => _children = next);
    await next;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Student>>(
      future: _children,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Scaffold(
            appBar: const SvScreenHeader(title: 'My Fees'),
            body: ListView(
              children: [
                SvCardSkeleton(),
                SvListSkeleton(rows: 4),
              ],
            ),
          );
        }
        if (snap.hasError) {
          return Scaffold(
            appBar: const SvScreenHeader(title: 'My Fees'),
            body: SvErrorState(
              message: 'Could not load your children.',
              onRetry: _refresh,
            ),
          );
        }
        final children = snap.data ?? const <Student>[];
        if (children.isEmpty) {
          return const Scaffold(
            appBar: SvScreenHeader(title: 'My Fees'),
            body: SvEmptyState(
              icon: Icons.child_care,
              title: 'No child linked',
              message: 'Ask the school office to link your child so you can '
                  'see their fees and payments.',
            ),
          );
        }
        if (_index >= children.length) _index = children.length - 1;
        final student = children[_index];
        return Scaffold(
          appBar: AppBar(
            title: const Text('My Fees'),
            actions: [
              if (children.length > 1)
                PopupMenuButton<String>(
                  tooltip: '${student.firstName} — switch child',
                  onSelected: (v) {
                    final i = int.tryParse(v);
                    if (i != null) {
                      svHaptic(SvHaptic.selection);
                      setState(() => _index = i);
                    }
                  },
                  itemBuilder: (_) => [
                    for (var i = 0; i < children.length; i++)
                      PopupMenuItem(
                        value: '$i',
                        child: Row(
                          children: [
                            Icon(
                              i == _index
                                  ? Icons.check_circle
                                  : Icons.child_care,
                              size: 18,
                              color: i == _index
                                  ? AppColors.brand
                                  : AppColors.muted,
                            ),
                            const SizedBox(width: 10),
                            Text(children[i].fullName),
                          ],
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.swap_horiz, size: 20),
                        const SizedBox(width: 6),
                        Text(student.firstName),
                        const Icon(Icons.arrow_drop_down),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          body: StudentFeesScreen(
            user: widget.user,
            student: student,
            showAppBar: false,
          ),
        );
      },
    );
  }
}
