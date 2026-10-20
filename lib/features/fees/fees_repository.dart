import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/api_client.dart';
import '../../core/models/app_notification.dart';
import '../../core/models/school_term.dart';
import '../../core/models/student.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/connectivity_monitor.dart';
import '../../core/sync/sync_queue.dart';
import '../audit/audit_repository.dart';
import '../notifications/notifications_repository.dart';
import 'fee_models.dart';

// ---------------------------------------------------------------------------
// Offline-first fees store + repository.
//
// One JSON document (`solvanta.fees_v1`) holds fee structures, invoices,
// payments and receipts. First read seeds it from the 8 existing students in
// `LocalStore` so the module has believable data with zero setup. Every write
// lands in SharedPreferences first (firm commit) with an in-memory fallback,
// so a broken/unavailable prefs store can never take the UI down.
// ---------------------------------------------------------------------------

/// The whole fees document. Lists are mutated in place and re-persisted by
/// [FeesRepository], which keeps the in-memory mirror in step on every write.
class FeesStore {
  FeesStore({
    List<FeeStructure>? structures,
    List<Invoice>? invoices,
    List<Payment>? payments,
    List<Receipt>? receipts,
  })  : structures = structures ?? <FeeStructure>[],
        invoices = invoices ?? <Invoice>[],
        payments = payments ?? <Payment>[],
        receipts = receipts ?? <Receipt>[];

  /// Chargeable fee items published for classes / the whole school.
  List<FeeStructure> structures;

  /// Bills raised for students.
  List<Invoice> invoices;

  /// Every payment received, newest last.
  List<Payment> payments;

  /// Every receipt cut for a payment.
  List<Receipt> receipts;

  factory FeesStore.fromJson(Map<String, dynamic> json) => FeesStore(
        structures: ((json['structures'] ?? const []) as List)
            .map((e) => FeeStructure.fromJson(e as Map<String, dynamic>))
            .toList(),
        invoices: ((json['invoices'] ?? const []) as List)
            .map((e) => Invoice.fromJson(e as Map<String, dynamic>))
            .toList(),
        payments: ((json['payments'] ?? const []) as List)
            .map((e) => Payment.fromJson(e as Map<String, dynamic>))
            .toList(),
        receipts: ((json['receipts'] ?? const []) as List)
            .map((e) => Receipt.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'structures': structures.map((e) => e.toJson()).toList(),
        'invoices': invoices.map((e) => e.toJson()).toList(),
        'payments': payments.map((e) => e.toJson()).toList(),
        'receipts': receipts.map((e) => e.toJson()).toList(),
      };
}

/// Reads and writes fee structures, invoices, payments and receipts.
///
/// Pattern follows `StudentsRepository` / `AttendanceRepository`: construct
/// freely (`FeesRepository()`), every method is async and seed-on-first-load.
/// [recordPayment] is the only mutation and is *firm-commit*: the payment is
/// persisted locally before anything else happens, then audited, pushed to
/// the linked parent, and mirrored to the backend (or the sync outbox when
/// offline) — all side effects wrapped so a platform/network failure can
/// never surface as a crash.
class FeesRepository {
  FeesRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  /// SharedPreferences key for the fees document.
  static const String storageKey = 'solvanta.fees_v1';

  /// Outbox kind for a captured payment (see `SyncQueue`).
  static const String paymentSyncKind = 'payment.record';

  /// Backend endpoint a queued payment is replayed to.
  static const String paymentPath = '/api/payments';

  /// Bursar name used for seeded payments/receipts.
  static const String _seededBy = 'Mrs. Adjoa Amankwah (Bursar)';

  /// In-memory mirror: the last successfully read/written document. Used
  /// whenever SharedPreferences itself fails, so reads and the firm commit
  /// keep working for the rest of the session.
  FeesStore _memory = FeesStore();
  var _memoryUsable = false;

  // ---------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------

  /// Every published fee structure.
  Future<List<FeeStructure>> structures() async =>
      List<FeeStructure>.unmodifiable((await _read()).structures);

  /// Structures that apply to [classId]: its own plus school-wide ones.
  Future<List<FeeStructure>> structuresForClass(String classId) async {
    final all = await structures();
    return all
        .where((f) => f.classId == classId || f.classId == FeeStructure.allClasses)
        .toList();
  }

  /// Structures that apply to [student]: their class's plus school-wide ones.
  Future<List<FeeStructure>> structuresForStudent(Student student) =>
      structuresForClass(student.classId);

