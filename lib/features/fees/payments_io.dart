import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../../core/models/student.dart';
import 'fee_models.dart';

/// Template generation, upload parsing and preview validation for **bulk
/// payment recording**. SOLVANTA never takes money: a school collects fees its
/// own way (cash, mobile money, bank), then records what was received here —
/// one by one from the fees screen, or many at once from a filled-in CSV/XLSX.
///
/// Pure (no Flutter, no I/O) so it is unit-testable. Each row is matched to a
/// student (id first, admission number second — never name) and to one of that
/// student's outstanding invoices.

const List<String> paymentColumns = [
  'studentId',
  'admissionNo',
  'studentName',
  'invoiceId',
  'amount',
  'method',
  'reference',
];

enum PaymentRowStatus { valid, warning, error }

class PaymentUploadRow {
  final String studentId;
  final String admissionNo;
  final String studentName;
  final String invoiceId;
  final String amountText;
  final String methodText;
  final String reference;

  const PaymentUploadRow({
    this.studentId = '',
    this.admissionNo = '',
    this.studentName = '',
    this.invoiceId = '',
    this.amountText = '',
    this.methodText = '',
    this.reference = '',
  });

  bool get isBlank =>
      studentId.isEmpty &&
      admissionNo.isEmpty &&
      studentName.isEmpty &&
      invoiceId.isEmpty &&
      amountText.isEmpty &&
      methodText.isEmpty &&
      reference.isEmpty;
}

class PaymentPreviewRow {
  final int line;
  final PaymentUploadRow raw;
  final PaymentRowStatus status;
  final String message;
  final String? studentId;
  final String? studentName;
  final String? invoiceId;
  final int amount; // whole GHS
  final PaymentMethod method;
  final String reference;

  const PaymentPreviewRow({
    required this.line,
    required this.raw,
    required this.status,
    required this.message,
    this.studentId,
    this.studentName,
    this.invoiceId,
    this.amount = 0,
    this.method = PaymentMethod.cash,
    this.reference = '',
  });

  bool get willWrite =>
      status != PaymentRowStatus.error && invoiceId != null && amount > 0;
}

PaymentMethod _method(String raw) {
  switch (raw.trim().toLowerCase().replaceAll(' ', '')) {
    case 'cash':
      return PaymentMethod.cash;
    case 'card':
      return PaymentMethod.card;
    case 'mobilemoney':
    case 'momo':
    case 'mtn':
    case 'mobile':
      return PaymentMethod.mobileMoney;
    case 'bank':
    case 'banktransfer':
    case 'transfer':
      return PaymentMethod.bank;
    default:
      return PaymentMethod.cash;
  }
}

// ---------------------------------------------------------------------------
// Template generation — prefilled with students who still owe.
// ---------------------------------------------------------------------------

/// Students with an outstanding balance, each paired with their oldest unpaid
/// invoice — the rows the template is seeded with.
List<({Student student, Invoice invoice})> _owing(
    List<Student> students, List<Invoice> invoices) {
  final byStudent = <String, List<Invoice>>{};
  for (final inv in invoices) {
    if (inv.balance > 0) byStudent.putIfAbsent(inv.studentId, () => []).add(inv);
  }
  final out = <({Student student, Invoice invoice})>[];
  for (final s in students) {
    final owed = byStudent[s.id];
    if (owed == null || owed.isEmpty) continue;
    owed.sort((a, b) => a.issueDate.compareTo(b.issueDate));
    out.add((student: s, invoice: owed.first));
  }
  return out;
}

String paymentTemplateCsv(List<Student> students, List<Invoice> invoices) {
  final b = StringBuffer();
  b.writeln('SOLVANTA — Record Payments');
  b.writeln(_csv('Amounts are in whole GHS. Enter what the school received.'));
  b.writeln();
  b.writeln(paymentColumns.map(_csv).join(','));
  for (final r in _owing(students, invoices)) {
    b.writeln([
      r.student.id,
      r.student.admissionNo,
      r.student.fullName,
      r.invoice.id,
      '', // amount
      'cash',
      '',
    ].map(_csv).join(','));
  }
  return b.toString();
}

