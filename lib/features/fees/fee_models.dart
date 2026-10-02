import 'package:flutter/material.dart';

import '../../core/settings/app_settings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';

// ---------------------------------------------------------------------------
// Fee & payment domain models (offline-first).
//
// Money is whole Ghana cedis (GHS) as `int` so balances never drift on float
// arithmetic; every date is a `yyyy-MM-dd` (or `yyyy-MM-dd HH:mm`) string to
// match the rest of the app's records. Every model round-trips through JSON
// so the repository can persist it to SharedPreferences.
// ---------------------------------------------------------------------------

/// Formats [amount] as Ghana cedis with thousands separators, e.g.
/// `GHS 2,350`. Money stays neutral or brand navy in the UI — never
/// green/red; only the final paid/overdue status uses a semantic colour.
String svCedis(int amount) {
  final negative = amount < 0;
  final digits = (negative ? -amount : amount).toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buf.write(',');
    }
    buf.write(digits[i]);
  }
  return '${negative ? '-' : ''}GHS $buf';
}

/// Friendly, human-readable failure for a rejected fee operation. Screens
/// show [message] verbatim — users never need a stack trace.
class FeeException implements Exception {
  FeeException(this.message);

  final String message;

  @override
  String toString() => 'FeeException: $message';
}

/// Aggregated fee position for a school or a single student.
class FeesTotals {
  const FeesTotals({
    required this.billed,
    required this.collected,
    required this.outstanding,
    this.overdueCount = 0,
    this.overdueAmount = 0,
  });

  /// Total invoiced (GHS).
  final int billed;

  /// Total paid so far (GHS).
  final int collected;

  /// Still owed across every invoice (GHS).
  final int outstanding;

  /// How many invoices are past their due date with a balance.
  final int overdueCount;

  /// Outstanding balance sitting on overdue invoices (GHS).
  final int overdueAmount;
}

/// One chargeable fee item (tuition, feeding, levies, exam fees) published
/// for a class or grade in a term.
class FeeStructure {
  const FeeStructure({
    required this.id,
    required this.name,
    required this.classId,
    required this.amount,
    required this.term,
    required this.dueDate,
  });

  final String id;
  final String name;

  /// Class/grade the structure applies to, or [allClasses] for a charge
  /// that applies to every student.
  final String classId;

  /// Amount in GHS.
  final int amount;

  /// Term label, e.g. `Term 1 · 2026/2027`.
  final String term;

  /// Payment due date (`yyyy-MM-dd`).
  final String dueDate;

  /// [classId] value shared by every class.
  static const String allClasses = '*';