  /// Every invoice in the school, oldest issued first.
  Future<List<Invoice>> invoices() async {
    final list = List<Invoice>.of((await _read()).invoices);
    list.sort((a, b) => a.issueDate.compareTo(b.issueDate));
    return list;
  }

  /// Invoices raised for one student (newest issued first for lists).
  Future<List<Invoice>> invoicesForStudent(String studentId) async {
    final list = (await invoices())
        .where((i) => i.studentId == studentId)
        .toList();
    list.sort((a, b) => b.issueDate.compareTo(a.issueDate));
    return list;
  }

  /// One invoice by id, or null when it does not exist.
  Future<Invoice?> invoiceById(String id) async {
    for (final invoice in await invoices()) {
      if (invoice.id == id) return invoice;
    }
    return null;
  }

  /// Payments recorded against [invoiceId], newest first.
  Future<List<Payment>> paymentsForInvoice(String invoiceId) async {
    final list = (await _read())
        .payments
        .where((p) => p.invoiceId == invoiceId)
        .toList();
    list.sort((a, b) => b.paidAt.compareTo(a.paidAt));
    return list;
  }

  /// Receipts cut for [invoiceId], newest first.
  Future<List<Receipt>> receiptsForInvoice(String invoiceId) async {
    final list = (await _read())
        .receipts
        .where((r) => r.invoiceId == invoiceId)
        .toList();
    list.sort((a, b) => b.issuedAt.compareTo(a.issuedAt));
    return list;
  }

  /// The receipt issued for one payment, if any.
  Future<Receipt?> receiptForPayment(String paymentId) async {
    for (final receipt in (await _read()).receipts) {
      if (receipt.paymentId == paymentId) return receipt;
    }
    return null;
  }

  /// Latest receipt cut for an invoice (the one to show after a payment).
  Future<Receipt?> latestReceiptFor(String invoiceId) async {
    final list = await receiptsForInvoice(invoiceId);
    return list.isEmpty ? null : list.first;
  }

  /// Whole-school position: billed, collected, outstanding + overdue figures.
  Future<FeesTotals> schoolTotals() async =>
      _totalsFor((await _read()).invoices);

  /// One student's position across their invoices.
  Future<FeesTotals> totalsForStudent(String studentId) async => _totalsFor(
      (await _read()).invoices.where((i) => i.studentId == studentId));

  // ---------------------------------------------------------------------
  // Record payment — the one mutation
  // ---------------------------------------------------------------------

  /// Firm-commits [amount] against [invoiceId] and issues a receipt.
  ///
  /// Order of operations (nothing is left half-done):
  /// 1. Validate — throws [FeeException] with a human message on bad input.
  /// 2. Persist — invoice, payment and receipt are written to the local
  ///    store first; this is the commit of record.
  /// 3. Side effects (each failure-swallowed): audit entry, parent
  ///    notification, backend mirror or sync-outbox capture when offline.
  Future<({Invoice invoice, Payment payment, Receipt receipt})> recordPayment({
    required String invoiceId,
    required int amount,
    required PaymentMethod method,
    String reference = '',
    required String recordedBy,
  }) async {
    final store = await _read();

    Invoice? invoice;
    for (final candidate in store.invoices) {
      if (candidate.id == invoiceId) {
        invoice = candidate;
        break;
      }
    }
    if (invoice == null) {
      throw FeeException('That invoice could not be found.');
    }
    if (amount <= 0) {
      throw FeeException('Enter an amount greater than GHS 0.');
    }
    final balance = invoice.balance;
    if (balance <= 0) {
      throw FeeException('This invoice is already fully paid.');
    }
    if (amount > balance) {
      throw FeeException(
          'Payment is more than the outstanding balance of ${svCedis(balance)}.');
    }

    final now = DateTime.now();
    final updated = invoice.copyWith(amountPaid: invoice.amountPaid + amount);
    final payment = Payment(
      id: 'PAY-${now.millisecondsSinceEpoch}',
      invoiceId: invoice.id,
      studentId: invoice.studentId,
      amount: amount,
      method: method,
      reference: reference.trim(),
      paidAt: _stamp(now),
      recordedBy: recordedBy.trim().isEmpty ? 'School Staff' : recordedBy.trim(),
    );
    final receipt = Receipt(
      id: 'RCT-${now.millisecondsSinceEpoch}',
      paymentId: payment.id,
      invoiceId: invoice.id,
      studentId: invoice.studentId,
      amount: amount,
      method: method,
      reference: payment.reference,
      issuedAt: payment.paidAt,
      issuedBy: payment.recordedBy,
      balanceAfter: updated.balance,
    );

    // --- Firm commit: local store first, in-memory mirror alongside ----
    store.invoices[store.invoices.indexOf(invoice)] = updated;
    store.payments.add(payment);
    store.receipts.add(receipt);
    await _write(store);

    // --- Side effects: never allowed to fail the committed payment ----
    await _audit(updated, payment, receipt);
    await _notifyParent(updated, payment, receipt);
    await _syncPayment(payment);

    return (invoice: updated, payment: payment, receipt: receipt);
  }

