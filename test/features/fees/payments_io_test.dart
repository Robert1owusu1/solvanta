import 'package:flutter_test/flutter_test.dart';

import 'package:solvanta/core/models/student.dart';
import 'package:solvanta/features/fees/fee_models.dart';
import 'package:solvanta/features/fees/payments_io.dart';

Student _student(String id, String adm, String first, String last) => Student(
      id: id,
      firstName: first,
      lastName: last,
      gender: 'M',
      dateOfBirth: '2010-01-01',
      admissionDate: '2023-09-01',
      admissionNo: adm,
      classId: 'JHS2A',
      schoolId: 'SCH-001',
    );

Invoice _invoice(String id, String studentId, int total, int paid,
        {String issue = '2026-09-01'}) =>
    Invoice(
      id: id,
      studentId: studentId,
      issueDate: issue,
      dueDate: '2026-10-01',
      term: 'Term 1 · 2026/2027',
      lineItems: [FeeLineItem(name: 'Fees', amount: total)],
      amountPaid: paid,
    );

void main() {
  final students = [
    _student('STU-001', 'S-001', 'Kojo', 'Owusu'),
    _student('STU-002', 'S-002', 'Akosua', 'Boaduwaa'),
    _student('STU-003', 'S-003', 'No', 'Debt'),
  ];
  // STU-001 owes 500 (1000 total, 500 paid); STU-002 owes 300; STU-003 is clear.
  final invoices = [
    _invoice('INV-1', 'STU-001', 1000, 500),
    _invoice('INV-2', 'STU-002', 300, 0),
    _invoice('INV-3', 'STU-003', 400, 400),
  ];

  List<PaymentPreviewRow> preview(List<PaymentUploadRow> rows) =>
      buildPaymentPreview(students: students, invoices: invoices, rows: rows);

  group('template', () {
    test('seeds only students who still owe', () {
      final csv = paymentTemplateCsv(students, invoices);
      expect(csv, contains('STU-001,S-001,Kojo Owusu,INV-1'));
      expect(csv, contains('STU-002,S-002,Akosua Boaduwaa,INV-2'));
      expect(csv, isNot(contains('STU-003'))); // fully paid → not seeded
    });

    test('xlsx round-trips to rows', () {
      final rows = parsePaymentXlsx(paymentTemplateXlsx(students, invoices));
      expect(rows.map((r) => r.studentId), containsAll(['STU-001', 'STU-002']));
    });
  });

  group('preview', () {
    test('a valid amount resolves to the student’s outstanding invoice', () {
      final p = preview([const PaymentUploadRow(studentId: 'STU-001', amountText: '200', methodText: 'momo')]);
      expect(p.single.status, PaymentRowStatus.valid);
      expect(p.single.invoiceId, 'INV-1');
      expect(p.single.amount, 200);
      expect(p.single.method, PaymentMethod.mobileMoney);
      expect(p.single.willWrite, isTrue);
    });

    test('matches on admission number, never on name', () {
      expect(preview([const PaymentUploadRow(admissionNo: 'S-002', amountText: '100')]).single.studentId, 'STU-002');
      expect(preview([const PaymentUploadRow(studentName: 'Kojo Owusu', amountText: '100')]).single.status,
          PaymentRowStatus.error);
    });

    test('an amount over the balance is an error', () {
      final p = preview([const PaymentUploadRow(studentId: 'STU-001', amountText: '9999')]);
      expect(p.single.status, PaymentRowStatus.error);
      expect(p.single.message, contains('outstanding'));
    });

    test('a non-numeric amount is an error', () {
      expect(preview([const PaymentUploadRow(studentId: 'STU-001', amountText: 'lots')]).single.status,
          PaymentRowStatus.error);
    });

    test('a student with nothing owing is an error', () {
      expect(preview([const PaymentUploadRow(studentId: 'STU-003', amountText: '50')]).single.status,
          PaymentRowStatus.error);
    });

    test('a blank amount is a skipped warning', () {
      final p = preview([const PaymentUploadRow(studentId: 'STU-001')]);
      expect(p.single.status, PaymentRowStatus.warning);
      expect(p.single.willWrite, isFalse);
    });

    test('summary totals the valid amounts', () {
      final p = preview([
        const PaymentUploadRow(studentId: 'STU-001', amountText: '200'),
        const PaymentUploadRow(studentId: 'STU-002', amountText: '100'),
        const PaymentUploadRow(studentId: 'STU-003', amountText: '50'), // error
      ]);
      final s = summarizePayments(p);
      expect(s.valid, 2);
      expect(s.error, 1);
      expect(s.totalPesewasAmount, 300);
    });
  });
}
