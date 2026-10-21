package store

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"

	"solvanta/backend/internal/domain"
)

// hash returns the bcrypt hash for a password. Cost is kept low (4) only for
// demo seeding speed; account creation uses runtime defaults.
func hash(pw string) string {
	h, err := bcrypt.GenerateFromPassword([]byte(pw), bcrypt.MinCost)
	if err != nil {
		panic(err)
	}
	return string(h)
}

// pw returns a bcrypt hash of the demo password, shorthand for the seed.
func pw(plain string) string { return hash(plain) }

// seedRefDate anchors every relative date in the demo dataset.
//
// The seed used to take these from time.Now(), which is idempotent only within
// a single calendar day: each boot on a new date wrote gate events under
// brand-new IDs (GATE-<yesterday>-NNN) and shifted the five-weekday attendance
// window forward, and neither collides with what the previous day's boot
// inserted. So the tables grew a little every day and drifted away from the
// client's seed — LocalStore computes its copy once at first launch and then
// freezes it in SharedPreferences — meaning the "local seed == remote store"
// contract the parity suite checks could not hold for more than a day.
//
// A fixed anchor makes every boot emit byte-identical rows, so re-seeding is
// genuinely idempotent. Keep it inside the seeded term (2026-09-07..2026-12-18).
const seedRefDate = "2026-09-30"

// seedRef is seedRefDate parsed once. The constant is the only input, so this
// cannot fail without someone editing it into a non-date — and the resulting
// nonsense dates are exactly what the seed tests would then flag.
var seedRef, _ = time.Parse("2006-01-02", seedRefDate)

// seedYesterday is the anchor minus one day: "yesterday" for gate events,
// notification timestamps and the end of the attendance window.
func seedYesterday() time.Time { return seedRef.AddDate(0, 0, -1) }

func (m *Memory) seed() { Seed(m) }