  /// Replaces invoices and payments with the server's copies (fee
  /// structures stay local) and cuts a receipt for any payment that has none
  /// yet, e.g. one recorded on another device. Called by `ServerSync` only
  /// when the outbox is empty, so no local payment is still unsent.
  Future<void> mirrorFromServer({
    required List<Invoice> invoices,
    required List<Payment> payments,
  }) async {
    final store = await _read();
    final existing = {for (final r in store.receipts) r.paymentId: r};
    final byInvoice = {for (final i in invoices) i.id: i};
    final sorted = [...payments]..sort((a, b) => a.paidAt.compareTo(b.paidAt));
    final paidSoFar = <String, int>{};
    final receipts = <Receipt>[];
    for (final p in sorted) {
      final paid = (paidSoFar[p.invoiceId] ?? 0) + p.amount;
      paidSoFar[p.invoiceId] = paid;
      final mine = existing[p.id];
      if (mine != null) {
        receipts.add(mine);
        continue;
      }
      final total = byInvoice[p.invoiceId]?.total ?? paid;
      receipts.add(Receipt(
        id: 'RCT-${p.id}',
        paymentId: p.id,
        invoiceId: p.invoiceId,
        studentId: p.studentId,
        amount: p.amount,
        method: p.method,
        reference: p.reference,
        issuedAt: p.paidAt,
        issuedBy: p.recordedBy,
        balanceAfter: (total - paid).clamp(0, total),
      ));
    }
    store
      ..invoices = invoices
      ..payments = sorted
      ..receipts = receipts;
    await _write(store);
  }

  // ---------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------

  Future<FeesTotals> _totalsFor(Iterable<Invoice> list) async {
    final now = DateTime.now();
    var billed = 0;
    var collected = 0;
    var outstanding = 0;
    var overdueCount = 0;
    var overdueAmount = 0;
    for (final invoice in list) {
      billed += invoice.total;
      collected += invoice.amountPaid;
      outstanding += invoice.balance;
      if (invoice.resolveStatus(now: now) == InvoiceStatus.overdue) {
        overdueCount += 1;
        overdueAmount += invoice.balance;
      }
    }
    return FeesTotals(
      billed: billed,
      collected: collected,
      outstanding: outstanding,
      overdueCount: overdueCount,
      overdueAmount: overdueAmount,
    );
  }

