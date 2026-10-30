package httpapi

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// Collections the server stores for the client without modelling them (see
// domain.Record): GET lists the kind as the caller may see it, PUT writes one
// row, DELETE removes one. Each kind declares who may write and how reads are
// scoped, using the studentId/classId fields of the client's own JSON.

type recordScope int

const (
	scopeSchool  recordScope = iota // everyone signed in
	scopeClass                      // staff, plus users who view the row's class
	scopeStudent                    // users who may see the row's student
	scopeOwner                      // only the user who wrote it
)

type recordKind struct {
	scope recordScope
	// roles that may write; empty means any signed-in user (still bound by
	// scope: a pupil can only write rows about themselves)
	writers []string
	// readable, when set, further limits which in-scope rows a user sees.
	readable func(u domain.User, r domain.Record) bool
	// check, when set, applies the kind's own write rules after the scope
	// checks. It may rewrite the stored JSON (server stamps) and returns
	// false after failing the request.
	check func(s *Server, c *gin.Context, u domain.User, prev *domain.Record, next *domain.Record) bool
}

var staffRoles = []string{domain.RoleSuperAdmin, domain.RoleSchoolAdmin,
	domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff}

var recordKinds = map[string]recordKind{
	domain.RecordLessons:               {scope: scopeSchool, writers: staffRoles},
	domain.RecordResources:             {scope: scopeClass, writers: staffRoles},
	domain.RecordSafetyCompletions:     {scope: scopeStudent},
	domain.RecordCorrections:           {scope: scopeStudent},
	domain.RecordTargets:               {scope: scopeOwner},
	domain.RecordScans:                 {scope: scopeStudent, writers: staffRoles},
	domain.RecordAssignmentSubmissions: {scope: scopeStudent, writers: staffRoles},
	// Owner-scoped: the reading and the teacher's confirmation of it belong to
	// the person who made them, on every device they sign in from, and to
	// nobody else. OwnerID is stamped here from the session (never taken from
	// the body) and checked again against the stored row before an overwrite,
	// so one teacher cannot read or amend another's confirmation.
	domain.RecordOcrJobs: {scope: scopeOwner, writers: staffRoles},
	// The same leaders who may promote a student one at a time.
	domain.RecordPromotions: {scope: scopeStudent, writers: []string{
		domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher}},
	// Teachers write their own class's; leaders approve. Families see a
	// report only once it is approved.
	domain.RecordTermReports: {scope: scopeStudent, writers: []string{
		domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher},
		readable: termReportReadable, check: checkTermReport},
}

// recordFields are the fields lifted out of a record's JSON.
type recordFields struct {
	ID        string `json:"id"`
	StudentID string `json:"studentId"`
	ClassID   string `json:"classId"`
}

func (s *Server) recordKindParam(c *gin.Context) (string, recordKind, bool) {
	kind := c.Param("kind")
	k, ok := recordKinds[kind]
	if !ok {
		fail(c, http.StatusNotFound, "Unknown collection")
		return "", k, false
	}
	return kind, k, true
}

// recordVisible applies the kind's read scope to one row.
func (s *Server) recordVisible(c *gin.Context, u domain.User, k recordKind, visible map[string]bool, r domain.Record) bool {
	switch k.scope {
	case scopeClass:
		return u.IsSchoolStaff() || r.ClassID == "" || s.viewsClass(c, u, r.ClassID)
	case scopeStudent:
		return visible == nil || visible[r.StudentID]
	case scopeOwner:
		return r.OwnerID == u.ID
	}
	return true
}

func (s *Server) listRecords(c *gin.Context) {
	kind, k, ok := s.recordKindParam(c)
	if !ok {
		return
	}
	u := currentUser(c)
	visible := s.visibleStudents(c, u)
	out := []json.RawMessage{}
	for _, r := range s.db(c).Records(kind) {
		if s.recordVisible(c, u, k, visible, r) && (k.readable == nil || k.readable(u, r)) {
			out = append(out, r.Data)
		}
	}
	sendJSON(c, out)
}

func roleIn(role string, roles []string) bool {
	for _, r := range roles {
		if r == role {
			return true
		}
	}
	return false
}