// Seed writes the development dataset into any Store. It mirrors the same
// users/classes/students/attendance/gate/bank/assessments/submissions/etc. that
// the Flutter client seeds into LocalStore, so in-memory and PostgreSQL-backed
// servers share one demo dataset with identical demo logins.
func Seed(st Store) {
	st.SaveSchool(domain.School{
		ID: "SCH-001", Name: "Accra Junior High School",
		Motto: "Knowledge, Character, Service", Address: "12 Independence Avenue, Accra",
		Phone: "0302-000-000", Email: "info@accrajhs.school.gh", Region: "Greater Accra",
	})
	st.SaveTerm(domain.SchoolTerm{Year: "2026/2027", Name: "Term 1", Start: "2026-09-07", End: "2026-12-18"})

	seedUsers := []domain.User{
		{ID: "USR-SUPER", Name: "Solvanta Platform", Email: "super@solvanta.app", Phone: "0240000000", Password: pw("super123"), Role: domain.RoleSuperAdmin},
		{ID: "USR-ADM-001", Name: "Mrs. Adjoa Amankwah", Email: "admin@solvanta.app", Phone: "0241000001", Password: pw("admin123"), Role: domain.RoleSchoolAdmin, SchoolID: "SCH-001"},
		{ID: "USR-HRT-001", Name: "Kwame Boateng", Email: "head@school.gh", Phone: "0242000002", Password: pw("head123"), Role: domain.RoleHeadteacher, SchoolID: "SCH-001"},
		{ID: "USR-TCH-001", Name: "Ms. Efua Mensah", Email: "efua.mensah@school.gh", Phone: "0243000003", Password: pw("teacher123"), Role: domain.RoleTeacher, SchoolID: "SCH-001", ClassID: "JHS2A"},
		{ID: "USR-PRN-001", Name: "Ama Owusu", Email: "ama.owusu@school.gh", Phone: "0244000004", Password: pw("parent123"), Role: domain.RoleParent, SchoolID: "SCH-001", StudentIDs: []string{"STU-001"}},
		{ID: "USR-PRN-002", Name: "Akua Boaduwaa", Email: "akua.boaduwaa@school.gh", Phone: "0246300003", Password: pw("parent123"), Role: domain.RoleParent, SchoolID: "SCH-001", StudentIDs: []string{"STU-002"}},
		{ID: "USR-PRN-003", Name: "Adwoa Adjei", Email: "adwoa.adjei@school.gh", Phone: "0246400001", Password: pw("parent123"), Role: domain.RoleParent, SchoolID: "SCH-001", StudentIDs: []string{"STU-003"}},
		{ID: "USR-PRN-004", Name: "Kwabena Serwaa", Email: "kwabena.serwaa@school.gh", Phone: "0246500001", Password: pw("parent123"), Role: domain.RoleParent, SchoolID: "SCH-001", StudentIDs: []string{"STU-004"}},
		{ID: "USR-PRN-005", Name: "Nana Darko", Email: "nana.darko@school.gh", Phone: "0246600001", Password: pw("parent123"), Role: domain.RoleParent, SchoolID: "SCH-001", StudentIDs: []string{"STU-005"}},
		{ID: "USR-PRN-006", Name: "Efua Adwoa", Email: "efua.adwoa@school.gh", Phone: "0246700001", Password: pw("parent123"), Role: domain.RoleParent, SchoolID: "SCH-001", StudentIDs: []string{"STU-006"}},
		{ID: "USR-PRN-007", Name: "Esi Manu", Email: "esi.manu@school.gh", Phone: "0246800001", Password: pw("parent123"), Role: domain.RoleParent, SchoolID: "SCH-001", StudentIDs: []string{"STU-007"}},
		{ID: "USR-PRN-008", Name: "Ama Amponsah", Email: "ama.amponsah@school.gh", Phone: "0246900001", Password: pw("parent123"), Role: domain.RoleParent, SchoolID: "SCH-001", StudentIDs: []string{"STU-008"}},
		{ID: "USR-STU-001", Name: "Kojo Owusu", Email: "kojo.owusu@school.gh", Phone: "0245000005", Password: pw("student123"), Role: domain.RoleStudent, SchoolID: "SCH-001", ClassID: "JHS2A"},
		{ID: "USR-STF-001", Name: "Mr. Yaw Asante", Email: "staff@school.gh", Phone: "0247000007", Password: pw("staff123"), Role: domain.RoleStaff, SchoolID: "SCH-001"},
	}

	// Pass 1: users without student links (students do not exist yet, but a
	// linked parent would reference them via user_students — circular FK).
	for _, u := range seedUsers {
		u.StudentIDs = nil
		st.SaveUser(u)
	}

	for _, c := range []domain.ClassRoom{
		{ID: "JHS1A", Name: "JHS 1", Stream: "A"},
		{ID: "JHS1B", Name: "JHS 1", Stream: "B"},
		{ID: "JHS2A", Name: "JHS 2", Stream: "A", TeacherID: "USR-TCH-001"},
		{ID: "JHS2B", Name: "JHS 2", Stream: "B"},
		{ID: "JHS3A", Name: "JHS 3", Stream: "A"},
		{ID: "JHS3B", Name: "JHS 3", Stream: "B"},
	} {
		st.SaveClass(c)
	}

	for _, s := range []domain.Student{
		{
			ID: "STU-001", FirstName: "Kojo", LastName: "Owusu", Gender: "M",
			DateOfBirth: "2010-04-12", AdmissionDate: "2023-09-04", AdmissionNo: "S-2023-001",
			ClassID: "JHS2A", SchoolID: "SCH-001", ParentUserID: "USR-PRN-001",
			Guardians:         []domain.Person{{Name: "Ama Owusu", Phone: "0244000004", Relation: "Mother"}, {Name: "Kofi Owusu", Phone: "0246100006", Relation: "Father"}},
			EmergencyContacts: []domain.Person{{Name: "Yaw Amankwah", Phone: "0246200002", Relation: "Uncle"}},
			AuthorizedPickup:  []domain.Person{{Name: "Ama Owusu", Phone: "0244000004", Relation: "Mother"}, {Name: "Yaw Amankwah", Phone: "0246200002", Relation: "Uncle"}},
		},
		{
			ID: "STU-002", FirstName: "Akosua", LastName: "Boaduwaa", Gender: "F",
			DateOfBirth: "2010-06-03", AdmissionDate: "2023-09-04", AdmissionNo: "S-2023-002",
			ClassID: "JHS2A", SchoolID: "SCH-001", ParentUserID: "USR-PRN-002",
			Guardians:         []domain.Person{{Name: "Akua Boaduwaa", Phone: "0246300003", Relation: "Mother"}},
			EmergencyContacts: []domain.Person{{Name: "Kwame Boaduwaa", Phone: "0246300004", Relation: "Father"}},
			AuthorizedPickup:  []domain.Person{{Name: "Akua Boaduwaa", Phone: "0246300003", Relation: "Mother"}},
		},
		{
			ID: "STU-003", FirstName: "Kwabena", LastName: "Adjei", Gender: "M",
			DateOfBirth: "2010-01-20", AdmissionDate: "2023-09-04", AdmissionNo: "S-2023-003",
			ClassID: "JHS2A", SchoolID: "SCH-001", ParentUserID: "USR-PRN-003",
			Guardians:        []domain.Person{{Name: "Adwoa Adjei", Phone: "0246400001", Relation: "Mother"}},
			AuthorizedPickup: []domain.Person{{Name: "Adwoa Adjei", Phone: "0246400001", Relation: "Mother"}, {Name: "Sam Adjei", Phone: "0246400002", Relation: "Brother"}},
		},
		{
			ID: "STU-004", FirstName: "Abena", LastName: "Serwaa", Gender: "F",
			DateOfBirth: "2010-09-15", AdmissionDate: "2023-09-04", AdmissionNo: "S-2023-004",
			ClassID: "JHS2A", SchoolID: "SCH-001", ParentUserID: "USR-PRN-004",
			Guardians:        []domain.Person{{Name: "Kwabena Serwaa", Phone: "0246500001", Relation: "Father"}},
			AuthorizedPickup: []domain.Person{{Name: "Kwabena Serwaa", Phone: "0246500001", Relation: "Father"}},
		},
		{
			ID: "STU-005", FirstName: "Yaw", LastName: "Darko", Gender: "M",
			DateOfBirth: "2011-02-28", AdmissionDate: "2023-09-04", AdmissionNo: "S-2023-005",
			ClassID: "JHS2A", SchoolID: "SCH-001", ParentUserID: "USR-PRN-005",
			Guardians:        []domain.Person{{Name: "Nana Darko", Phone: "0246600001", Relation: "Mother"}},
			AuthorizedPickup: []domain.Person{{Name: "Nana Darko", Phone: "0246600001", Relation: "Mother"}},
		},
		{
			ID: "STU-006", FirstName: "Maame", LastName: "Adwoa", Gender: "F",
			DateOfBirth: "2010-11-07", AdmissionDate: "2023-09-04", AdmissionNo: "S-2023-006",
			ClassID: "JHS2A", SchoolID: "SCH-001", ParentUserID: "USR-PRN-006",
			Guardians:        []domain.Person{{Name: "Efua Adwoa", Phone: "0246700001", Relation: "Mother"}},
			AuthorizedPickup: []domain.Person{{Name: "Efua Adwoa", Phone: "0246700001", Relation: "Mother"}},
		},
		{
			ID: "STU-007", FirstName: "Kofi", LastName: "Manu", Gender: "M",
			DateOfBirth: "2012-03-19", AdmissionDate: "2024-09-02", AdmissionNo: "S-2024-001",
			ClassID: "JHS1A", SchoolID: "SCH-001", ParentUserID: "USR-PRN-007",
			Guardians:        []domain.Person{{Name: "Esi Manu", Phone: "0246800001", Relation: "Mother"}},
			AuthorizedPickup: []domain.Person{{Name: "Esi Manu", Phone: "0246800001", Relation: "Mother"}},
		},
		{
			ID: "STU-008", FirstName: "Esi", LastName: "Amponsah", Gender: "F",
			DateOfBirth: "2012-01-11", AdmissionDate: "2024-09-02", AdmissionNo: "S-2024-002",
			ClassID: "JHS1A", SchoolID: "SCH-001", ParentUserID: "USR-PRN-008",
			Guardians:        []domain.Person{{Name: "Ama Amponsah", Phone: "0246900001", Relation: "Mother"}},
			AuthorizedPickup: []domain.Person{{Name: "Ama Amponsah", Phone: "0246900001", Relation: "Mother"}},
		},
	} {
		st.SaveStudent(s)
	}

	// Pass 2: re-save the linked accounts so user_students resolves against the
	// students created above.
	for _, u := range seedUsers {
		if len(u.StudentIDs) > 0 {
			st.SaveUser(u)
		}
	}

	days := lastWeekdayDates(5)
	jhs2a := []string{"STU-001", "STU-002", "STU-003", "STU-004", "STU-005", "STU-006"}
	var att []domain.AttendanceRecord
	for d, day := range days {
		for i, sid := range jhs2a {
			status := domain.AttPresent
			switch (i*3 + d*2) % 10 {
			case 7:
				status = domain.AttExcused
			case 8:
				status = domain.AttAbsent
			case 9:
				status = domain.AttLate
			}
			checkIn := "07:4" + string(rune('0'+i%5))
			if status == domain.AttAbsent {
				checkIn = ""
			}
			att = append(att, domain.AttendanceRecord{
				ID: "ATT-" + day + "-" + sid, StudentID: sid, ClassID: "JHS2A", Date: day,
				Status: status, CheckIn: checkIn,
			})
		}
	}
	st.SaveAttendance(att)

	yes := seedYesterday().Format("2006-01-02")
	for _, e := range []domain.GateEvent{
		{ID: "GATE-" + yes + "-001", StudentID: "STU-001", Type: domain.GateArrival, Time: "07:40", Date: yes, Reporter: "Ms. Efua Mensah", Detail: "Arrival verified at gate"},
		{ID: "GATE-" + yes + "-002", StudentID: "STU-002", Type: domain.GateArrival, Time: "07:42", Date: yes, Reporter: "Ms. Efua Mensah", Detail: "Arrival verified at gate"},
		{ID: "GATE-" + yes + "-003", StudentID: "STU-001", Type: domain.GatePickupAuthorized, Time: "14:30", Date: yes, Reporter: "Gate Officer", Person: "Ama Owusu", Detail: "Pickup verified against authorized list"},
		{ID: "GATE-" + yes + "-004", StudentID: "STU-003", Type: domain.GatePickupAuthorized, Time: "14:35", Date: yes, Reporter: "Gate Officer", Person: "Adwoa Adjei", Detail: "Pickup verified against authorized list"},
		{ID: "GATE-" + yes + "-005", StudentID: "STU-004", Type: domain.GateEarlyDeparture, Time: "12:10", Date: yes, Reporter: "Ms. Efua Mensah", Detail: "Early departure — documented reason: medical"},
	} {
		st.AddGateEvent(e)
	}

	questions := []domain.Question{
		{ID: "Q-MATH-001", Type: domain.QTypeMCQ, SubjectID: "MATH", ClassID: "JHS2A", Topic: "Fractions", Difficulty: 1, CognitiveLevel: "Knowledge", Marks: 2, Stem: "Which fraction is equivalent to 1/2?", Options: []string{"2/4", "2/3", "3/4", "1/3"}, CorrectAnswer: "2/4", Explanation: "Multiplying numerator and denominator of 1/2 by 2 gives 2/4."},
		{ID: "Q-MATH-002", Type: domain.QTypeMCQ, SubjectID: "MATH", ClassID: "JHS2A", Topic: "Fractions", Difficulty: 2, CognitiveLevel: "Application", Marks: 3, Stem: "A rope is 3/4 m long. Half of it is used. What length is left?", Options: []string{"3/8 m", "1/4 m", "1/2 m", "3/2 m"}, CorrectAnswer: "3/8 m", Explanation: "3/4 × 1/2 = 3/8."},
		{ID: "Q-MATH-003", Type: domain.QTypeMath, SubjectID: "MATH", ClassID: "JHS2A", Topic: "Fractions", Difficulty: 3, CognitiveLevel: "Analysis", Marks: 4, Stem: "Simplify: 3/4 + 1/6. Show your working.", Explanation: "Common denominator 12: 9/12 + 2/12 = 11/12."},
		{ID: "Q-ENG-001", Type: domain.QTypeTrueFalse, SubjectID: "ENG", ClassID: "JHS2A", Topic: "Comprehension", Difficulty: 1, CognitiveLevel: "Knowledge", Marks: 1, Stem: "A noun is a naming word.", CorrectAnswer: "True", Explanation: "A noun names a person, place, or thing."},
		{ID: "Q-ENG-002", Type: domain.QTypeFillBlank, SubjectID: "ENG", ClassID: "JHS2A", Topic: "Grammar", Difficulty: 2, CognitiveLevel: "Comprehension", Marks: 2, Stem: "She ___ to school every morning. (go / goes)", CorrectAnswer: "goes", Explanation: "Third person singular takes \"goes\"."},
		{ID: "Q-ENG-003", Type: domain.QTypeShortAnswer, SubjectID: "ENG", ClassID: "JHS2A", Topic: "Comprehension", Difficulty: 2, CognitiveLevel: "Application", Marks: 3, Stem: "Write one sentence using a conjunction.", Explanation: "Conjunctions: and, but, because, or."},
		{ID: "Q-SCI-001", Type: domain.QTypeMCQ, SubjectID: "SCI", ClassID: "JHS2A", Topic: "Photosynthesis", Difficulty: 1, CognitiveLevel: "Knowledge", Marks: 2, Stem: "Which gas do plants absorb during photosynthesis?", Options: []string{"Oxygen", "Carbon dioxide", "Nitrogen", "Hydrogen"}, CorrectAnswer: "Carbon dioxide", Explanation: "Plants take in CO2 and release oxygen."},
		{ID: "Q-SCI-002", Type: domain.QTypeMCQ, SubjectID: "SCI", ClassID: "JHS2A", Topic: "Photosynthesis", Difficulty: 2, CognitiveLevel: "Application", Marks: 3, Stem: "The pigment that makes leaves green is called ___?", Options: []string{"Chlorophyll", "Carotene", "Chloroplast", "Xylem"}, CorrectAnswer: "Chlorophyll", Explanation: "Chlorophyll captures light energy."},
		{ID: "Q-SOC-001", Type: domain.QTypeTrueFalse, SubjectID: "SOC", ClassID: "JHS2A", Topic: "Ghana Independence", Difficulty: 1, CognitiveLevel: "Knowledge", Marks: 1, Stem: "Ghana became independent in 1957.", CorrectAnswer: "True", Explanation: "Ghana gained independence on 6 March 1957."},
		{ID: "Q-SOC-002", Type: domain.QTypeShortAnswer, SubjectID: "SOC", ClassID: "JHS2A", Topic: "Ghana Independence", Difficulty: 2, CognitiveLevel: "Comprehension", Marks: 2, Stem: "Name which city is the capital of Ghana.", CorrectAnswer: "Accra", Explanation: "Accra is the capital city of Ghana."},
	}
	for _, q := range questions {
		st.SaveQuestion(q)
	}

	byID := make(map[string]domain.Question, len(questions))
	for _, q := range questions {
		byID[q.ID] = q
	}
	for _, a := range []domain.Assessment{
		{ID: "ASSMT-MAT-HALF", Title: "Fractions Quick Diagnostic", Type: domain.TypeDiagnostic, SubjectID: "MATH", ClassID: "JHS2A", Date: "2026-09-10", CreatedBy: "Ms. Efua Mensah", Questions: []domain.Question{byID["Q-MATH-001"], byID["Q-MATH-002"], byID["Q-MATH-003"]}},
		{ID: "ASSMT-ENG-T1", Title: "English Language — Term 1 Test", Type: domain.TypeClassTest, SubjectID: "ENG", ClassID: "JHS2A", Date: "2026-09-12", CreatedBy: "Ms. Efua Mensah", Questions: []domain.Question{byID["Q-ENG-001"], byID["Q-ENG-002"], byID["Q-ENG-003"]}},
		{ID: "ASSMT-MOCK-BECE-MATH", Title: "BECE Mathematics Mock", Type: domain.TypeMock, SubjectID: "MATH", ClassID: "JHS2A", Date: "2026-09-14", CreatedBy: "Ms. Efua Mensah", Questions: []domain.Question{byID["Q-MATH-001"], byID["Q-MATH-002"], byID["Q-MATH-003"]}},
		{ID: "ASSMT-MOCK-BECE-ENG", Title: "BECE English Mock", Type: domain.TypeMock, SubjectID: "ENG", ClassID: "JHS2A", Date: "2026-09-16", CreatedBy: "Ms. Efua Mensah", Questions: []domain.Question{byID["Q-ENG-001"], byID["Q-ENG-002"], byID["Q-ENG-003"]}},
	} {
		st.SaveAssessment(a)
	}

	for _, s := range []domain.Submission{
		{ID: "SUB-M1-STU001", AssessmentID: "ASSMT-MAT-HALF", StudentID: "STU-001", ClassID: "JHS2A", Date: "2026-09-10", Answers: map[string]string{"Q-MATH-001": "2/4", "Q-MATH-002": "3/8 m", "Q-MATH-003": "11/12"}, TeacherMarks: map[string]float64{"Q-MATH-003": 3}, Earned: 8},
		{ID: "SUB-M1-STU002", AssessmentID: "ASSMT-MAT-HALF", StudentID: "STU-002", ClassID: "JHS2A", Date: "2026-09-10", Answers: map[string]string{"Q-MATH-001": "2/4", "Q-MATH-002": "1/2 m"}, Earned: 2},
		{ID: "SUB-E1-STU001", AssessmentID: "ASSMT-ENG-T1", StudentID: "STU-001", ClassID: "JHS2A", Date: "2026-09-12", Answers: map[string]string{"Q-ENG-001": "True", "Q-ENG-002": "goes", "Q-ENG-003": "Kojo ran, but he was late."}, TeacherMarks: map[string]float64{"Q-ENG-003": 3}, Earned: 6},
	} {
		st.SaveSubmission(s)
	}

	for _, i := range []domain.Intervention{
		{ID: "INTV-001", StudentID: "STU-002", Topic: "Fractions", Action: "Targeted practice on equivalent fractions; re-teach and reassess in 2 weeks.", AssignedBy: "Ms. Efua Mensah", CreatedDate: "2026-09-14", Status: domain.IntOpen},
	} {
		st.SaveIntervention(i)
	}

	for _, m := range []domain.Message{
		{ID: "MSG-001", FromID: "USR-TCH-001", ToID: "USR-PRN-001", RelatedStudentID: "STU-001", Subject: "Fractions diagnostic — great progress", Body: "Dear Ama, Kojo scored 8/9 on the Fractions diagnostic. Keep practising equivalent fractions at home. - Ms. Mensah", Timestamp: "2026-09-11T08:15"},
		{ID: "MSG-002", FromID: "USR-PRN-001", ToID: "USR-TCH-001", RelatedStudentID: "STU-001", Subject: "Re: Fractions diagnostic — great progress", Body: "Thank you, Ms. Mensah. We will practice over the weekend.", Timestamp: "2026-09-11T19:40", Read: true},
		{ID: "MSG-003", FromID: "USR-TCH-001", ToID: "USR-PRN-001", RelatedStudentID: "STU-001", Subject: "Attendance reminder", Body: "Kojo was marked late twice this week. Please ensure he arrives by 7:30am.", Timestamp: "2026-09-15T07:20", Read: true},
	} {
		st.SaveMessage(m)
	}

	// Fixed timestamps, so every boot (and the app seed) agree.
	for _, a := range seedAnnouncements {
		st.AddAnnouncement(a)
	}
	seedRecords(st)

	notifTS := seedYesterday().Format("2006-01-02")
	for _, n := range []domain.Notification{
		{ID: "NOTIF-001", Kind: domain.NotifGate, Title: "Kojo arrived at school", Body: "Arrival verified at the gate at 07:40.", Timestamp: notifTS + " 07:40", StudentID: "STU-001"},
		{ID: "NOTIF-002", Kind: domain.NotifAttendance, Title: "Late arrival recorded", Body: "Kojo was marked late again this week. Please ensure timely arrival.", Timestamp: notifTS + " 08:05", StudentID: "STU-001"},
		{ID: "NOTIF-003", Kind: domain.NotifAssessment, Title: "New results available", Body: "Fractions Quick Diagnostic results are ready for review.", Timestamp: notifTS + " 15:20", StudentID: "STU-001"},
	} {
		st.AddNotification(n)
	}

	for _, a := range []domain.Assignment{
		{ID: "ASG-001", ClassID: "JHS2A", SubjectID: "MATH", Title: "Fractions practice set", Instructions: "Complete questions 1–6 in your exercise book. Show all working. Due Friday.", Deadline: "2026-09-25", CreatedBy: "Ms. Efua Mensah", CreatedAt: "2026-09-18"},
		{ID: "ASG-002", ClassID: "JHS2A", SubjectID: "ENG", Title: "Write a short paragraph", Instructions: "Describe your best friend using at least three adjectives and one conjunction.", Deadline: "2026-09-24", CreatedBy: "Ms. Efua Mensah", CreatedAt: "2026-09-18"},
	} {
		st.SaveAssignment(a)
	}

	// Fees mirror the client's FeesRepository._buildSeed so the API and a fee
	// screen opened on a phone describe the same bill. `st.Students()` rather
	// than the literal above: Postgres orders by id and Memory keeps insertion
	// order, and both are the order the client rotates its paid/partial/
	// overdue/due states through.
	seedFees(st, st.Term(), st.Students())
}

