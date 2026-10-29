import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/student.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../students/students_repository.dart';
import 'fee_models.dart';
import 'fees_pdf.dart';
import 'fees_repository.dart';

// ---------------------------------------------------------------------------
// Invoice detail: line items, totals, payment history, the Record-payment
// bottom sheet (firm commit + haptics) and receipt viewing/sharing.
// ---------------------------------------------------------------------------

/// One successful load of the invoice detail screen.
typedef _DetailData = ({
  Invoice? invoice,
  Student? student,
  List<Payment> payments,
  List<Receipt> receipts,
});

/// Result popped by the record-payment sheet after a firm commit.
typedef _PaymentResult = ({Invoice invoice, Payment payment, Receipt receipt});

/// One invoice in full: student facts, line items, totals, payment history
/// and receipt sharing. When [canRecord] is true (staff at the till) a
/// **Record payment** sheet commits payments offline-first — local store
/// first, then audit, parent notification and sync outbox.
class InvoiceDetailScreen extends StatefulWidget {
  const InvoiceDetailScreen({
    super.key,
    required this.invoiceId,
    required this.canRecord,
    this.recordedBy = '',
  });

  /// Id of the invoice to display.
  final String invoiceId;

  /// Whether to show the Record payment action (staff only).
  final bool canRecord;

  /// Name recorded on new payments (the signed-in staff member).
  final String recordedBy;

  @override
  State<InvoiceDetailScreen> createState() => _InvoiceDetailScreenState();
}

class _InvoiceDetailScreenState extends State<InvoiceDetailScreen> {
  late Future<_DetailData> _data;

