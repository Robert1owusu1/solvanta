import '../../core/models/term_report.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';
import 'report_card_pdf.dart';

/// Term reports: saved on this device first, then sent to the server, which
/// enforces who may write which part (see `httpapi/term_reports.go`) and
/// stamps who approved and when.
class TermReportsRepository {
  TermReportsRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  /// Every report for [year] / [term], by student id.
  Future<Map<String, TermReport>> forTerm(String year, String term) async => {
        for (final r in await _store.loadTermReports())
          if (r.year == year && r.term == term) r.studentId: r,
      };

  /// [studentId]'s approved reports, newest first — what their family sees.
  Future<List<TermReport>> approvedFor(String studentId) async {
    final mine = [
      for (final r in await _store.loadTermReports())
        if (r.studentId == studentId && r.approved && r.snapshot != null) r,
    ];
    mine.sort((a, b) => (b.approvedAt).compareTo(a.approvedAt));
    return mine;
  }

  Future<void> save(TermReport report) async {
    final all = await _store.loadTermReports();
    await _store.saveTermReports([
      for (final r in all)
        if (r.id != report.id) r,
      report,
    ]);
    await ServerSync.instance.send(
        'PUT', '/api/records/term_reports/${report.id}',
        body: report.toJson());
  }

  /// Approves [report] with [card] frozen in it — the card exactly as the
  /// headteacher saw it. Shown as approved by [actor] here at once; the
  /// server's own stamp replaces it on the next sync.
  Future<TermReport> approve(
      TermReport report, ReportCardData card, String actor) async {
    final approved = TermReport.fromJson({
      ...report.withApproval(card.toJson()).toJson(),
      'approvedBy': actor,
      'approvedAt': DateTime.now().toIso8601String().substring(0, 16),
    });
    await save(approved);
    return approved;
  }

  /// Reopens an approved report as a draft (school leaders only).
  Future<TermReport> reopen(TermReport report) async {
    final draft = report.withApproval(null);
    await save(draft);
    return draft;
  }
}
