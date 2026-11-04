package httpapi

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/store"
)

// Transfer of an independent teacher's workspace into a school (Phase 3). When
// the teacher's school joins SOLVANTA, a super admin moves the workspace's
// classes, students, assessments and scores into the school's tenant, turns the
// teacher into a normal teacher there, and archives the workspace read-only.
//
// Ids are kept where free in the destination and remapped otherwise, with the
// old→new map returned so an offline client replaying old ids still lands
// correctly. Every transfer is audited in both tenants.
//
// Scope note: the gradebook graph (classes → students → assessments →
// submissions) and the teacher account are moved. Marking drafts, marking
// schemes and scan images are reported in the preview but left in the archived
// (read-only) workspace, which is never deleted, so they stay accessible.

type transferRequest struct {
	SourceSchoolID string `json:"sourceSchoolId"`
	// ClassDecisions maps a source class id to "merge" (into an existing class
	// with the same id in the destination) or "new" (create a fresh class).
	// A clashing class with no decision defaults to "new".
	ClassDecisions map[string]string `json:"classDecisions"`
}

type transferConflict struct {
	Kind   string `json:"kind"` // classNameClash | duplicateAdmission | emailClash
	ID     string `json:"id"`
	Detail string `json:"detail"`
}

type transferCounts struct {
	Classes        int `json:"classes"`
	Students       int `json:"students"`
	Assessments    int `json:"assessments"`
	Scores         int `json:"scores"`
	MarkingDrafts  int `json:"markingDrafts"`
	MarkingSchemes int `json:"markingSchemes"`
	ScanImages     int `json:"scanImages"`
}

// transferSource validates the request and returns the source (independent) and
// destination (school) stores. It writes the error and returns ok=false.
func (s *Server) transferSource(c *gin.Context) (src store.Store, dst store.Store, srcID, dstID string, ok bool) {
	dstID, dst, found := s.schoolInPath(c)
	if !found {
		return nil, nil, "", "", false
	}
	var body transferRequest
	if !bind(c, &body) {
		return nil, nil, "", "", false
	}
	c.Set(ctxTransferBodyKey, body)
	if body.SourceSchoolID == "" || body.SourceSchoolID == dstID {
		fail(c, http.StatusBadRequest, "a different source workspace is required")
		return nil, nil, "", "", false
	}
	src, err := s.tenants.For(body.SourceSchoolID)
	if err != nil {
		fail(c, http.StatusNotFound, "Source workspace not found")
		return nil, nil, "", "", false
	}
	if !src.School().IsIndependent() {
		fail(c, http.StatusBadRequest, "only an independent workspace can be transferred")
		return nil, nil, "", "", false
	}
	if dst.School().IsIndependent() {
		fail(c, http.StatusBadRequest, "the destination must be a school, not a workspace")
		return nil, nil, "", "", false
	}
	return src, dst, body.SourceSchoolID, dstID, true
}

const ctxTransferBodyKey = "solvanta.transferBody"

func transferBody(c *gin.Context) transferRequest {
	v, _ := c.Get(ctxTransferBodyKey)
	b, _ := v.(transferRequest)
	return b
}

// countsAndConflicts tallies what would move and the conflicts the super admin
// must resolve. Shared by preview and execute (execute re-checks).
func countsAndConflicts(src, dst store.Store, ownerEmail string, emailHome string) (transferCounts, []transferConflict) {
	var counts transferCounts
	var conflicts []transferConflict

	targetClasses := map[string]bool{}
	for _, c := range dst.Classes() {
		targetClasses[c.ID] = true
	}
	for _, sc := range src.Classes() {
		counts.Classes++
		if targetClasses[sc.ID] {
			conflicts = append(conflicts, transferConflict{
				Kind: "classNameClash", ID: sc.ID,
				Detail: "a class " + sc.ID + " already exists in the school"})
		}
	}

	targetAdmissions := map[string]string{}
	for _, st := range dst.Students() {
		if st.AdmissionNo != "" {
			targetAdmissions[st.AdmissionNo] = st.ID
		}
	}
	for _, st := range src.Students() {
		counts.Students++
		if st.AdmissionNo != "" {
			if other, dup := targetAdmissions[st.AdmissionNo]; dup {
				conflicts = append(conflicts, transferConflict{
					Kind: "duplicateAdmission", ID: st.AdmissionNo,
					Detail: st.FullName() + " shares admission no. " + st.AdmissionNo + " with " + other})
			}
		}
	}

	counts.Assessments = len(src.Assessments())
	subs := src.Submissions()
	counts.Scores = len(subs)
	counts.MarkingSchemes = len(src.MarkingSchemes())
	for _, sub := range subs {
		counts.MarkingDrafts += len(src.MarkingDraftsForSubmission(sub.ID))
		counts.ScanImages += len(src.ScanPages(sub.ID))
	}

	// The owner's sign-in email clashes when the destination already holds it.
	if ownerEmail != "" && emailHome != "" {
		if _, found := dst.UserByEmail(ownerEmail); found {
			conflicts = append(conflicts, transferConflict{
				Kind: "emailClash", ID: ownerEmail,
				Detail: "the school already has an account with this email"})
		}
	}
	return counts, conflicts
}

// transferPreview is the dry-run: what would move and any conflicts, writing
// nothing. POST /api/schools/:id/transfers/preview (super admin).
func (s *Server) transferPreview(c *gin.Context) {
	src, dst, srcID, dstID, ok := s.transferSource(c)
	if !ok {
		return
	}
	owner := src.School().OwnerUserID
	ownerUser, _ := src.UserByID(owner)
	emailHome, _ := s.tenants.SchoolForEmail(ownerUser.Email)
	counts, conflicts := countsAndConflicts(src, dst, ownerUser.Email, emailHome)
	sendJSON(c, gin.H{
		"sourceSchoolId": srcID,
		"targetSchoolId": dstID,
		"teacher":        gin.H{"id": ownerUser.ID, "name": ownerUser.Name, "email": ownerUser.Email},
		"counts":         counts,
		"conflicts":      conflicts,
	})
}