  /// Last successful load, reused after the payment sheet commits.
  _DetailData? _cached;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_DetailData> _load() async {
    final repo = FeesRepository();
    final invoice = await repo.invoiceById(widget.invoiceId);
    if (invoice == null) {
      final missing = (
        invoice: null,
        student: null,
        payments: const <Payment>[],
        receipts: const <Receipt>[],
      );
      _cached = missing;
      return missing;
    }
    Student? student;
    try {
      student = await StudentsRepository().byId(invoice.studentId);
    } catch (e) {
      debugPrint('[Fees] student lookup failed: $e');
      student = null;
    }
    final payments = await repo.paymentsForInvoice(invoice.id);
    final receipts = await repo.receiptsForInvoice(invoice.id);
    final data = (
      invoice: invoice,
      student: student,
      payments: payments,
      receipts: receipts,
    );
    _cached = data;
    return data;
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() => _data = next);
    await next;
  }

  Future<void> _openRecordSheet(Invoice invoice) async {
    final result = await showModalBottomSheet<_PaymentResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RecordPaymentSheet(
        invoice: invoice,
        recordedBy: widget.recordedBy,
      ),
    );
    if (!mounted) return;
    setState(() => _data = _load());
    if (result == null) return;
    svSnack(
      context,
      'Payment recorded. Receipt ${result.receipt.id} issued.',
    );
    final student = _cached?.student;
    final cachedInvoice = _cached?.invoice;
    if (student != null && cachedInvoice != null) {
      await _openReceipt(result.receipt, cachedInvoice, student);
    }
  }

  Future<void> _openReceipt(Receipt receipt, Invoice invoice, Student? student) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _ReceiptSheet(
          receipt: receipt,
          invoice: invoice,
          student: student,
        ),
      );

  void _tapPayment(Receipt? receipt, Invoice invoice, Student? student) {
    if (receipt == null) return;
    svHaptic(SvHaptic.light);
    _openReceipt(receipt, invoice, student);
  }

  Future<void> _shareStatement(Invoice invoice, Student student) async {
    try {
      final pdf = FeesPdf();
      final bytes = await pdf.invoicePdf(
        invoice: invoice,
        student: student,
        payments: _cached?.payments ?? const <Payment>[],
      );
      await pdf.saveAndShare(bytes, 'Invoice-${invoice.id}');
      svHaptic(SvHaptic.medium);
    } catch (e) {
      debugPrint('[Fees] statement share failed: $e');
      if (!mounted) return;
      svSnack(context, 'Could not build the statement PDF.', error: true);
    }
  }

  Receipt? _receiptFor(List<Receipt> receipts, String paymentId) {
    for (final r in receipts) {
      if (r.paymentId == paymentId) return r;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(
        title: 'Invoice',
        subtitle: widget.invoiceId,
      ),
      body: FutureBuilder<_DetailData>(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return ListView(
              children: [
                SvCardSkeleton(lines: 5),
                SvListSkeleton(rows: 4),
              ],
            );
          }
          if (snap.hasError) {
            return SvErrorState(
              message: 'Could not load this invoice.',
              onRetry: _refresh,
            );
          }
          final data = snap.data;
          final invoice = data?.invoice;
          if (data == null || invoice == null) {
            return const SvEmptyState(
              icon: Icons.receipt_long,
              title: 'Invoice not found',
              message: 'It may have been removed. Go back and pull to '
                  'refresh the list.',
            );
          }
          final student = data.student;
          final status = invoice.resolveStatus();
          return SvRefresh(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                // --- Facts + status -----------------------------------
                Container(
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
                          invoiceStatusChip(status),
                          const Spacer(),
                          Flexible(
                            child: Text(
                              invoice.id,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _fact('Student', student?.fullName ?? invoice.studentId),
                      _fact('Class', student?.classId ?? '—'),
                      _fact('Admission No.', student?.admissionNo ?? '—'),
                      _fact('Term', invoice.term),
                      _fact('Issued', invoice.issueDate),
                      _fact('Due', invoice.dueDate),
                    ],
                  ),
                ),

                // --- Line items + totals -------------------------------
                const SvSectionTitle('Line items'),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    children: [
                      for (final item in invoice.lineItems)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  item.name,
                                  style: const TextStyle(fontSize: 13.5),
                                ),
                              ),
                              Text(
                                svCedis(item.amount),
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
                      const Divider(height: 1),
                      const SizedBox(height: 8),
                      _moneyLine('Total', invoice.total, bold: true),
                      _moneyLine('Paid', invoice.amountPaid),
                      _moneyLine(
                        'Balance',
                        invoice.balance,
                        bold: true,
                        navy: true,
                      ),
                    ],
                  ),
                ),

                // --- Payment history -----------------------------------
                const SvSectionTitle('Payment history'),
                if (data.payments.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Text(
                      'No payments recorded yet.',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.muted,
                      ),
                    ),
                  )
                else
                  for (var i = 0; i < data.payments.length; i++)
                    feesEntrance(
                      i,
                      SvPressScale(
                        child: _paymentTile(
                          data.payments[i],
                          data.receipts,
                          invoice,
                          student,
                        ),
                      ),
                    ),

                // --- Actions -------------------------------------------
                if (widget.canRecord && invoice.balance > 0) ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: FilledButton.icon(
                      onPressed: () => _openRecordSheet(invoice),
                      icon: const Icon(Icons.add_card),
                      label: const Text('Record payment'),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: OutlinedButton.icon(
                    onPressed: student == null
                        ? null
                        : () => _shareStatement(invoice, student),
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('Share statement (PDF)'),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _fact(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 116,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.muted,
                ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _moneyLine(String label, int amount, {bool bold = false, bool navy = false}) {
    final style = TextStyle(
      fontSize: bold ? 14 : 13,
      fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
      color: navy ? AppColors.brand : AppColors.ink,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: bold
                  ? const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)
                  : TextStyle(fontSize: 13, color: AppColors.muted),
            ),
          ),
          Text(svCedis(amount), style: style),
        ],
      ),
    );
  }

  Widget _paymentTile(
    Payment payment,
    List<Receipt> receipts,
    Invoice invoice,
    Student? student,
  ) {
    final receipt = _receiptFor(receipts, payment.id);
    final reference =
        payment.reference.isEmpty ? '' : ' · ${payment.reference}';
    return SvAvatarTile(
      title: '${svCedis(payment.amount)} · ${payment.method.label}',
      meta: '${payment.paidAt} · ${payment.recordedBy}$reference',
      icon: paymentMethodIcon(payment.method),
      avatarColor: AppTheme.brand,
      onTap: () => _tapPayment(receipt, invoice, student),
    );
  }
}

// ---------------------------------------------------------------------------
// Record payment bottom sheet
// ---------------------------------------------------------------------------

/// Bottom sheet that firm-commits a payment: amount + method chips +
/// optional reference, then `FeesRepository.recordPayment` (local commit
/// first, side effects swallowed) with a firm haptic on success.
class _RecordPaymentSheet extends StatefulWidget {
  const _RecordPaymentSheet({
    required this.invoice,
    required this.recordedBy,
  });

  final Invoice invoice;
  final String recordedBy;

  @override
  State<_RecordPaymentSheet> createState() => _RecordPaymentSheetState();
}