Uint8List paymentTemplateXlsx(List<Student> students, List<Invoice> invoices) {
  final excel = Excel.createExcel();
  final ws = excel['Payments'];
  ws.appendRow([TextCellValue('SOLVANTA — Record Payments')]);
  ws.appendRow([TextCellValue('Amounts are in whole GHS.')]);
  ws.appendRow([TextCellValue('')]);
  ws.appendRow(paymentColumns.map(TextCellValue.new).toList());
  for (final r in _owing(students, invoices)) {
    ws.appendRow([
      TextCellValue(r.student.id),
      TextCellValue(r.student.admissionNo),
      TextCellValue(r.student.fullName),
      TextCellValue(r.invoice.id),
      TextCellValue(''),
      TextCellValue('cash'),
      TextCellValue(''),
    ]);
  }
  return Uint8List.fromList(excel.encode() ?? const []);
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

List<PaymentUploadRow> parsePaymentCsv(String text) =>
    _rows(_parseCsvGrid(text));

List<PaymentUploadRow> parsePaymentXlsx(Uint8List bytes) {
  final excel = Excel.decodeBytes(bytes);
  for (final table in excel.tables.values) {
    final grid = <List<String>>[
      for (final row in table.rows)
        [for (final cell in row) cell?.value?.toString() ?? '']
    ];
    final rows = _rows(grid);
    if (rows.isNotEmpty) return rows;
  }
  return const [];
}

List<PaymentUploadRow> _rows(List<List<String>> grid) {
  var headerAt = -1;
  for (var i = 0; i < grid.length; i++) {
    if (grid[i].isNotEmpty && grid[i][0].trim().toLowerCase() == 'studentid') {
      headerAt = i;
      break;
    }
  }
  if (headerAt < 0) return const [];
  final header = grid[headerAt].map((h) => h.trim().toLowerCase()).toList();
  int col(String n) => header.indexOf(n.toLowerCase());
  final iId = col('studentId'),
      iAdm = col('admissionNo'),
      iName = col('studentName'),
      iInv = col('invoiceId'),
      iAmt = col('amount'),
      iMeth = col('method'),
      iRef = col('reference');
  String at(List<String> r, int i) => (i >= 0 && i < r.length) ? r[i].trim() : '';

  final out = <PaymentUploadRow>[];
  for (var i = headerAt + 1; i < grid.length; i++) {
    final r = grid[i];
    final row = PaymentUploadRow(
      studentId: at(r, iId),
      admissionNo: at(r, iAdm),
      studentName: at(r, iName),
      invoiceId: at(r, iInv),
      amountText: at(r, iAmt),
      methodText: at(r, iMeth),
      reference: at(r, iRef),
    );
    if (!row.isBlank) out.add(row);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Preview validation
// ---------------------------------------------------------------------------

List<PaymentPreviewRow> buildPaymentPreview({
  required List<Student> students,
  required List<Invoice> invoices,
  required List<PaymentUploadRow> rows,
}) {
  final byId = {for (final s in students) s.id: s};
  final byAdmission = <String, List<Student>>{};
  for (final s in students) {
    if (s.admissionNo.isNotEmpty) {
      byAdmission.putIfAbsent(s.admissionNo, () => []).add(s);
    }
  }
  final invById = {for (final inv in invoices) inv.id: inv};
  List<Invoice> owing(String studentId) {
    final list = invoices
        .where((inv) => inv.studentId == studentId && inv.balance > 0)
        .toList()
      ..sort((a, b) => a.issueDate.compareTo(b.issueDate));
    return list;
  }

  final out = <PaymentPreviewRow>[];
  for (var i = 0; i < rows.length; i++) {
    final raw = rows[i];
    final line = i + 1;

    Student? student;
    if (raw.studentId.isNotEmpty) {
      student = byId[raw.studentId];
    } else if (raw.admissionNo.isNotEmpty) {
      final m = byAdmission[raw.admissionNo] ?? const [];
      if (m.length == 1) student = m.first;
    }
    if (student == null) {
      out.add(PaymentPreviewRow(
          line: line, raw: raw, status: PaymentRowStatus.error,
          message: 'Unknown student (match by id or admission no., not name)'));
      continue;
    }

    // Resolve the invoice: the named one (if it belongs to the student and is
    // unpaid), else the oldest invoice they still owe on.
    Invoice? invoice;
    if (raw.invoiceId.isNotEmpty) {
      final inv = invById[raw.invoiceId];
      if (inv != null && inv.studentId == student.id && inv.balance > 0) {
        invoice = inv;
      } else if (inv != null && inv.studentId == student.id) {
        out.add(PaymentPreviewRow(
            line: line, raw: raw, status: PaymentRowStatus.error,
            studentId: student.id, studentName: student.fullName,
            message: 'Invoice ${raw.invoiceId} is already fully paid'));
        continue;
      }
    }
    invoice ??= owing(student.id).isNotEmpty ? owing(student.id).first : null;
    if (invoice == null) {
      out.add(PaymentPreviewRow(
          line: line, raw: raw, status: PaymentRowStatus.error,
          studentId: student.id, studentName: student.fullName,
          message: '${student.fullName} has no outstanding invoice'));
      continue;
    }

    final amount = int.tryParse(raw.amountText.trim().replaceAll(',', ''));
    if (raw.amountText.trim().isEmpty) {
      out.add(PaymentPreviewRow(
          line: line, raw: raw, status: PaymentRowStatus.warning,
          studentId: student.id, studentName: student.fullName,
          message: 'No amount — this row will be skipped'));
      continue;
    }
    if (amount == null) {
      out.add(PaymentPreviewRow(
          line: line, raw: raw, status: PaymentRowStatus.error,
          studentId: student.id, studentName: student.fullName,
          message: '"${raw.amountText}" is not a whole GHS amount'));
      continue;
    }
    if (amount <= 0) {
      out.add(PaymentPreviewRow(
          line: line, raw: raw, status: PaymentRowStatus.error,
          studentId: student.id, studentName: student.fullName,
          message: 'Amount must be greater than 0'));
      continue;
    }
    if (amount > invoice.balance) {
      out.add(PaymentPreviewRow(
          line: line, raw: raw, status: PaymentRowStatus.error,
          studentId: student.id, studentName: student.fullName,
          invoiceId: invoice.id,
          message: 'More than the ${svCedis(invoice.balance)} outstanding'));
      continue;
    }

    out.add(PaymentPreviewRow(
      line: line, raw: raw, status: PaymentRowStatus.valid,
      studentId: student.id, studentName: student.fullName,
      invoiceId: invoice.id, amount: amount, method: _method(raw.methodText),
      reference: raw.reference, message: 'OK',
    ));
  }
  return out;
}

class PaymentPreviewSummary {
  final int valid, warning, error, totalPesewasAmount;
  const PaymentPreviewSummary(
      this.valid, this.warning, this.error, this.totalPesewasAmount);
  bool get hasBlockingErrors => error > 0;
}

PaymentPreviewSummary summarizePayments(List<PaymentPreviewRow> preview) {
  var v = 0, w = 0, e = 0, total = 0;
  for (final r in preview) {
    switch (r.status) {
      case PaymentRowStatus.valid:
        v++;
        total += r.amount;
      case PaymentRowStatus.warning:
        w++;
      case PaymentRowStatus.error:
        e++;
    }
  }
  return PaymentPreviewSummary(v, w, e, total);
}

// ---------------------------------------------------------------------------
// Small CSV helpers (shared shape with score_io).
// ---------------------------------------------------------------------------

String _csv(String s) {
  var v = s;
  if (v.isNotEmpty && '=+-@\t\r'.contains(v[0])) v = "'$v";
  if (v.contains(',') || v.contains('"') || v.contains('\n')) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}

List<List<String>> _parseCsvGrid(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var i = 0;
  void endField() {
    row.add(field.toString());
    field.clear();
  }

  void endRow() {
    endField();
    rows.add(row);
    row = <String>[];
  }

  while (i < text.length) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
        i++;
        continue;
      }
      field.write(ch);
      i++;
      continue;
    }
    switch (ch) {
      case '"':
        inQuotes = true;
        i++;
      case ',':
        endField();
        i++;
      case '\r':
        i++;
      case '\n':
        endRow();
        i++;
      default:
        field.write(ch);
        i++;
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}