// seedFees raises this term's invoices exactly as the client's
// FeesRepository._buildSeed does: one invoice per student, tuition priced by
// class plus the school-wide levies, and the same four-way rotation over the
// student list — settled, part-paid, past due, untouched — so the demo shows
// every state a bursar meets.
//
// Only the invoice itself is stored. The payments below are what the read side
// sums back into amountPaid, which is why the two always agree here instead of
// being written twice and left to drift.
// seedAnnouncements mirrors LocalStore's seed in the app.
var seedAnnouncements = []domain.Announcement{
	{ID: "ANN-SEED-001", Title: "Mid-term break", Body: "School closes on Friday 23 October for the mid-term break and reopens on Monday 2 November.", Audience: domain.AudSchool, AuthorID: "USR-HRT-001", AuthorName: "Kwame Boateng", Timestamp: "2026-09-29 09:00"},
	{ID: "ANN-SEED-002", Title: "JHS 2A science practical", Body: "Bring a notebook and a pencil for Thursday's practical in the science lab.", Audience: domain.AudClasses, TargetClassID: "JHS2A", AuthorID: "USR-TCH-001", AuthorName: "Ms. Efua Mensah", Timestamp: "2026-09-28 14:30"},
	{ID: "ANN-SEED-003", Title: "PTA meeting", Body: "The termly PTA meeting is on Saturday 10 October at 10:00 in the assembly hall. All parents are welcome.", Audience: domain.AudSchool, AuthorID: "USR-ADM-001", AuthorName: "Mrs. Adjoa Amankwah", Timestamp: "2026-09-25 11:00"},
}

