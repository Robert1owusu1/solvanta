import 'school.dart';

/// Feature catalogue — mirrors `backend/internal/domain/capabilities.go`. Every
/// gated feature is named once here and on the server, so the capability matrix
/// is defined in one place. Phase 4 layers per-plan toggles and limits on top.
abstract final class Feature {
  static const studentsRegister = 'students.register';
  static const studentsBulkImport = 'students.bulkImport';
  static const classesManage = 'classes.manage';
  static const assessmentsCreate = 'assessments.create';
  static const markingAi = 'marking.ai';
  static const scoresManual = 'scores.manual';
  static const scoresBulkUpload = 'scores.bulkUpload';
  static const scoreSheet = 'scoreSheet.view';
  static const exportXlsx = 'export.xlsx';
  static const exportPdf = 'export.pdf';
  static const questionBank = 'questionBank';
  static const aiQuestionGen = 'aiQuestionGen';
  static const analyticsClass = 'analytics.class';
  static const transferToSchool = 'transfer.toSchool';

  // Features an independent workspace does NOT get.
  static const fees = 'fees';
  static const gate = 'gate';
  static const sms = 'sms';
  static const staffManage = 'staff.manage';
  static const announcements = 'announcements';
  static const reportApproval = 'reportApproval';
  static const analyticsSchool = 'analytics.school';
  static const audit = 'audit';
  static const parentStudent = 'logins.parentStudent';
}

/// Features an independent teacher's workspace cannot use — the school-only
/// modules. Mirrors `independentDenied` in Go.
const _independentDenied = {
  Feature.fees,
  Feature.gate,
  Feature.sms,
  Feature.staffManage,
  Feature.announcements,
  Feature.reportApproval,
  Feature.analyticsSchool,
  Feature.audit,
  Feature.parentStudent,
};

/// The single capability check the client goes through, instead of scattered
/// `if independent` tests. A normal school allows everything (role gates still
/// apply); an independent workspace is denied the school-only modules.
abstract final class Capabilities {
  static bool schoolAllows(SchoolKind kind, String feature) {
    if (kind == SchoolKind.independent) {
      return !_independentDenied.contains(feature);
    }
    return true;
  }

  static bool allows(School school, String feature) =>
      schoolAllows(school.kind, feature);

  /// The current workspace's kind, kept up to date like [School] loads. Screens
  /// and the module grid read this synchronously to hide what the workspace
  /// cannot use. Defaults to a normal school.
  static SchoolKind currentKind = SchoolKind.school;

  static bool current(String feature) => schoolAllows(currentKind, feature);
}