  /// Reads the document, seeding it on first use. Falls back to the
  /// in-memory mirror when SharedPreferences is unavailable or corrupt.
  Future<FeesStore> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) {
        final seeded = await _seed();
        await _persist(seeded);
        _memory = seeded;
        _memoryUsable = true;
        return seeded;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('fees store is not a JSON object');
      }
      final store = FeesStore.fromJson(decoded);
      _memory = store;
      _memoryUsable = true;
      return store;
    } catch (e) {
      // A corrupt or unreachable store must never break the screen: seed
      // into memory once, then keep serving (and writing) that copy.
      debugPrint('[Fees] store read failed (serving in-memory copy): $e');
      if (!_memoryUsable) {
        _memory = await _seedSafe();
        _memoryUsable = true;
      }
      return _memory;
    }
  }

  /// Persists [store] and updates the in-memory mirror. A failed write is
  /// logged and tolerated — the mirror keeps the session coherent.
  Future<void> _write(FeesStore store) async {
    _memory = store;
    _memoryUsable = true;
    try {
      await _persist(store);
    } catch (e) {
      debugPrint('[Fees] persist failed (kept in memory): $e');
    }
  }

  Future<void> _persist(FeesStore store) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(store.toJson()));
  }

  /// Seeding seeds: fee structures + one invoice per existing seed student.
  Future<FeesStore> _seed() async {
    final students = await _seedStudents();
    final term = await _seedTerm();
    return _buildSeed(students, term);
  }

  /// Students for seeding, falling back to none if the store misbehaves.
  Future<List<Student>> _seedStudents() async {
    try {
      return await _store.loadStudents();
    } catch (e) {
      debugPrint('[Fees] cannot load students for seeding: $e');
      return const <Student>[];
    }
  }

  /// Active term for seeding, falling back if the store misbehaves.
  Future<SchoolTerm> _seedTerm() async {
    try {
      return await _store.loadTerm();
    } catch (e) {
      debugPrint('[Fees] cannot load term for seeding: $e');
      return SchoolTerm.fallback;
    }
  }

  /// Seeding that survives even a fully broken prefs store (no students).
  Future<FeesStore> _seedSafe() async {
    try {
      return await _seed();
    } catch (e) {
      debugPrint('[Fees] seed failed (starting empty): $e');
      return FeesStore();
    }
  }

  FeesStore _buildSeed(List<Student> students, SchoolTerm term) {
    final termLabel = term.label;
    final issueDate = term.start;
    final dueDate = _shiftDate(term.start, 30);

    // Per-class tuition + levies charged to every student (doc seed plan).
    const tuitionByClass = <String, int>{
      'JHS1A': 1450,
      'JHS1B': 1450,
      'JHS2A': 1550,
      'JHS2B': 1550,
      'JHS3A': 1700,
      'JHS3B': 1700,
    };
    final structures = <FeeStructure>[
      for (final entry in tuitionByClass.entries)
        FeeStructure(
          id: 'FEE-TUITION-${entry.key}',
          name: 'Tuition — ${entry.key}',
          classId: entry.key,
          amount: entry.value,
          term: termLabel,
          dueDate: dueDate,
        ),
      FeeStructure(
        id: 'FEE-FEEDING',
        name: 'Feeding levy',
        classId: FeeStructure.allClasses,
        amount: 450,
        term: termLabel,
        dueDate: dueDate,
      ),
      FeeStructure(
        id: 'FEE-PTA',
        name: 'PTA levy',
        classId: FeeStructure.allClasses,
        amount: 200,
        term: termLabel,
        dueDate: dueDate,
      ),
      FeeStructure(
        id: 'FEE-EXAM',
        name: 'Exam fee',
        classId: FeeStructure.allClasses,
        amount: 150,
        term: termLabel,
        dueDate: dueDate,
      ),
    ];

    final schoolWide = structures
        .where((f) => f.classId == FeeStructure.allClasses)
        .toList();
    final invoices = <Invoice>[];
    final payments = <Payment>[];
    final receipts = <Receipt>[];

    for (final (index, student) in students.indexed) {
      final tuition = tuitionByClass[student.classId];
      final lineItems = <FeeLineItem>[
        if (tuition != null)
          FeeLineItem(name: 'Tuition — ${student.classId}', amount: tuition),
        for (final fee in schoolWide)
          FeeLineItem(name: fee.name, amount: fee.amount),
      ];
      if (lineItems.isEmpty) continue;

      // Rotate through the four states so every status is representable:
      // 0 paid · 1 partial · 2 overdue (due already passed) · 3 due.
      final pattern = index % 4;
      final invoiceDue = pattern == 2 ? _shiftDate(issueDate, 10) : dueDate;
      final invoice = Invoice(
        id: 'INV-${_termCode(term)}-${student.id}',
        studentId: student.id,
        issueDate: issueDate,
        dueDate: invoiceDue,
        lineItems: lineItems,
        term: termLabel,
      );

      var paid = 0;
      if (pattern == 0) {
        paid = invoice.total;
      } else if (pattern == 1) {
        paid = (invoice.total * 60) ~/ 100;
      }

      if (paid > 0) {
        final settled = invoice.copyWith(amountPaid: paid);
        final paidOn = _shiftDate(issueDate, (index % 7) + 1);
        final payment = Payment(
          id: 'PAY-SEED-${student.id}',
          invoiceId: invoice.id,
          studentId: student.id,
          amount: paid,
          method: pattern == 0 ? PaymentMethod.mobileMoney : PaymentMethod.cash,
          reference: pattern == 0 ? 'MOMO-${index + 1}00' : 'CASH-${index + 1}00',
          paidAt: '$paidOn 10:30',
          recordedBy: _seededBy,
        );
        payments.add(payment);
        receipts.add(Receipt(
          id: 'RCT-SEED-${student.id}',
          paymentId: payment.id,
          invoiceId: invoice.id,
          studentId: student.id,
          amount: paid,
          method: payment.method,
          reference: payment.reference,
          issuedAt: payment.paidAt,
          issuedBy: _seededBy,
          balanceAfter: settled.balance,
        ));
        invoices.add(settled);
      } else {
        invoices.add(invoice);
      }
    }

    return FeesStore(
      structures: structures,
      invoices: invoices,
      payments: payments,
      receipts: receipts,
    );
  }

  // --- Side effects (each one failure-swallowed) -------------------------

  Future<void> _audit(
      Invoice invoice, Payment payment, Receipt receipt) async {
    try {
      await AuditRepository(store: _store).log(
        action: 'fee.payment',
        actor: payment.recordedBy,
        target: invoice.id,
        detail:
            '${svCedis(payment.amount)} received via ${payment.method.label} '
            '· receipt ${receipt.id} · balance ${svCedis(invoice.balance)}',
        reason: payment.reference.isEmpty ? null : payment.reference,
      );
    } catch (e) {
      debugPrint('[Fees] audit write failed: $e');
    }
  }

  Future<void> _notifyParent(
      Invoice invoice, Payment payment, Receipt receipt) async {
    try {
      final students = await _store.loadStudents();
      Student? student;
      for (final candidate in students) {
        if (candidate.id == invoice.studentId) {
          student = candidate;
          break;
        }
      }
      final parentId = student?.parentUserId;
      if (parentId == null || parentId.isEmpty) return;
      await NotificationsRepository(store: _store).push(
        kind: NotificationKind.system,
        title: 'Payment received — ${student?.fullName ?? invoice.studentId}',
        body: '${svCedis(payment.amount)} received via '
            '${payment.method.label}. Balance ${svCedis(invoice.balance)}. '
            'Receipt ${receipt.id}.',
        userId: parentId,
        studentId: invoice.studentId,
      );
    } catch (e) {
      debugPrint('[Fees] parent notification failed: $e');
    }
  }

  /// Mirrors the payment to the backend — or parks it in the sync outbox
  /// when offline — per the `SyncQueue` / `ApiClient` replay contract.
  /// Never throws: the payment is already committed locally.
  Future<void> _syncPayment(Payment payment) async {
    try {
      if (!ApiClient.isConfigured) {
        // Local-only build: the store is authoritative, nothing to push to.
        return;
      }
      final online = await ConnectivityMonitor.instance.isOnline;
      if (!online) {
        // Explicit, idempotent outbox capture (id = payment id). `ApiClient`
        // registered the replay handler at startup, so this re-issues
        // `POST /api/payments` verbatim when connectivity returns.
        await SyncQueue.instance.enqueue(
          paymentSyncKind,
          {
            'method': 'POST',
            'path': paymentPath,
            'body': payment.toJson(),
            'paymentId': payment.id,
          },
          id: payment.id,
        );
        return;
      }
      try {
        await ApiClient().request(
          'POST',
          paymentPath,
          body: payment.toJson(),
          syncKind: paymentSyncKind,
          syncPayload: {'paymentId': payment.id},
        );
      } on ApiException catch (e) {
        // Network failure → ApiClient already queued it; a 4xx rejection
        // leaves the local commit as the record of truth. Either way the
        // cashier's screen must not crash.
        debugPrint('[Fees] payment ${payment.id} not acknowledged: $e');
      }
    } catch (e) {
      debugPrint('[Fees] payment sync failed (local commit stands): $e');
    }
  }

  // --- Small date helpers ------------------------------------------------

  String _stamp(DateTime n) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${p(n.month)}-${p(n.day)} ${p(n.hour)}:${p(n.minute)}';
  }

  /// `yyyy-MM-dd` shifted by [days]; returns [base] unchanged when it is
  /// not a parseable date.
  String _shiftDate(String base, int days) {
    final d = DateTime.tryParse(base);
    if (d == null) return base;
    final shifted = d.add(Duration(days: days));
    String p(int v) => v.toString().padLeft(2, '0');
    return '${shifted.year}-${p(shifted.month)}-${p(shifted.day)}';
  }

  /// Short invoice-key segment for a term, e.g. `2026T1` for `Term 1 ·
  /// 2026/2027`.
  String _termCode(SchoolTerm term) {
    final year = term.year.split('/').first;
    final digits = term.name.replaceAll(RegExp(r'[^0-9]'), '');
    return '$year${digits.isEmpty ? 'T' : 'T$digits'}';
  }
}