// canWriteRecord checks the writer roles and that the row stays inside what
// the caller may see, both as sent and as it was before.
func (s *Server) canWriteRecord(c *gin.Context, u domain.User, kind string, k recordKind, r domain.Record) bool {
	if len(k.writers) > 0 && !roleIn(u.Role, k.writers) {
		fail(c, http.StatusForbidden, "Your role cannot change this")
		return false
	}
	visible := s.visibleStudents(c, u)
	check := func(r domain.Record) bool {
		switch k.scope {
		case scopeStudent:
			if r.StudentID == "" || (visible != nil && !visible[r.StudentID]) {
				fail(c, http.StatusForbidden, "Not your student")
				return false
			}
		case scopeOwner:
			if r.OwnerID != u.ID {
				fail(c, http.StatusForbidden, "Not your record")
				return false
			}
		case scopeClass:
			if u.Role == domain.RoleTeacher && r.ClassID != "" && r.ClassID != u.ClassID {
				fail(c, http.StatusForbidden, "Not your class")
				return false
			}
		}
		return true
	}
	if !check(r) {
		return false
	}
	if prev, ok := s.db(c).RecordByID(kind, r.ID); ok && !check(prev) {
		return false
	}
	return true
}

func (s *Server) saveRecord(c *gin.Context) {
	kind, k, ok := s.recordKindParam(c)
	if !ok {
		return
	}
	u := currentUser(c)
	raw, err := io.ReadAll(c.Request.Body)
	if err != nil {
		if isBodyTooLarge(err) {
			fail(c, http.StatusRequestEntityTooLarge, "Request body too large")
			return
		}
		fail(c, http.StatusBadRequest, "Could not read the request body")
		return
	}
	raw = bytes.TrimSpace(raw)
	var f recordFields
	if len(raw) == 0 || raw[0] != '{' || json.Unmarshal(raw, &f) != nil {
		fail(c, http.StatusBadRequest, "Body must be a JSON object")
		return
	}
	id := c.Param("id")
	// '#' is the page separator in submissionPageKey. A record whose own id
	// contained one ("ASUB-1#2") would share a photo key with page 2 of
	// another submission, letting its /image route read or replace that page.
	if strings.Contains(id, "#") {
		fail(c, http.StatusBadRequest, "id may not contain '#'")
		return
	}
	if f.ID != "" && f.ID != id {
		fail(c, http.StatusBadRequest, "id in the body does not match the URL")
		return
	}
	r := domain.Record{
		Kind: kind, ID: id, StudentID: f.StudentID, ClassID: f.ClassID,
		UpdatedAt: now(), Data: json.RawMessage(raw),
	}
	if k.scope == scopeOwner {
		r.OwnerID = u.ID
	}
	if !s.canWriteRecord(c, u, kind, k, r) {
		return
	}
	if k.check != nil {
		var prev *domain.Record
		if p, ok := s.db(c).RecordByID(kind, id); ok {
			prev = &p
		}
		if !k.check(s, c, u, prev, &r) {
			return
		}
	}
	if writeFailed(c, s.db(c).SaveRecord(r)) {
		return
	}
	s.audit(c, "record.save", kind+"/"+id, "Saved "+strings.ReplaceAll(kind, "_", " ")+" "+id, "")
	c.Data(http.StatusOK, "application/json", r.Data)
}

func (s *Server) deleteRecord(c *gin.Context) {
	kind, k, ok := s.recordKindParam(c)
	if !ok {
		return
	}
	u := currentUser(c)
	r, found := s.db(c).RecordByID(kind, c.Param("id"))
	if !found {
		// already gone: deleting is idempotent so a replayed outbox item
		// does not surface as an error
		sendJSON(c, gin.H{"deleted": c.Param("id")})
		return
	}
	if !s.canWriteRecord(c, u, kind, k, r) {
		return
	}
	if k.readable != nil && kind == domain.RecordTermReports && isApprovedReport(r) {
		fail(c, http.StatusConflict, "An approved report can't be deleted; reopen it first")
		return
	}
	if writeFailed(c, s.db(c).DeleteRecord(kind, r.ID)) {
		return
	}
	s.audit(c, "record.delete", kind+"/"+r.ID, "Removed "+strings.ReplaceAll(kind, "_", " ")+" "+r.ID, "")
	sendJSON(c, gin.H{"deleted": r.ID})
}

// maxScanImage caps one scan photo. The app resizes captures to at most
// 2400×3200 at quality 90, which lands well under this.
const maxScanImage = 8 << 20

// putScanImage stores the photo for a scan page that already has a record.
func (s *Server) putScanImage(c *gin.Context) {
	u := currentUser(c)
	k := recordKinds[domain.RecordScans]
	r, ok := s.db(c).RecordByID(domain.RecordScans, c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Scan not found")
		return
	}
	if !s.canWriteRecord(c, u, domain.RecordScans, k, r) {
		return
	}
	ct := c.ContentType()
	if !strings.HasPrefix(ct, "image/") {
		fail(c, http.StatusUnsupportedMediaType, "Send the scan as an image")
		return
	}
	data, err := io.ReadAll(c.Request.Body)
	if err != nil {
		if isBodyTooLarge(err) {
			fail(c, http.StatusRequestEntityTooLarge, "Image too large")
			return
		}
		fail(c, http.StatusBadRequest, "Could not read the image")
		return
	}
	if len(data) == 0 {
		fail(c, http.StatusBadRequest, "Empty image")
		return
	}
	if writeFailed(c, s.db(c).SaveScanImage(r.ID, ct, data)) {
		return
	}
	sendJSON(c, gin.H{"stored": r.ID, "bytes": len(data)})
}

