package httpapi

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
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
}

var staffRoles = []string{domain.RoleSuperAdmin, domain.RoleSchoolAdmin,
	domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff}

var recordKinds = map[string]recordKind{
	domain.RecordLessons:           {scope: scopeSchool, writers: staffRoles},
	domain.RecordResources:         {scope: scopeClass, writers: staffRoles},
	domain.RecordSafetyCompletions: {scope: scopeStudent},
	domain.RecordCorrections:       {scope: scopeStudent},
	domain.RecordTargets:           {scope: scopeOwner},
	domain.RecordScans:             {scope: scopeStudent, writers: staffRoles},
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
func (s *Server) recordVisible(u domain.User, k recordKind, visible map[string]bool, r domain.Record) bool {
	switch k.scope {
	case scopeClass:
		return u.IsSchoolStaff() || r.ClassID == "" || s.viewsClass(u, r.ClassID)
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
	visible := s.visibleStudents(u)
	out := []json.RawMessage{}
	for _, r := range s.store.Records(kind) {
		if s.recordVisible(u, k, visible, r) {
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
	visible := s.visibleStudents(u)
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
	if prev, ok := s.store.RecordByID(kind, r.ID); ok && !check(prev) {
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
	if writeFailed(c, s.store.SaveRecord(r)) {
		return
	}
	s.audit(c, "record.save", kind+"/"+id, "Saved "+strings.ReplaceAll(kind, "_", " ")+" "+id, "")
	c.Data(http.StatusOK, "application/json", raw)
}

func (s *Server) deleteRecord(c *gin.Context) {
	kind, k, ok := s.recordKindParam(c)
	if !ok {
		return
	}
	u := currentUser(c)
	r, found := s.store.RecordByID(kind, c.Param("id"))
	if !found {
		// already gone: deleting is idempotent so a replayed outbox item
		// does not surface as an error
		sendJSON(c, gin.H{"deleted": c.Param("id")})
		return
	}
	if !s.canWriteRecord(c, u, kind, k, r) {
		return
	}
	if writeFailed(c, s.store.DeleteRecord(kind, r.ID)) {
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
	r, ok := s.store.RecordByID(domain.RecordScans, c.Param("id"))
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
	if writeFailed(c, s.store.SaveScanImage(r.ID, ct, data)) {
		return
	}
	sendJSON(c, gin.H{"stored": r.ID, "bytes": len(data)})
}

func (s *Server) getScanImage(c *gin.Context) {
	u := currentUser(c)
	r, ok := s.store.RecordByID(domain.RecordScans, c.Param("id"))
	if !ok || !s.recordVisible(u, recordKinds[domain.RecordScans], s.visibleStudents(u), r) {
		fail(c, http.StatusNotFound, "Scan not found")
		return
	}
	ct, data, ok := s.store.ScanImage(r.ID)
	if !ok {
		fail(c, http.StatusNotFound, "No image uploaded for this scan")
		return
	}
	c.Header("Cache-Control", "private, max-age=86400")
	c.Data(http.StatusOK, ct, data)
}
