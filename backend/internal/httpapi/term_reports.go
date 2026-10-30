package httpapi

import (
	"encoding/json"
	"net/http"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// A term report (domain.RecordTermReports) is written in two hands:
//
//   - the class teacher: remark, conduct, attitude, interest — while the
//     report is a draft, for their own class (the scope check);
//   - a school leader: the headteacher's remark, and approval, which freezes
//     a copy of the whole card ("snapshot") so later mark changes cannot
//     alter a card parents already have. Only a leader can reopen it.
//
// Families read a report only once it is approved.

// termReportFields are the parts of the client's JSON the rules look at.
type termReportFields struct {
	Status        string          `json:"status"`
	Year          string          `json:"year"`
	Term          string          `json:"term"`
	TeacherRemark string          `json:"teacherRemark"`
	Conduct       string          `json:"conduct"`
	Attitude      string          `json:"attitude"`
	Interest      string          `json:"interest"`
	HeadRemark    string          `json:"headRemark"`
	ApprovedBy    string          `json:"approvedBy"`
	ApprovedAt    string          `json:"approvedAt"`
	Snapshot      json.RawMessage `json:"snapshot"`
}

const (
	termReportDraft    = "draft"
	termReportApproved = "approved"
	// maxRemark keeps a remark to what fits on the card.
	maxRemark = 600
)

func termReportOf(r domain.Record) termReportFields {
	var f termReportFields
	_ = json.Unmarshal(r.Data, &f)
	return f
}

func isApprovedReport(r domain.Record) bool {
	return termReportOf(r).Status == termReportApproved
}

func isLeader(u domain.User) bool {
	return u.Role == domain.RoleSuperAdmin || u.Role == domain.RoleSchoolAdmin ||
		u.Role == domain.RoleHeadteacher
}

// termReportReadable: staff see drafts; families only approved reports.
func termReportReadable(u domain.User, r domain.Record) bool {
	if u.Role == domain.RoleParent || u.Role == domain.RoleStudent {
		return isApprovedReport(r)
	}
	return true
}

func checkTermReport(s *Server, c *gin.Context, u domain.User, prev *domain.Record, next *domain.Record) bool {
	n := termReportOf(*next)
	var p termReportFields
	if prev != nil {
		p = termReportOf(*prev)
	}
	if n.Status != termReportDraft && n.Status != termReportApproved {
		fail(c, http.StatusBadRequest, "status must be draft or approved")
		return false
	}
	for _, t := range []string{n.TeacherRemark, n.HeadRemark, n.Conduct, n.Attitude, n.Interest} {
		if len(t) > maxRemark {
			fail(c, http.StatusBadRequest, "remarks are limited to 600 characters")
			return false
		}
	}
	if !isLeader(u) {
		switch {
		case p.Status == termReportApproved:
			fail(c, http.StatusConflict, "This report is approved; ask the headteacher to reopen it")
			return false
		case n.Status != termReportDraft:
			fail(c, http.StatusForbidden, "Only the headteacher can approve a report")
			return false
		case n.HeadRemark != p.HeadRemark:
			fail(c, http.StatusForbidden, "Only the headteacher can write the headteacher's remark")
			return false
		}
		return restamp(c, next, func(m map[string]any) {
			delete(m, "snapshot")
			delete(m, "approvedBy")
			delete(m, "approvedAt")
		})
	}
	// A leader: an approved report changes only by being reopened.
	if p.Status == termReportApproved && n.Status == termReportApproved {
		if !sameReport(p, n) {
			fail(c, http.StatusConflict, "This report is approved; reopen it before changing it")
			return false
		}
		next.Data = prev.Data // a replay of the same approval: keep the original stamp
		return true
	}
	if n.Status == termReportApproved {
		if len(n.Snapshot) == 0 || n.Snapshot[0] != '{' {
			fail(c, http.StatusBadRequest, "approving needs the card's snapshot")
			return false
		}
		approvedAt := now()
		if !restamp(c, next, func(m map[string]any) {
			m["approvedBy"] = u.Name
			m["approvedAt"] = approvedAt
		}) {
			return false
		}
		// Released to the family: tell the parents (student-scoped notice).
		s.notify(c, "", domain.NotifReportCard, n.Term+" report card is ready",
			"The "+n.Term+" ("+n.Year+") report card has been approved by the school.", next.StudentID)
		return true
	}
	return restamp(c, next, func(m map[string]any) {
		delete(m, "snapshot")
		delete(m, "approvedBy")
		delete(m, "approvedAt")
	})
}

// sameReport: the parts a re-sent approval may not change.
func sameReport(a, b termReportFields) bool {
	return a.TeacherRemark == b.TeacherRemark && a.Conduct == b.Conduct &&
		a.Attitude == b.Attitude && a.Interest == b.Interest &&
		a.HeadRemark == b.HeadRemark
}

// restamp rewrites the stored JSON with server-set fields.
func restamp(c *gin.Context, r *domain.Record, edit func(map[string]any)) bool {
	var m map[string]any
	if err := json.Unmarshal(r.Data, &m); err != nil {
		fail(c, http.StatusBadRequest, "Body must be a JSON object")
		return false
	}
	edit(m)
	data, err := json.Marshal(m)
	if err != nil {
		fail(c, http.StatusBadRequest, "Body must be a JSON object")
		return false
	}
	r.Data = data
	return true
}