func (s *Server) getScanImage(c *gin.Context) {
	u := currentUser(c)
	r, ok := s.db(c).RecordByID(domain.RecordScans, c.Param("id"))
	if !ok || !s.recordVisible(c, u, recordKinds[domain.RecordScans], s.visibleStudents(c, u), r) {
		fail(c, http.StatusNotFound, "Scan not found")
		return
	}
	ct, data, ok := s.db(c).ScanImage(r.ID)
	if !ok {
		fail(c, http.StatusNotFound, "No image uploaded for this scan")
		return
	}
	c.Header("Cache-Control", "private, max-age=86400")
	c.Data(http.StatusOK, ct, data)
}

// submissionPageKey namespaces one page's photo inside the shared scan_images
// store.
//
// An assignment submission carries any number of pages, so its photos cannot
// be keyed by the submission id alone — that would overwrite page 1 with page
// 2 on every upload. Both stores already key images by an arbitrary string and
// neither validates it against a record id, so "<submissionId>#<pageNumber>"
// namespaces the pages without a migration. The separator cannot collide with
// a generated id: submission ids are minted as "ASUB-<digits>" and page
// numbers are integers, so no legitimate id contains a '#'.
func submissionPageKey(id string, page int) string {
	return id + "#" + itoa(page)
}

// parseSubmissionPage reads and validates the page number from the URL.
func parseSubmissionPage(c *gin.Context) (int, bool) {
	n, err := strconv.Atoi(c.Param("page"))
	if err != nil || n < 1 || n > 999 {
		fail(c, http.StatusBadRequest, "Invalid page number")
		return 0, false
	}
	return n, true
}

// putSubmissionPageImage stores the photo for one page of a submission that
// already has a record. Mirrors putScanImage exactly — same size cap, same
// content-type rule, same write scope — so a submission's page can never be
// written by someone who could not write the submission itself.
func (s *Server) putSubmissionPageImage(c *gin.Context) {
	u := currentUser(c)
	kind := domain.RecordAssignmentSubmissions
	k := recordKinds[kind]
	r, ok := s.db(c).RecordByID(kind, c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Submission not found")
		return
	}
	page, okPage := parseSubmissionPage(c)
	if !okPage {
		return
	}
	if !s.canWriteRecord(c, u, kind, k, r) {
		return
	}
	ct := c.ContentType()
	if !strings.HasPrefix(ct, "image/") {
		fail(c, http.StatusUnsupportedMediaType, "Send the page as an image")
		return
	}
	data, err := io.ReadAll(c.Request.Body)
	if err != nil {
		if isBodyTooLarge(err) {
			fail(c, http.StatusRequestEntityTooLarge, "Image too large")
			return
		}
		fail(c, http.StatusBadRequest, "Could not read the image")
		return
	}
	if len(data) == 0 {
		fail(c, http.StatusBadRequest, "Empty image")
		return
	}
	// No explicit size check here: limitRequestBody already caps every PUT
	// ending in "/image" at maxScanImage and turns an overflow into 413.
	key := submissionPageKey(r.ID, page)
	if writeFailed(c, s.db(c).SaveScanImage(key, ct, data)) {
		return
	}
	sendJSON(c, gin.H{"stored": r.ID, "page": page, "bytes": len(data)})
}

func (s *Server) getSubmissionPageImage(c *gin.Context) {
	u := currentUser(c)
	kind := domain.RecordAssignmentSubmissions
	r, ok := s.db(c).RecordByID(kind, c.Param("id"))
	if !ok || !s.recordVisible(c, u, recordKinds[kind], s.visibleStudents(c, u), r) {
		fail(c, http.StatusNotFound, "Submission not found")
		return
	}
	page, okPage := parseSubmissionPage(c)
	if !okPage {
		return
	}
	ct, data, ok := s.db(c).ScanImage(submissionPageKey(r.ID, page))
	if !ok {
		fail(c, http.StatusNotFound, "No image uploaded for this page")
		return
	}
	c.Header("Cache-Control", "private, max-age=86400")
	c.Data(http.StatusOK, ct, data)
}