// transferExecute moves the workspace into the school and archives it.
// POST /api/schools/:id/transfers (super admin).
func (s *Server) transferExecute(c *gin.Context) {
	src, dst, srcID, dstID, ok := s.transferSource(c)
	if !ok {
		return
	}
	body := transferBody(c)
	srcSchool := src.School()
	if srcSchool.Archived {
		fail(c, http.StatusConflict, "This workspace has already been transferred")
		return
	}
	owner, _ := src.UserByID(srcSchool.OwnerUserID)

	idMap := map[string]string{} // old id → new id, every entity
	remapped := func(prefix, id string, taken func(string) bool) string {
		if !taken(id) {
			idMap[id] = id
			return id
		}
		n := newID(prefix)
		idMap[id] = n
		return n
	}

	// 1. Classes (honouring merge/new decisions).
	classMap := map[string]string{}
	for _, sc := range src.Classes() {
		_, clash := dst.ClassByID(sc.ID)
		decision := body.ClassDecisions[sc.ID]
		if clash && decision == "merge" {
			classMap[sc.ID] = sc.ID // fold into the existing class
			idMap[sc.ID] = sc.ID
			continue
		}
		newCID := remapped("CLS", sc.ID, func(id string) bool { _, ex := dst.ClassByID(id); return ex })
		classMap[sc.ID] = newCID
		nc := sc
		nc.ID = newCID
		if writeFailed(c, dst.SaveClass(nc)) {
			return
		}
	}

	// 2. Students.
	studentMap := map[string]string{}
	for _, ss := range src.Students() {
		newSID := remapped("STU", ss.ID, func(id string) bool { _, ex := dst.StudentByID(id); return ex })
		studentMap[ss.ID] = newSID
		ns := ss
		ns.ID = newSID
		ns.SchoolID = dstID
		if mapped, okc := classMap[ss.ClassID]; okc {
			ns.ClassID = mapped
		}
		// Independent workspaces have no parent accounts to carry over.
		ns.ParentUserID = ""
		if writeFailed(c, dst.SaveStudent(ns)) {
			return
		}
	}

	// 3. Assessments.
	assessmentMap := map[string]string{}
	for _, sa := range src.Assessments() {
		newAID := remapped("ASSMT", sa.ID, func(id string) bool { _, ex := dst.AssessmentByID(id); return ex })
		assessmentMap[sa.ID] = newAID
		na := sa
		na.ID = newAID
		if mapped, okc := classMap[sa.ClassID]; okc {
			na.ClassID = mapped
		}
		if writeFailed(c, dst.SaveAssessment(na)) {
			return
		}
	}

	// 4. Submissions (scores).
	for _, sub := range src.Submissions() {
		ns := sub
		ns.ID = idMap[sub.ID] // usually fresh; keep map complete
		if ns.ID == "" {
			ns.ID = newID("SUB")
			idMap[sub.ID] = ns.ID
		}
		if mapped, oka := assessmentMap[sub.AssessmentID]; oka {
			ns.AssessmentID = mapped
		}
		if mapped, oks := studentMap[sub.StudentID]; oks {
			ns.StudentID = mapped
		}
		if mapped, okc := classMap[sub.ClassID]; okc {
			ns.ClassID = mapped
		}
		if writeFailed(c, dst.SaveSubmission(ns)) {
			return
		}
	}

	// 5. The teacher becomes a normal teacher in the school. Re-point the email
	// directory first so SaveUser's claim sees the destination, not the source.
	newOwnerID := owner.ID
	if _, ex := dst.UserByID(owner.ID); ex {
		newOwnerID = newID("USR")
	}
	idMap[owner.ID] = newOwnerID
	if owner.Email != "" {
		if err := s.tenants.ReassignEmail(owner.Email, srcID, dstID, newOwnerID); err != nil {
			fail(c, http.StatusInternalServerError, "Could not move the teacher's account")
			return
		}
	}
	movedOwner := owner
	movedOwner.ID = newOwnerID
	movedOwner.Role = domain.RoleTeacher
	movedOwner.SchoolID = dstID
	movedOwner.ClassID = ""
	if writeFailed(c, dst.SaveUser(movedOwner)) {
		return
	}

	// 6. Archive the workspace read-only and suspend its subscription. It is
	// never deleted automatically.
	srcSchool.Archived = true
	if writeFailed(c, src.SaveSchool(srcSchool)) {
		return
	}
	_ = s.tenants.SetSuspended(srcID, true)

	// 7. Audit in both tenants.
	detail := "Transferred workspace " + srcID + " into school " + dstID +
		" (" + itoa(len(src.Students())) + " students)"
	src.AddAudit(domain.AuditEntry{ID: newID("AUD"), Action: "workspace.transfer.out",
		Actor: currentUser(c).Name, Target: srcID, Detail: detail, Timestamp: now()})
	dst.AddAudit(domain.AuditEntry{ID: newID("AUD"), Action: "workspace.transfer.in",
		Actor: currentUser(c).Name, Target: dstID, Detail: detail, Timestamp: now()})

	sendJSON(c, gin.H{
		"sourceSchoolId": srcID,
		"targetSchoolId": dstID,
		"teacherUserId":  newOwnerID,
		"idMap":          idMap,
		"archived":       true,
	})
}