func seedFees(st Store, term domain.SchoolTerm, students []domain.Student) {
	tuitionByClass := map[string]int{
		"JHS1A": 1450, "JHS1B": 1450, "JHS2A": 1550,
		"JHS2B": 1550, "JHS3A": 1700, "JHS3B": 1700,
	}
	schoolWide := []domain.FeeLineItem{
		{Name: "Feeding levy", Amount: 450},
		{Name: "PTA levy", Amount: 200},
		{Name: "Exam fee", Amount: 150},
	}
	issue := term.Start
	due := seedShiftDate(issue, 30)
	termCode := feeTermCode(term)
	bursar := "Mrs. Adjoa Amankwah (Bursar)"

	for i, s := range students {
		tuition, priced := tuitionByClass[s.ClassID]
		if !priced {
			continue // a class with no fee schedule is billed nothing, not something
		}
		items := append(
			[]domain.FeeLineItem{{Name: "Tuition — " + s.ClassID, Amount: tuition}},
			schoolWide...)

		pattern := i % 4
		invDue := due
		if pattern == 2 {
			// The "past due" invoice must actually be past due, so it lapses
			// a week in rather than on the ordinary 30-day date.
			invDue = seedShiftDate(issue, 10)
		}
		inv := domain.Invoice{
			ID: "INV-" + termCode + "-" + s.ID, StudentID: s.ID,
			IssueDate: issue, DueDate: invDue, LineItems: items, Term: term.Label(),
		}

		paid := 0
		switch pattern {
		case 0:
			paid = inv.Total() // settled
		case 1:
			paid = inv.Total() * 60 / 100 // part-paid
		}
		if paid > 0 {
			method, ref := "cash", fmt.Sprintf("CASH-%d00", i+1)
			if pattern == 0 {
				method, ref = "mobileMoney", fmt.Sprintf("MOMO-%d00", i+1)
			}
			st.SavePayment(domain.Payment{
				ID: "PAY-SEED-" + s.ID, InvoiceID: inv.ID, StudentID: s.ID,
				Amount: paid, Method: method, Reference: ref,
				PaidAt: seedShiftDate(issue, i%7+1) + " 10:30", RecordedBy: bursar,
			})
		}
		st.SaveInvoice(inv)
	}
}

