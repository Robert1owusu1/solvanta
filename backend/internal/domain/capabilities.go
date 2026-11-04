package domain

// Feature catalogue — every gated feature, named once and shared with the Dart
// client (lib/core/models/capabilities.dart) so the capability matrix is
// defined in one place. Phase 4 layers per-plan toggles and limits on top of
// this; Phase 3 uses it to decide what an independent workspace may do.
const (
	FeatStudentsRegister   = "students.register"
	FeatStudentsBulkImport = "students.bulkImport"
	FeatClassesManage      = "classes.manage"
	FeatAssessmentsCreate  = "assessments.create"
	FeatMarkingAI          = "marking.ai"
	FeatScoresManual       = "scores.manual"
	FeatScoresBulkUpload   = "scores.bulkUpload"
	FeatScoreSheet         = "scoreSheet.view"
	FeatExportXlsx         = "export.xlsx"
	FeatExportPdf          = "export.pdf"
	FeatQuestionBank       = "questionBank"
	FeatAIQuestionGen      = "aiQuestionGen"
	FeatAnalyticsClass     = "analytics.class"
	FeatTransferToSchool   = "transfer.toSchool"

	// Features an independent workspace does NOT get.
	FeatFees            = "fees"
	FeatGate            = "gate"
	FeatSMS             = "sms"
	FeatStaffManage     = "staff.manage"
	FeatAnnouncements   = "announcements"
	FeatReportApproval  = "reportApproval"
	FeatAnalyticsSchool = "analytics.school"
	FeatAudit           = "audit"
	FeatParentStudent   = "logins.parentStudent"
)

// AllFeatures is every gated feature key, for catalogues and tests.
var AllFeatures = []string{
	FeatStudentsRegister, FeatStudentsBulkImport, FeatClassesManage,
	FeatAssessmentsCreate, FeatMarkingAI, FeatScoresManual, FeatScoresBulkUpload,
	FeatScoreSheet, FeatExportXlsx, FeatExportPdf, FeatQuestionBank,
	FeatAIQuestionGen, FeatAnalyticsClass, FeatTransferToSchool,
	FeatFees, FeatGate, FeatSMS, FeatStaffManage, FeatAnnouncements,
	FeatReportApproval, FeatAnalyticsSchool, FeatAudit, FeatParentStudent,
}

// independentDenied are the features an independent teacher's workspace cannot
// use — fees & invoices, gate/safety, SMS, staff management, parent/student
// logins, announcements, the report-card approval workflow, school-wide
// analytics and audit screens.
var independentDenied = map[string]bool{
	FeatFees:            true,
	FeatGate:            true,
	FeatSMS:             true,
	FeatStaffManage:     true,
	FeatAnnouncements:   true,
	FeatReportApproval:  true,
	FeatAnalyticsSchool: true,
	FeatAudit:           true,
	FeatParentStudent:   true,
}

// SchoolAllows reports whether a school of the given kind may use a feature.
// A normal school allows everything (role gates still apply); an independent
// workspace is denied the school-only modules above. Empty kind is a school.
//
// This is the single capability check the whole codebase goes through, instead
// of scattered `if independent` tests (see Capabilities.forSchool in Dart).
func SchoolAllows(kind, feature string) bool {
	if kind == SchoolKindIndependent {
		return !independentDenied[feature]
	}
	return true
}
