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
import '../students/students_repository.dart';
import 'report_card_pdf.dart';

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

  static Future<ReportCardSource> load({LocalStore? store}) async {
    final s = store ?? LocalStore();
    final repo = AssessmentRepository();
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
    );
  }

  /// Class teacher for the student's class, or `''` when none is on record.
  String teacherNameFor(Student student) =>
      users
          .where((u) => u.role.isTeacher && u.classId == student.classId)
          .firstOrNull
          ?.name ??
      '';

  /// [student]'s card for this term.
  ReportCardData cardFor(Student student) {
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

  /// [studentId]'s card, or `null` when that student isn't on this device.
  ReportCardData? cardForId(String studentId) {
    final s = students.where((x) => x.id == studentId).firstOrNull;
    return s == null ? null : cardFor(s);
  }
}