// seedShiftDate moves a 'yyyy-MM-dd' by days and returns it in the same
// format — _shiftDate in the client's fees repository, seed edition. An
// unparseable base is returned unchanged, as the client does.
func seedShiftDate(base string, days int) string {
	d, err := time.Parse("2006-01-02", base)
	if err != nil {
		return base
	}
	return d.AddDate(0, 0, days).Format("2006-01-02")
}

// feeTermCode builds the invoice-key segment for a term, e.g. `2026T1` for
// "Term 1 · 2026/2027" — the client's _termCode: the calendar year before the
// slash, then T and the digits left in the term name.
func feeTermCode(term domain.SchoolTerm) string {
	year := term.Year
	if i := strings.IndexByte(year, '/'); i >= 0 {
		year = year[:i]
	}
	digits := make([]rune, 0, len(term.Name))
	for _, r := range term.Name {
		if r >= '0' && r <= '9' {
			digits = append(digits, r)
		}
	}
	if len(digits) == 0 {
		return year + "T"
	}
	return year + "T" + string(digits)
}

// lastWeekdayDates returns count most recent weekdays ending the day before the
// seed anchor (seedRefDate), mirroring LocalStore._lastWeekdayDates(5) as of
// that date. Anchoring rather than using time.Now() is what keeps the window —
// and therefore the record IDs — identical across boots.
func lastWeekdayDates(count int) []string {
	var out []string
	d := seedYesterday()
	for len(out) < count {
		if wd := d.Weekday(); wd >= time.Monday && wd <= time.Friday {
			out = append(out, d.Format("2006-01-02"))
		}
		d = d.AddDate(0, 0, -1)
	}
	// reversed (oldest first)
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

// seedRecords mirrors Phase6Store's timetable and resource seed in the app,
// byte-for-byte in field order so a parity check can compare the JSON.
func seedRecords(st Store) {
	days := []string{"Monday", "Tuesday", "Wednesday", "Thursday", "Friday"}
	subjects := []string{"MATH", "ENG", "SCI", "SOC", "ICT"}
	starts := []string{"08:00", "09:10", "10:20", "11:30", "13:30"}
	ends := []string{"08:50", "10:00", "11:10", "12:20", "14:20"}
	for d, day := range days {
		for i := range starts {
			id := fmt.Sprintf("SLOT-%d-%d", d, i)
			if _, ok := st.RecordByID(domain.RecordLessons, id); ok {
				continue
			}
			st.SaveRecord(seedRecord(domain.RecordLessons, id, "JHS2A", map[string]any{
				"id": id, "classId": "JHS2A", "weekday": day,
				"start": starts[i], "end": ends[i],
				"subjectId": subjects[i%len(subjects)], "teacherId": "USR-TCH-001",
			}))
		}
	}
	for _, r := range seedResources {
		if _, ok := st.RecordByID(domain.RecordResources, r["id"].(string)); ok {
			continue
		}
		st.SaveRecord(seedRecord(domain.RecordResources, r["id"].(string), "JHS2A", r))
	}
}

// seedRecord builds one demo row. Callers skip ids already stored, so a
// reboot never overwrites a timetable or resource the school has edited.
func seedRecord(kind, id, classID string, data map[string]any) domain.Record {
	raw, err := json.Marshal(data)
	if err != nil {
		panic(err)
	}
	return domain.Record{Kind: kind, ID: id, ClassID: classID, UpdatedAt: seedRefDate + " 00:00", Data: raw}
}

var seedResources = []map[string]any{
	{"id": "RES-001", "subjectId": "MATH", "classId": "JHS2A", "kind": "notes",
		"title": "Fractions — Class Notes", "topic": "Fractions",
		"body":    "A fraction has a numerator and a denominator. To add or subtract fractions, find a common denominator first.",
		"addedBy": "Ms. Efua Mensah", "addedOn": "2026-09-01"},
	{"id": "RES-002", "subjectId": "MATH", "classId": "JHS2A", "kind": "worksheet",
		"title": "Equivalent Fractions Worksheet", "topic": "Fractions",
		"body":    "Simplify to lowest terms: 4/8, 6/12, 9/15, 12/20, 8/10. Show your working in the box.",
		"addedBy": "Ms. Efua Mensah", "addedOn": "2026-09-02"},
	{"id": "RES-003", "subjectId": "ENG", "classId": "JHS2A", "kind": "notes",
		"title": "Parts of Speech — Quick Reference", "topic": "Grammar",
		"body":    "Nouns name things, verbs show action, adjectives describe nouns, and adverbs modify verbs or other adjectives.",
		"addedBy": "Mr. Kwame Boateng", "addedOn": "2026-09-03"},
	{"id": "RES-004", "subjectId": "SCI", "classId": "JHS2A", "kind": "video",
		"title": "The Water Cycle — Watch & Learn", "topic": "Ecology",
		"body":    "Evaporation, condensation, precipitation and collection. Watch with your class, then answer three questions.",
		"addedBy": "Ms. Efua Mensah", "addedOn": "2026-09-04"},
	{"id": "RES-005", "subjectId": "SOC", "classId": "JHS2A", "kind": "lessonPlan",
		"title": "Map Skills — Lesson Plan", "topic": "Map Reading",
		"body":    "Objective: read a simple map key. Starter: show a street map. Main: locate landmarks. Plenary: draw a classroom map.",
		"addedBy": "Mr. Kwame Boateng", "addedOn": "2026-09-05"},
}