class _RecordPaymentSheetState extends State<_RecordPaymentSheet> {
  late final TextEditingController _amount = TextEditingController(
    text: widget.invoice.balance.toString(),
  );
  final TextEditingController _reference = TextEditingController();
  PaymentMethod _method = PaymentMethod.mobileMoney;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    final amount = int.tryParse(_amount.text.trim()) ?? 0;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final result = await FeesRepository().recordPayment(
        invoiceId: widget.invoice.id,
        amount: amount,
        method: _method,
        reference: _reference.text,
        recordedBy: widget.recordedBy,
      );
      if (!mounted) return;
      svHaptic(SvHaptic.medium);
      Navigator.pop(context, result);
    } on FeeException catch (e) {
      if (!mounted) return;
      svHaptic(SvHaptic.error);
      svSnack(context, e.message, error: true);
      setState(() => _busy = false);
    } catch (e) {
      debugPrint('[Fees] record payment failed: $e');
      if (!mounted) return;
      svHaptic(SvHaptic.error);
      svSnack(
        context,
        'Could not record the payment. Please try again.',
        error: true,
      );
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(24),
          ),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(Icons.add_card, color: AppColors.brand),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Record payment',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  invoiceStatusChip(widget.invoice.resolveStatus()),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Outstanding balance ${svCedis(widget.invoice.balance)}',
                style: TextStyle(fontSize: 13, color: AppColors.muted),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _amount,
                enabled: !_busy,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: false),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Amount (GHS)',
                  prefixIcon: Icon(Icons.payments_outlined),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Method',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 8),
              SvFilterChips(
                padding: EdgeInsets.zero,
                options: [
                  for (final m in PaymentMethod.values)
                    SvFilterOption(m.label, selected: _method == m),
                ],
                onSelected: (i) {
                  svHaptic(SvHaptic.selection);
                  setState(() => _method = PaymentMethod.values[i]);
                },
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _reference,
                enabled: !_busy,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Reference (optional)',
                  hintText: 'Momo ID, cash receipt no., trace…',
                  prefixIcon: Icon(Icons.tag),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _busy ? null : _commit,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle_outline),
                label: Text(_busy ? 'Recording…' : 'Record payment'),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Receipt view
// ---------------------------------------------------------------------------

/// Receipt for one committed payment: facts, share-as-PDF (branded) and
/// share-as-text. The PDF action is hidden when the student record is
/// unavailable; every failure is caught and surfaced as a snack, never a
/// crash.
class _ReceiptSheet extends StatefulWidget {
  const _ReceiptSheet({
    required this.receipt,
    required this.invoice,
    this.student,
  });

  final Receipt receipt;
  final Invoice invoice;
  final Student? student;

  @override
  State<_ReceiptSheet> createState() => _ReceiptSheetState();
}

class _ReceiptSheetState extends State<_ReceiptSheet> {
  bool _busy = false;

  Future<void> _sharePdf() async {
    if (_busy) return;
    setState(() => _busy = true);
    final student = widget.student;
    if (student == null) {
      setState(() => _busy = false);
      return;
    }
    try {
      final pdf = FeesPdf();
      final bytes = await pdf.receiptPdf(
        receipt: widget.receipt,
        invoice: widget.invoice,
        student: student,
      );
      await pdf.saveAndShare(bytes, 'Receipt-${widget.receipt.id}');
      svHaptic(SvHaptic.medium);
    } catch (e) {
      debugPrint('[Fees] receipt PDF share failed: $e');
      if (mounted) {
        svSnack(context, 'Could not share the receipt PDF.', error: true);
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _shareText() async {
    final r = widget.receipt;
    final text = 'Payment receipt ${r.id}\n'
        'Student: ${widget.student?.fullName ?? r.studentId}\n'
        'Invoice: ${r.invoiceId}\n'
        'Amount: ${svCedis(r.amount)}\n'
        'Method: ${r.method.label}\n'
        'Paid on: ${r.issuedAt}\n'
        'Recorded by: ${r.issuedBy}\n'
        'Balance after payment: ${svCedis(r.balanceAfter)}';
    try {
      await FeesPdf().shareText(text, title: 'Receipt ${r.id}');
    } catch (e) {
      debugPrint('[Fees] receipt text share failed: $e');
      if (mounted) {
        svSnack(context, 'Could not open the share sheet.', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.receipt;
    final balanceStatus = r.balanceAfter == 0
        ? svStatus('Invoice settled', Icons.check_circle, AppColors.success)
        : svStatus(
            'Balance now ${svCedis(r.balanceAfter)}',
            Icons.schedule,
            AppColors.info,
          );
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(24),
          ),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(Icons.receipt_long, color: AppColors.brand),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Payment receipt',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  invoiceStatusChip(widget.invoice.resolveStatus()),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                svCedis(r.amount),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: AppColors.brand,
                ),
              ),
              const SizedBox(height: 4),
              Center(child: balanceStatus),
              const SizedBox(height: 14),
              _fact('Student', widget.student?.fullName ?? r.studentId),
              _fact('Invoice', r.invoiceId),
              _fact('Method', r.method.label),
              _fact('Paid on', r.issuedAt),
              _fact('Reference', r.reference.isEmpty ? '—' : r.reference),
              _fact('Recorded by', r.issuedBy),
              _fact('Receipt no.', r.id),
              const SizedBox(height: 18),
              if (widget.student != null)
                FilledButton.icon(
                  onPressed: _busy ? null : _sharePdf,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.picture_as_pdf),
                  label: Text(_busy ? 'Preparing…' : 'Share PDF'),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _shareText,
                icon: const Icon(Icons.share),
                label: const Text('Share text'),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fact(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 116,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.muted,
                ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
}