  factory FeeStructure.fromJson(Map<String, dynamic> json) => FeeStructure(
        id: json['id'] as String,
        name: json['name'] as String,
        classId: json['classId'] as String,
        amount: (json['amount'] as num).toInt(),
        term: (json['term'] ?? '') as String,
        dueDate: (json['dueDate'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'classId': classId,
        'amount': amount,
        'term': term,
        'dueDate': dueDate,
      };
}

/// One row on an invoice (tuition, feeding, PTA levy…).
class FeeLineItem {
  const FeeLineItem({required this.name, required this.amount});

  final String name;

  /// Amount in GHS.
  final int amount;

  factory FeeLineItem.fromJson(Map<String, dynamic> json) => FeeLineItem(
        name: json['name'] as String,
        amount: (json['amount'] as num).toInt(),
      );

  Map<String, dynamic> toJson() => {'name': name, 'amount': amount};
}

/// Lifecycle of an invoice. Always rendered with a glyph + text label —
/// never colour alone.
enum InvoiceStatus {
  paid('Paid'),
  partial('Partial'),
  overdue('Overdue'),
  due('Due');

  const InvoiceStatus(this.label);

  /// Human label shown next to the icon/glyph.
  final String label;

  static InvoiceStatus fromKey(String key) =>
      InvoiceStatus.values.firstWhere((s) => s.name == key,
          orElse: () => InvoiceStatus.due);
}

/// A bill raised for one student: line items plus payments received so far.
class Invoice {
  const Invoice({
    required this.id,
    required this.studentId,
    required this.issueDate,
    required this.dueDate,
    required this.lineItems,
    required this.term,
    this.amountPaid = 0,
    this.status = InvoiceStatus.due,
  });

  final String id;
  final String studentId;

  /// Raised on (`yyyy-MM-dd`).
  final String issueDate;

  /// Payment due on (`yyyy-MM-dd`).
  final String dueDate;

  final List<FeeLineItem> lineItems;

  /// Term label, e.g. `Term 1 · 2026/2027`.
  final String term;

  /// Running total of payments received (GHS).
  final int amountPaid;

  /// Last resolved status — cached for JSON; use [resolveStatus] for the
  /// live value.
  final InvoiceStatus status;

  /// Sum of [lineItems] (GHS).
  int get total => lineItems.fold(0, (sum, item) => sum + item.amount);

  /// Outstanding balance, never negative (GHS).
  int get balance {
    final b = total - amountPaid;
    return b < 0 ? 0 : b;
  }

  /// Status derived from payments and dates: settled → **paid**; past the
  /// due date with a balance → **overdue**; partially paid → **partial**;
  /// otherwise simply **due**.
  InvoiceStatus resolveStatus({DateTime? now}) {
    if (balance <= 0) return InvoiceStatus.paid;
    final at = now ?? DateTime.now();
    final due = DateTime.tryParse(dueDate);
    if (due != null) {
      final today = DateTime(at.year, at.month, at.day);
      final dueDay = DateTime(due.year, due.month, due.day);
      if (today.isAfter(dueDay)) return InvoiceStatus.overdue;
    }
    if (amountPaid > 0) return InvoiceStatus.partial;
    return InvoiceStatus.due;
  }

  Invoice copyWith({int? amountPaid, InvoiceStatus? status}) => Invoice(
        id: id,
        studentId: studentId,
        issueDate: issueDate,
        dueDate: dueDate,
        lineItems: lineItems,
        term: term,
        amountPaid: amountPaid ?? this.amountPaid,
        status: status ?? this.status,
      );

  factory Invoice.fromJson(Map<String, dynamic> json) => Invoice(
        id: json['id'] as String,
        studentId: json['studentId'] as String,
        issueDate: (json['issueDate'] ?? '') as String,
        dueDate: (json['dueDate'] ?? '') as String,
        lineItems: ((json['lineItems'] ?? const []) as List)
            .map((e) => FeeLineItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        term: (json['term'] ?? '') as String,
        amountPaid: ((json['amountPaid'] ?? 0) as num).toInt(),
        status: InvoiceStatus.fromKey((json['status'] ?? 'due') as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'studentId': studentId,
        'issueDate': issueDate,
        'dueDate': dueDate,
        'lineItems': lineItems.map((e) => e.toJson()).toList(),
        'term': term,
        'amountPaid': amountPaid,
        'status': status.name,
      };
}

/// How a payment was made. Ghana-school reality: mobile money dominates,
/// then cash and bank transfers.
enum PaymentMethod {
  cash('Cash'),
  card('Card'),
  mobileMoney('Mobile Money'),
  bank('Bank Transfer');

  const PaymentMethod(this.label);

  /// Human label shown in chips, rows and receipts.
  final String label;

  static PaymentMethod fromKey(String key) => PaymentMethod.values
      .firstWhere((m) => m.name == key, orElse: () => PaymentMethod.cash);
}

/// One money movement against an invoice. Firm-committed on device first,
/// replayed to the server through the sync outbox when offline.
class Payment {
  const Payment({
    required this.id,
    required this.invoiceId,
    required this.studentId,
    required this.amount,
    required this.method,
    this.reference = '',
    required this.paidAt,
    required this.recordedBy,
  });

  final String id;
  final String invoiceId;

  /// Student the payment is for, taken from the invoice it settles.
  ///
  /// Sent with every recorded payment so the API can scope a read to one
  /// student without resolving the invoice first — the same value the receipt
  /// below already carries. Read back as '' for rows stored before it existed.
  final String studentId;

  /// Amount in GHS.
  final int amount;
  final PaymentMethod method;

  /// Momo ID, cash receipt number, bank trace… may be empty.
  final String reference;

  /// `yyyy-MM-dd HH:mm`.
  final String paidAt;

  final String recordedBy;

  factory Payment.fromJson(Map<String, dynamic> json) => Payment(
        id: json['id'] as String,
        invoiceId: json['invoiceId'] as String,
        studentId: (json['studentId'] ?? '') as String,
        amount: (json['amount'] as num).toInt(),
        method: PaymentMethod.fromKey((json['method'] ?? 'cash') as String),
        reference: (json['reference'] ?? '') as String,
        paidAt: (json['paidAt'] ?? '') as String,
        recordedBy: (json['recordedBy'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'invoiceId': invoiceId,
        'studentId': studentId,
        'amount': amount,
        'method': method.name,
        'reference': reference,
        'paidAt': paidAt,
        'recordedBy': recordedBy,
      };
}

/// Proof of payment issued the moment a [Payment] is committed. Rendered
/// on screen, shared as text and exported as a branded PDF.
class Receipt {
  const Receipt({
    required this.id,
    required this.paymentId,
    required this.invoiceId,
    required this.studentId,
    required this.amount,
    required this.method,
    this.reference = '',
    required this.issuedAt,
    required this.issuedBy,
    required this.balanceAfter,
  });

  final String id;
  final String paymentId;
  final String invoiceId;
  final String studentId;

  /// Amount in GHS.
  final int amount;
  final PaymentMethod method;
  final String reference;

  /// `yyyy-MM-dd HH:mm`.
  final String issuedAt;
  final String issuedBy;

  /// Invoice balance at the moment the receipt was cut (GHS).
  final int balanceAfter;

  factory Receipt.fromJson(Map<String, dynamic> json) => Receipt(
        id: json['id'] as String,
        paymentId: json['paymentId'] as String,
        invoiceId: json['invoiceId'] as String,
        studentId: json['studentId'] as String,
        amount: (json['amount'] as num).toInt(),
        method: PaymentMethod.fromKey((json['method'] ?? 'cash') as String),
        reference: (json['reference'] ?? '') as String,
        issuedAt: (json['issuedAt'] ?? '') as String,
        issuedBy: (json['issuedBy'] ?? '') as String,
        balanceAfter: ((json['balanceAfter'] ?? 0) as num).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'paymentId': paymentId,
        'invoiceId': invoiceId,
        'studentId': studentId,
        'amount': amount,
        'method': method.name,
        'reference': reference,
        'issuedAt': issuedAt,
        'issuedBy': issuedBy,
        'balanceAfter': balanceAfter,
      };
}

// ---------------------------------------------------------------------------
// Presentation helpers shared by the fees screens.
// ---------------------------------------------------------------------------

/// Icon paired with an [InvoiceStatus] label so status is never conveyed
/// by colour alone.
IconData invoiceStatusIcon(InvoiceStatus status) => switch (status) {
      InvoiceStatus.paid => Icons.check_circle,
      InvoiceStatus.partial => Icons.pie_chart_outline,
      InvoiceStatus.overdue => Icons.error_outline,
      InvoiceStatus.due => Icons.schedule,
    };

/// Icon for a payment-method row / chip.
IconData paymentMethodIcon(PaymentMethod method) => switch (method) {
      PaymentMethod.cash => Icons.payments_outlined,
      PaymentMethod.card => Icons.credit_card,
      PaymentMethod.mobileMoney => Icons.phone_iphone,
      PaymentMethod.bank => Icons.account_balance,
    };

/// Status badge (icon + text label + colour) for use on tiles and cards.
/// paid → success ✓, overdue → danger ⚠, partial → brand navy, due → info ○.
Widget invoiceStatusChip(InvoiceStatus status) {
  final Color color = switch (status) {
    InvoiceStatus.paid => AppColors.success,
    InvoiceStatus.partial => AppTheme.brand,
    InvoiceStatus.overdue => AppColors.danger,
    InvoiceStatus.due => AppColors.info,
  };
  return SvStatusBadge(
    label: status.label,
    icon: invoiceStatusIcon(status),
    color: color,
  );
}

/// Staggered entrance for list rows — collapses to the plain child when the
/// user turned on Reduce motion or Data saver in Settings.
Widget feesEntrance(int index, Widget child) {
  if (AppSettings.instance.motionOff) return child;
  return SvEntrance(
    delay: Duration(milliseconds: 40 * index.clamp(0, 10)),
    child: child,
  );
}
