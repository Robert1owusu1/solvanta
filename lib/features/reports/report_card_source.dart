import '../../core/models/assessment.dart';
import '../../core/models/attendance.dart';
import '../../core/models/class_room.dart';
import '../../core/models/grading.dart';
import '../../core/models/school.dart';
import '../../core/models/school_term.dart';
import '../../core/models/student.dart';
import '../../core/models/submission.dart';
import '../../core/models/user.dart';
import '../../core/storage/local_store.dart';
import '../assessment/assessment_repository.dart';
import '../calendar/term_repository.dart';
import '../fees/fee_models.dart';
import '../fees/fees_repository.dart';
import '../students/students_repository.dart';
import '../../core/models/term_report.dart';
import 'report_card_pdf.dart';
import 'term_reports_repository.dart';

/// Everything a report card is built from, read from the local store so it
/// works offline: marks, the class roster (for positions), this term and the
/// finished ones, the school's grading set-up and this term's attendance.
/// Shared by the Report Cards screen and the parent / student results.
class ReportCardSource {
  const ReportCardSource({
    required this.students,
    required this.assessments,
    required this.subs,
    required this.term,
    required this.pastTerms,
    required this.grading,
    required this.classes,
    required this.school,
    required this.users,
    required this.attendance,
    this.invoices = const [],
    this.feeStructures = const [],
    this.reports = const {},
  });

  final List<Student> students;
  final List<Assessment> assessments;
  final List<AssessmentSubmission> subs;
  final SchoolTerm term;

  /// Finished terms with the grading each ended under, oldest first.
  final List<FinishedTerm> pastTerms;

  /// The school's grading set-up and its classes, which pick the scheme.
  final GradingConfig grading;
  final List<ClassRoom> classes;
  final School school;
  final List<User> users;

  /// This term's attendance records, bucketed by student id.
  final Map<String, List<AttendanceRecord>> attendance;

  /// The Fees module's invoices and fee structures, for "Fees owing" and
  /// "Next term's fees".
  final List<Invoice> invoices;
  final List<FeeStructure> feeStructures;

  /// This term's reports (remarks, approval), by student id.
  final Map<String, TermReport> reports;

  static Future<ReportCardSource> load({LocalStore? store}) async {
    final s = store ?? LocalStore();
    final repo = AssessmentRepository();
    final fees = FeesRepository(store: s);
    final term = await TermRepository(store: s).current();
    final attendance = <String, List<AttendanceRecord>>{};
    for (final r in await s.loadAttendance()) {
      if (!term.contains(r.date)) continue;
      (attendance[r.studentId] ??= <AttendanceRecord>[]).add(r);
    }
    return ReportCardSource(
      students: await StudentsRepository().all(),
      assessments: await repo.assessments(),
      subs: await repo.submissions(),
      term: term,
      pastTerms: await s.loadTermHistory(),
      grading: await s.loadGradingConfig(),
      classes: await s.loadClasses(),
      school: await s.loadSchool() ??
          const School(id: 'SCH-001', name: 'SOLVANTA School'),
      users: await s.loadUsers(),
      attendance: attendance,
      invoices: await fees.invoices(),
      feeStructures: await fees.structures(),
      reports: await TermReportsRepository(store: s)
          .forTerm(term.year, term.name),
    );
  }

  /// Class teacher for the student's class, or `''` when none is on record.
  String teacherNameFor(Student student) =>
      users
          .where((u) => u.role.isTeacher && u.classId == student.classId)
          .firstOrNull
          ?.name ??
      '';

  /// [student]'s report for this term — the saved one, or a fresh draft.
  TermReport reportFor(Student student) =>
      reports[student.id] ??
      TermReport(
        studentId: student.id,
        classId: student.classId,
        year: term.year,
        term: term.name,
      );

  /// [student]'s card for this term: exactly as approved once the
  /// headteacher has approved it, otherwise built from the latest marks
  /// with the term report's remarks on it.
  ReportCardData cardFor(Student student) {
    final report = reports[student.id];
    final frozen = report?.snapshot;
    if (report != null && report.approved && frozen != null) {
      return ReportCardData.fromJson(frozen).copyWithJson({
        'approvedBy': report.approvedBy.isEmpty ? 'the school' : report.approvedBy,
        'approvedAt': report.approvedAt,
      });
    }
    final live = liveCardFor(student);
    return report == null ? live : withReport(live, report);
  }

  /// [card] with [report]'s remarks on it: the teacher's own remark replaces
  /// the generated one.
  static ReportCardData withReport(ReportCardData card, TermReport report) =>
      card.copyWithJson({
        if (report.teacherRemark.trim().isNotEmpty)
          'remark': report.teacherRemark.trim(),
        'conduct': report.conduct,
        'attitude': report.attitude,
        'interest': report.interest,
        'headRemark': report.headRemark,
      });

  /// [student]'s card from the latest marks, ignoring any approval.
  ReportCardData liveCardFor(Student student) {
    final records = attendance[student.id] ?? const <AttendanceRecord>[];
    return ReportCardDataBuilder.build(
      student: student,
      school: school,
      term: term,
      assessments: assessments,
      subs: subs,
      roster: students,
      pastTerms: pastTerms,
      grading: grading,
      classes: classes,
      teacherName: teacherNameFor(student),
      feesOwing: feesOwingFor(student.id),
      nextTermFeesFor: nextTermFeesFor,
      attendance: records.isEmpty
          ? null
          : (
              total: records.length,
              present: records
                  .where((r) =>
                      r.status == AttendanceStatus.present ||
                      r.status == AttendanceStatus.late)
                  .length,
            ),
    );
  }

  /// Unpaid balance across [studentId]'s invoices, or `null` when the Fees
  /// module has billed them nothing.
  int? feesOwingFor(String studentId) {
    final mine = invoices.where((i) => i.studentId == studentId).toList();
    if (mine.isEmpty) return null;
    return mine.fold<int>(0, (sum, i) => sum + i.balance);
  }

  /// Fees set for [classId] for the term after this one (its own and the
  /// school-wide ones), or `null` when none are set yet.
  int? nextTermFeesFor(String classId) {
    final next = term.nextLabel;
    final due = feeStructures.where((f) =>
        f.term == next &&
        (f.classId == classId || f.classId == FeeStructure.allClasses));
    if (due.isEmpty) return null;
    return due.fold<int>(0, (sum, f) => sum + f.amount);
  }

  /// [studentId]'s card, or `null` when that student isn't on this device.
  ReportCardData? cardForId(String studentId) {
    final s = students.where((x) => x.id == studentId).firstOrNull;
    return s == null ? null : cardFor(s);
  }
}
