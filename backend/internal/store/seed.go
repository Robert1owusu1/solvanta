package store

import (
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

	yes := time.Now().AddDate(0, 0, -1).Format("2006-01-02")
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

	notifTS := time.Now().AddDate(0, 0, -1).Format("2006-01-02")
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
}

// lastWeekdayDates returns count most recent weekdays ending yesterday,
// mirroring LocalStore._lastWeekdayDates(5).
func lastWeekdayDates(count int) []string {
	var out []string
	d := time.Now().AddDate(0, 0, -1)
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
