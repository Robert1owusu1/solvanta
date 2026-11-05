package httpapi

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// Data-subject rights (data protection). A signed-in user can download a copy
// of their own personal data, and request erasure of their account.

// meExport returns the requesting user's personal data as a JSON download:
// their account, and — for a student or parent — the records SOLVANTA holds
// about them / their children. Passwords are never included (json:"-").
func (s *Server) meExport(c *gin.Context) {
	u := currentUser(c)
	out := gin.H{"exportedAt": now(), "account": u}

	var studentIDs []string
	switch u.Role {
	case domain.RoleStudent:
		studentIDs = []string{stringToStudentID(u.ID)}
	case domain.RoleParent:
		studentIDs = u.StudentIDs
	}

	if len(studentIDs) > 0 {
		db := s.db(c)
		subs := db.Submissions()
		att := db.Attendance()
		invoices := db.Invoices()
		payments := db.Payments()

		kids := make([]gin.H, 0, len(studentIDs))
		for _, sid := range studentIDs {
			st, ok := db.StudentByID(sid)
			if !ok {
				continue
			}
			var mySubs []domain.Submission
			for _, x := range subs {
				if x.StudentID == sid {
					mySubs = append(mySubs, x)
				}
			}
			var myAtt []domain.AttendanceRecord
			for _, x := range att {
				if x.StudentID == sid {
					myAtt = append(myAtt, x)
				}
			}
			var myInv []domain.Invoice
			for _, x := range invoices {
				if x.StudentID == sid {
					myInv = append(myInv, x)
				}
			}
			var myPay []domain.Payment
			for _, x := range payments {
				if x.StudentID == sid {
					myPay = append(myPay, x)
				}
			}
			kids = append(kids, gin.H{
				"student":    st,
				"results":    nonNilLists(mySubs),
				"attendance": nonNilLists(myAtt),
				"invoices":   nonNilLists(myInv),
				"payments":   nonNilLists(myPay),
				"gate":       db.GateForStudent(sid),
			})
		}
		out["students"] = kids
	}

	s.audit(c, "me.export", u.ID, "Exported own data", "")
	c.Header("Content-Disposition", `attachment; filename="my-solvanta-data.json"`)
	sendJSON(c, out)
}

// meDelete erases the requesting user's own account (right to erasure). It needs
// the current password, and refuses accounts whose removal would orphan data or
// lock a school out: the platform operator, an independent workspace owner (the
// workspace holds children's data — transfer or close it first), and the last
// remaining admin of a school.
func (s *Server) meDelete(c *gin.Context) {
	u := currentUser(c)
	var body struct {
		Password string `json:"password"`
	}
	if !bind(c, &body) {
		return
	}
	if !verifyPassword(u.Password, body.Password) {
		fail(c, http.StatusUnauthorized, "Password is incorrect")
		return
	}
	if u.IsSuperAdmin() {
		fail(c, http.StatusConflict, "The platform operator account cannot be self-deleted")
		return
	}
	school := s.db(c).School()
	if school.IsIndependent() && school.OwnerUserID == u.ID {
		fail(c, http.StatusConflict,
			"Your workspace holds pupils' data. Transfer it to a school or ask for it to be closed first.")
		return
	}
	if u.Role == domain.RoleSchoolAdmin {
		admins := 0
		for _, other := range s.db(c).Users() {
			if other.Role == domain.RoleSchoolAdmin {
				admins++
			}
		}
		if admins <= 1 {
			fail(c, http.StatusConflict,
				"You are the only school admin. Appoint another admin before deleting your account.")
			return
		}
	}

	if writeFailed(c, s.db(c).DeleteUser(u.ID)) {
		return
	}
	if u.Email != "" {
		_ = s.tenants.ForgetEmail(u.Email)
	}
	// End the current session immediately.
	if tc, ok := s.claimsFromRequest(c); ok {
		s.revoke(tc.Jti, time.Unix(tc.Exp, 0))
	}
	s.audit(c, "me.delete", u.ID, "Deleted own account ("+u.Role+")", "")
	sendJSON(c, gin.H{"deleted": true})
}
