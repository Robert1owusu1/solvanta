import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../core/models/school.dart';
import '../../core/models/student.dart';
import '../../core/storage/local_store.dart';
import '../../core/theme/app_theme.dart';
import 'fee_models.dart';

// ---------------------------------------------------------------------------
// Branded fee documents (doc §39 export style): navy #1B3B6F header band,
// gold #E3A008 hairline under it, black-on-white body. Colours are derived
// from AppTheme constants (no raw hex here), so the palette cannot drift.
// The base PDF font is Latin-1 only — never put ✓/⚠ glyphs in the document.
// ---------------------------------------------------------------------------

/// Builds receipt/invoice PDFs for the fees module and shares them with
/// `share_plus` (saved to the temp directory — nothing touches the gallery).
class FeesPdf {
  /// Navy header fill (constant brand, same in both brightnesses).
  static PdfColor get _brand => PdfColor.fromInt(AppTheme.brand.toARGB32());

  /// Gold hairline accent (the ~10% brand accent, one gesture).
  static PdfColor get _gold => PdfColor.fromInt(AppTheme.gold.toARGB32());

  static PdfColor get _muted => PdfColor.fromInt(AppColors.muted.toARGB32());

  /// Full-width navy band: school name + document title + gold hairline.
  pw.Widget _header(String schoolName, String docTitle, String docSubtitle) =>
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.fromLTRB(18, 16, 18, 14),
        decoration: pw.BoxDecoration(
          color: _brand,
          border: pw.Border(bottom: pw.BorderSide(color: _gold, width: 3)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'SOLVANTA',
              style: pw.TextStyle(
                fontSize: 17,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
                letterSpacing: 1.2,
              ),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              schoolName,
              style: const pw.TextStyle(
                fontSize: 9,
                color: PdfColors.white,
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Text(
              docTitle,
              style: pw.TextStyle(
                fontSize: 13,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
            ),
            if (docSubtitle.isNotEmpty) ...[
              pw.SizedBox(height: 2),
              pw.Text(
                docSubtitle,
                style: const pw.TextStyle(
                  fontSize: 9,
                  color: PdfColors.white,
                ),
              ),
            ],
          ],
        ),
      );

  /// Label/value row used for the document's header facts.
  pw.Widget _fact(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(
              width: 110,
              child: pw.Text(
                label,
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
              ),
            ),
            pw.Expanded(
              child: pw.Text(value, style: const pw.TextStyle(fontSize: 9)),
            ),
          ],
        ),
      );

  /// Emphasised money row (total / paid / balance).
  pw.Widget _moneyRow(String label, String value, {bool emphasize = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          children: [
            pw.Expanded(
              child: pw.Text(
                label,
                style: emphasize
                    ? pw.TextStyle(
                        fontWeight: pw.FontWeight.bold, fontSize: 11)
                    : const pw.TextStyle(fontSize: 9),
              ),
            ),
            pw.Text(
              value,
              style: emphasize
                  ? pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 12,
                      color: _brand,
                    )
                  : const pw.TextStyle(fontSize: 9),
            ),
          ],
        ),
      );

  /// School identity for letterheads, with a safe offline fallback.
  Future<School> _school() async {
    try {
      final school = await LocalStore().loadSchool();
      if (school != null) return school;
    } catch (ex) {
      debugPrint('FeesPdf: school load failed, using fallback letterhead: $ex');
    }
    return const School(
      id: 'SCH-001',
      name: 'Accra Junior High School',
      address: '12 Independence Avenue, Accra',
      phone: '0302-000-000',
      email: 'info@accrajhs.school.gh',
    );
  }

  pw.Widget _footer(School school) => pw.Container(
        width: double.infinity,
        margin: const pw.EdgeInsets.only(top: 18),
        padding: const pw.EdgeInsets.only(top: 8),
        decoration: pw.BoxDecoration(
          border: pw.Border(top: pw.BorderSide(color: _gold, width: 1.5)),
        ),
        child: pw.Text(
          'Generated offline by SOLVANTA · ${DateTime.now().year} · '
          '${school.address} · ${school.phone}',
          style: pw.TextStyle(fontSize: 7, color: _muted),
        ),
      );

  /// Payment receipt PDF for one committed [receipt].
  Future<Uint8List> receiptPdf({
    required Receipt receipt,
    required Invoice invoice,
    required Student student,
    String? schoolName,
  }) async {
    final school = await _school();
    final doc = pw.Document();
    final docTitle = 'Payment Receipt';
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (context) => pw.Padding(
          padding: const pw.EdgeInsets.all(20),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _header(
                schoolName ?? school.name,
                docTitle,
                'Receipt ${receipt.id} · ${receipt.issuedAt}',
              ),
              pw.SizedBox(height: 14),
              _fact('Student', student.fullName),
              _fact('Class / ID', '${student.classId} · ${student.id}'),
              _fact('Admission No.', student.admissionNo),
              _fact('Invoice', receipt.invoiceId),
              _fact('Term', invoice.term),
              _fact('Paid on', receipt.issuedAt),
              _fact('Method', receipt.method.label),
              if (receipt.reference.isNotEmpty)
                _fact('Reference', receipt.reference),
              _fact('Recorded by', receipt.issuedBy),
              pw.SizedBox(height: 12),
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: _gold, width: 1.2),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    _moneyRow('Amount received', svCedis(receipt.amount),
                        emphasize: true),
                    pw.Divider(color: _muted, thickness: 0.4),
                    _moneyRow('Invoice balance after payment',
                        svCedis(receipt.balanceAfter)),
                  ],
                ),
              ),
              pw.SizedBox(height: 10),
              pw.Text(
                'Keep this receipt for your records. It was issued on device '
                'and remains valid offline.',
                style: pw.TextStyle(fontSize: 8, color: _muted),
              ),
              _footer(school),
            ],
          ),
        ),
      ),
    );
    return doc.save();
  }

  /// Invoice statement PDF: line items, totals and the payment history.
  Future<Uint8List> invoicePdf({
    required Invoice invoice,
    required Student student,
    List<Payment> payments = const [],
    String? schoolName,
  }) async {
    final school = await _school();
    final doc = pw.Document();
    final status = invoice.resolveStatus().label;
    final items = pw.TableHelper.fromTextArray(
      headers: ['Item', 'Amount (GHS)'],
      data: [
        for (final item in invoice.lineItems)
          [item.name, svCedis(item.amount).replaceFirst('GHS ', '')],
        ['', ''],
        ['Total', svCedis(invoice.total).replaceFirst('GHS ', '')],
        ['Paid', svCedis(invoice.amountPaid).replaceFirst('GHS ', '')],
        ['Balance', svCedis(invoice.balance).replaceFirst('GHS ', '')],
      ],
      headerStyle: pw.TextStyle(
        fontWeight: pw.FontWeight.bold,
        fontSize: 9,
        color: PdfColors.white,
      ),
      headerDecoration: pw.BoxDecoration(color: _brand),
      cellStyle: const pw.TextStyle(fontSize: 9, color: PdfColors.black),
      cellAlignments: {
        0: pw.Alignment.centerLeft,
        1: pw.Alignment.centerRight,
      },
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    );
    final history = pw.TableHelper.fromTextArray(
      headers: ['Date', 'Method', 'Reference', 'Amount (GHS)'],
      data: [
        for (final p in payments)
          [
            p.paidAt,
            p.method.label,
            p.reference.isEmpty ? '—' : p.reference,
            svCedis(p.amount).replaceFirst('GHS ', ''),
          ],
      ],
      headerStyle: pw.TextStyle(
        fontWeight: pw.FontWeight.bold,
        fontSize: 9,
        color: PdfColors.white,
      ),
      headerDecoration: pw.BoxDecoration(color: _brand),
      cellStyle: const pw.TextStyle(fontSize: 8, color: PdfColors.black),
      cellAlignments: {
        0: pw.Alignment.centerLeft,
        1: pw.Alignment.centerLeft,
        2: pw.Alignment.centerLeft,
        3: pw.Alignment.centerRight,
      },
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    );

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (context) => pw.Padding(
          padding: const pw.EdgeInsets.all(20),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _header(
                schoolName ?? school.name,
                'Fee Invoice',
                '${invoice.id} · status: $status',
              ),
              pw.SizedBox(height: 14),
              _fact('Student', student.fullName),
              _fact('Class / ID', '${student.classId} · ${student.id}'),
              _fact('Admission No.', student.admissionNo),
              _fact('Term', invoice.term),
              _fact('Issued', invoice.issueDate),
              _fact('Due', invoice.dueDate),
              pw.SizedBox(height: 10),
              items,
              pw.SizedBox(height: 14),
              pw.Text(
                'Payment history',
                style:
                    pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11),
              ),
              pw.SizedBox(height: 4),
              if (payments.isEmpty)
                pw.Text(
                  'No payments recorded yet.',
                  style: pw.TextStyle(fontSize: 9, color: _muted),
                )
              else
                history,
              _footer(school),
            ],
          ),
        ),
      ),
    );
    return doc.save();
  }

  /// Writes [bytes] to the temp directory as `<name>.pdf` and opens the
  /// share sheet. Throws only for the caller to surface a friendly message.
  Future<void> saveAndShare(Uint8List bytes, String name) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$name.pdf');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/pdf')],
        fileNameOverrides: ['$name.pdf'],
      ),
    );
  }

  /// Shares plain receipt/invoice text (no file) — the lightweight path
  /// when a PDF is unnecessary.
  Future<void> shareText(String text, {String? title}) async {
    await SharePlus.instance.share(
      ShareParams(text: text, title: title),
    );
  }
}
