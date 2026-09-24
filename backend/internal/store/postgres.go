package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"

	_ "github.com/jackc/pgx/v5/stdlib"

	"solvanta/backend/internal/domain"
	"solvanta/backend/migrations"
)

// Postgres is a Store implementation backed by PostgreSQL. It uses the schema
// in migrations/001_init.sql, which stores the same camelCase enum strings and
// display-level date/time strings the Flutter client sends and renders.
//
// The Store contract has no error channel (the in-memory store never fails),
// so read failures fall back to empty/zero values and write failures are
// logged. Production callers wanting hard failure semantics should check the
// health endpoint instead of individual reads.
type Postgres struct {
	db *sql.DB
}

// NewPostgres opens a PostgreSQL connection (DSN e.g.
// postgres://user:pass@host/db?sslmode=disable), applies the embedded schema
// and — when seed is true — loads the same development dataset the in-memory
// store ships with.
func NewPostgres(dsn string, seed bool) (*Postgres, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, err
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, err
	}
	p := &Postgres{db: db}
	if _, err := db.Exec(migrations.SQL); err != nil {
		db.Close()
		return nil, fmt.Errorf("apply migrations: %w", err)
	}
	if seed {
		Seed(p)
	}
	return p, nil
}

// Close releases the underlying connection pool.
func (p *Postgres) Close() error { return p.db.Close() }

func errLog(verb string, err error) { log.Printf("postgres %s: %v", verb, err) }

func contextTODO() context.Context { return context.Background() }

// toJSON marshals a Go value to a JSON string (NULL for empty values). Queries
// cast the result with ::jsonb so JSONB columns round-trip losslessly.
func toJSON(v any) any {
	if v == nil {
		return nil
	}
	switch x := v.(type) {
	case []domain.Person:
		if len(x) == 0 {
			return nil
		}
	case []domain.Question:
		if len(x) == 0 {
			return nil
		}
	case []string:
		if len(x) == 0 {
			return nil
		}
	case map[string]string:
		if len(x) == 0 {
			return nil
		}
	case map[string]float64:
		if len(x) == 0 {
			return nil
		}
	}
	b, err := json.Marshal(v)
	if err != nil {
		log.Printf("postgres toJSON(%T): %v", v, err)
		return nil
	}
	return string(b)
}

func nullStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// --- School & term ---

func (p *Postgres) School() domain.School {
	var s domain.School
	row := p.db.QueryRowContext(contextTODO(),
		`SELECT id, name, COALESCE(motto,''), COALESCE(address,''), COALESCE(phone,''), COALESCE(email,''), COALESCE(region,'') FROM schools ORDER BY id LIMIT 1`)
	err := row.Scan(&s.ID, &s.Name, &s.Motto, &s.Address, &s.Phone, &s.Email, &s.Region)
	if err != nil && err != sql.ErrNoRows {
		errLog("School", err)
	}
	return s
}

func (p *Postgres) SaveSchool(s domain.School) {
	if s.ID == "" {
		s.ID = domain.DefaultSchoolID()
	}
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO schools (id, name, motto, address, phone, email, region)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (id) DO UPDATE SET
			name = EXCLUDED.name, motto = EXCLUDED.motto, address = EXCLUDED.address,
			phone = EXCLUDED.phone, email = EXCLUDED.email, region = EXCLUDED.region`,
		s.ID, s.Name, nullStr(s.Motto), nullStr(s.Address), nullStr(s.Phone), nullStr(s.Email), nullStr(s.Region))
	if err != nil {
		errLog("SaveSchool", err)
	}
}

func (p *Postgres) Term() domain.SchoolTerm {
	var t domain.SchoolTerm
	row := p.db.QueryRowContext(contextTODO(),
		`SELECT year, name, start_date::text, end_date::text FROM school_terms ORDER BY id DESC LIMIT 1`)
	err := row.Scan(&t.Year, &t.Name, &t.Start, &t.End)
	if err != nil && err != sql.ErrNoRows {
		errLog("Term", err)
	}
	return t
}

func (p *Postgres) SaveTerm(t domain.SchoolTerm) {
	_, err := p.db.ExecContext(contextTODO(),
		`INSERT INTO school_terms (school_id, year, name, start_date, end_date)
		 VALUES ($1, $2, $3, $4, $5)`,
		domain.DefaultSchoolID(), t.Year, t.Name, t.Start, t.End)
	if err != nil {
		errLog("SaveTerm", err)
	}
}

// --- Users (doc §9) ---

const userColumns = `id, name, email, COALESCE(phone,''), password, role,
	COALESCE(school_id,''), COALESCE(class_id,'')`

func scanUser(row interface{ Scan(...any) error }) (domain.User, error) {
	var u domain.User
	err := row.Scan(&u.ID, &u.Name, &u.Email, &u.Phone, &u.Password, &u.Role, &u.SchoolID, &u.ClassID)
	return u, err
}

func (p *Postgres) studentIDsForUser(ctx context.Context, id string) []string {
	rows, err := p.db.QueryContext(ctx, `SELECT student_id FROM user_students WHERE user_id = $1`, id)
	if err != nil {
		errLog("studentIDsForUser", err)
		return nil
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var sid string
		if err := rows.Scan(&sid); err != nil {
			errLog("studentIDsForUser scan", err)
			continue
		}
		out = append(out, sid)
	}
	return out
}

func (p *Postgres) Users() []domain.User {
	rows, err := p.db.QueryContext(contextTODO(), `SELECT `+userColumns+` FROM users ORDER BY id`)
	if err != nil {
		errLog("Users", err)
		return nil
	}
	defer rows.Close()
	ctx := contextTODO()
	var out []domain.User
	for rows.Next() {
		u, err := scanUser(rows)
		if err != nil {
			errLog("Users scan", err)
			continue
		}
		u.StudentIDs = p.studentIDsForUser(ctx, u.ID)
		out = append(out, u)
	}
	return out
}

func (p *Postgres) UserByID(id string) (domain.User, bool) {
	row := p.db.QueryRowContext(contextTODO(), `SELECT `+userColumns+` FROM users WHERE id = $1`, id)
	u, err := scanUser(row)
	if err != nil {
		if err != sql.ErrNoRows {
			errLog("UserByID", err)
		}
		return domain.User{}, false
	}
	u.StudentIDs = p.studentIDsForUser(contextTODO(), u.ID)
	return u, true
}

func (p *Postgres) UserByEmail(email string) (domain.User, bool) {
	row := p.db.QueryRowContext(contextTODO(), `SELECT `+userColumns+` FROM users WHERE lower(email) = lower($1)`, email)
	u, err := scanUser(row)
	if err != nil {
		if err != sql.ErrNoRows {
			errLog("UserByEmail", err)
		}
		return domain.User{}, false
	}
	u.StudentIDs = p.studentIDsForUser(contextTODO(), u.ID)
	return u, true
}

func (p *Postgres) SaveUser(u domain.User) {
	tx, err := p.db.BeginTx(contextTODO(), nil)
	if err != nil {
		errLog("SaveUser begin", err)
		return
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(contextTODO(), `
		INSERT INTO users (id, name, email, phone, password, role, school_id, class_id)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT (id) DO UPDATE SET
			name = EXCLUDED.name, email = EXCLUDED.email, phone = EXCLUDED.phone,
			password = EXCLUDED.password, role = EXCLUDED.role,
			school_id = EXCLUDED.school_id, class_id = EXCLUDED.class_id`,
		u.ID, u.Name, u.Email, nullStr(u.Phone), u.Password, u.Role, nullStr(u.SchoolID), nullStr(u.ClassID)); err != nil {
		errLog("SaveUser", err)
		return
	}
	if _, err := tx.ExecContext(contextTODO(), `DELETE FROM user_students WHERE user_id = $1`, u.ID); err != nil {
		errLog("SaveUser links delete", err)
		return
	}
	for _, sid := range u.StudentIDs {
		if _, err := tx.ExecContext(contextTODO(),
			`INSERT INTO user_students (user_id, student_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
			u.ID, sid); err != nil {
			errLog("SaveUser link", err)
			return
		}
	}
	if err := tx.Commit(); err != nil {
		errLog("SaveUser commit", err)
	}
}

// --- Classes ---

func (p *Postgres) Classes() []domain.ClassRoom {
	rows, err := p.db.QueryContext(contextTODO(),
		`SELECT id, name, COALESCE(stream,''), COALESCE(teacher_id,'') FROM class_rooms ORDER BY id`)
	if err != nil {
		errLog("Classes", err)
		return nil
	}
	defer rows.Close()
	var out []domain.ClassRoom
	for rows.Next() {
		var c domain.ClassRoom
		if err := rows.Scan(&c.ID, &c.Name, &c.Stream, &c.TeacherID); err != nil {
			errLog("Classes scan", err)
			continue
		}
		out = append(out, c)
	}
	return out
}

func (p *Postgres) ClassByID(id string) (domain.ClassRoom, bool) {
	var c domain.ClassRoom
	row := p.db.QueryRowContext(contextTODO(),
		`SELECT id, name, COALESCE(stream,''), COALESCE(teacher_id,'') FROM class_rooms WHERE id = $1`, id)
	err := row.Scan(&c.ID, &c.Name, &c.Stream, &c.TeacherID)
	if err != nil {
		if err != sql.ErrNoRows {
			errLog("ClassByID", err)
		}
		return domain.ClassRoom{}, false
	}
	return c, true
}

func (p *Postgres) SaveClass(c domain.ClassRoom) {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO class_rooms (id, name, stream, teacher_id) VALUES ($1, $2, $3, $4)
		ON CONFLICT (id) DO UPDATE SET
			name = EXCLUDED.name, stream = EXCLUDED.stream, teacher_id = EXCLUDED.teacher_id`,
		c.ID, c.Name, nullStr(c.Stream), nullStr(c.TeacherID))
	if err != nil {
		errLog("SaveClass", err)
	}
}

// --- Students (doc §10) ---

const studentColumns = `id, first_name, last_name, COALESCE(gender,''), COALESCE(date_of_birth::text,''),
	COALESCE(admission_date::text,''), COALESCE(admission_no,''), COALESCE(class_id,''),
	COALESCE(school_id,''), COALESCE(status,''), COALESCE(parent_user_id,'')`

func scanStudent(row interface{ Scan(...any) error }) (domain.Student, error) {
	var s domain.Student
	err := row.Scan(&s.ID, &s.FirstName, &s.LastName, &s.Gender, &s.DateOfBirth,
		&s.AdmissionDate, &s.AdmissionNo, &s.ClassID, &s.SchoolID, &s.Status, &s.ParentUserID)
	return s, err
}

type contactRow struct {
	Kind   string
	Person domain.Person
}

func (p *Postgres) contactsForStudents(ctx context.Context) map[string][]contactRow {
	rows, err := p.db.QueryContext(ctx,
		`SELECT student_id, kind, name, COALESCE(phone,''), COALESCE(relation,'') FROM student_contacts ORDER BY id`)
	if err != nil {
		errLog("contactsForStudents", err)
		return nil
	}
	defer rows.Close()
	out := map[string][]contactRow{}
	for rows.Next() {
		var sid, kind, name, phone, rel string
		if err := rows.Scan(&sid, &kind, &name, &phone, &rel); err != nil {
			errLog("contactsForStudents scan", err)
			continue
		}
		out[sid] = append(out[sid], contactRow{Kind: kind, Person: domain.Person{Name: name, Phone: phone, Relation: rel}})
	}
	return out
}

func (p *Postgres) attachContacts(s *domain.Student, contacts map[string][]contactRow) {
	for _, c := range contacts[s.ID] {
		switch c.Kind {
		case "guardian":
			s.Guardians = append(s.Guardians, c.Person)
		case "emergency":
			s.EmergencyContacts = append(s.EmergencyContacts, c.Person)
		case "authorizedPickup":
			s.AuthorizedPickup = append(s.AuthorizedPickup, c.Person)
		}
	}
}

func (p *Postgres) Students() []domain.Student {
	rows, err := p.db.QueryContext(contextTODO(), `SELECT `+studentColumns+` FROM students ORDER BY id`)
	if err != nil {
		errLog("Students", err)
		return nil
	}
	defer rows.Close()
	contacts := p.contactsForStudents(contextTODO())
	var out []domain.Student
	for rows.Next() {
		s, err := scanStudent(rows)
		if err != nil {
			errLog("Students scan", err)
			continue
		}
		p.attachContacts(&s, contacts)
		out = append(out, s)
	}
	return out
}

func (p *Postgres) StudentByID(id string) (domain.Student, bool) {
	row := p.db.QueryRowContext(contextTODO(), `SELECT `+studentColumns+` FROM students WHERE id = $1`, id)
	s, err := scanStudent(row)
	if err != nil {
		if err != sql.ErrNoRows {
			errLog("StudentByID", err)
		}
		return domain.Student{}, false
	}
	p.attachContacts(&s, p.contactsForStudents(contextTODO()))
	return s, true
}

func (p *Postgres) StudentsByParentUser(id string) []domain.Student {
	rows, err := p.db.QueryContext(contextTODO(),
		`SELECT `+studentColumns+` FROM students WHERE parent_user_id = $1 ORDER BY id`, id)
	if err != nil {
		errLog("StudentsByParentUser", err)
		return nil
	}
	defer rows.Close()
	contacts := p.contactsForStudents(contextTODO())
	var out []domain.Student
	for rows.Next() {
		s, err := scanStudent(rows)
		if err != nil {
			errLog("StudentsByParentUser scan", err)
			continue
		}
		p.attachContacts(&s, contacts)
		out = append(out, s)
	}
	return out
}

func (p *Postgres) SaveStudent(s domain.Student) {
	tx, err := p.db.BeginTx(contextTODO(), nil)
	if err != nil {
		errLog("SaveStudent begin", err)
		return
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(contextTODO(), `
		INSERT INTO students (id, first_name, last_name, gender, date_of_birth, admission_date,
			admission_no, class_id, school_id, status, parent_user_id)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
		ON CONFLICT (id) DO UPDATE SET
			first_name = EXCLUDED.first_name, last_name = EXCLUDED.last_name, gender = EXCLUDED.gender,
			date_of_birth = EXCLUDED.date_of_birth, admission_date = EXCLUDED.admission_date,
			admission_no = EXCLUDED.admission_no, class_id = EXCLUDED.class_id,
			school_id = EXCLUDED.school_id, status = EXCLUDED.status, parent_user_id = EXCLUDED.parent_user_id`,
		s.ID, s.FirstName, s.LastName, nullStr(s.Gender), nullStr(s.DateOfBirth),
		nullStr(s.AdmissionDate), nullStr(s.AdmissionNo), nullStr(s.ClassID),
		nullStr(s.SchoolID), firstNonEmpty(s.Status, "active"), nullStr(s.ParentUserID)); err != nil {
		errLog("SaveStudent", err)
		return
	}
	if _, err := tx.ExecContext(contextTODO(), `DELETE FROM student_contacts WHERE student_id = $1`, s.ID); err != nil {
		errLog("SaveStudent contacts delete", err)
		return
	}
	writeContacts := func(kind string, people []domain.Person) {
		for _, p := range people {
			if _, err := tx.ExecContext(contextTODO(),
				`INSERT INTO student_contacts (student_id, kind, name, phone, relation)
				 VALUES ($1,$2,$3,$4,$5)`,
				s.ID, kind, p.Name, nullStr(p.Phone), nullStr(p.Relation)); err != nil {
				errLog("SaveStudent contact", err)
			}
		}
	}
	writeContacts("guardian", s.Guardians)
	writeContacts("emergency", s.EmergencyContacts)
	writeContacts("authorizedPickup", s.AuthorizedPickup)
	if err := tx.Commit(); err != nil {
		errLog("SaveStudent commit", err)
	}
}

// --- Attendance (doc §12) ---

const attendanceColumns = `id, student_id, COALESCE(class_id,''), date::text, status,
	COALESCE(to_char(check_in, 'HH24:MI'),''), COALESCE(to_char(check_out, 'HH24:MI'),''),
	COALESCE(old_status,''), COALESCE(reason,'')`

func scanAttendance(row interface{ Scan(...any) error }) (domain.AttendanceRecord, error) {
	var r domain.AttendanceRecord
	err := row.Scan(&r.ID, &r.StudentID, &r.ClassID, &r.Date, &r.Status,
		&r.CheckIn, &r.CheckOut, &r.OldStatus, &r.Reason)
	return r, err
}

func (p *Postgres) Attendance() []domain.AttendanceRecord {
	rows, err := p.db.QueryContext(contextTODO(), `SELECT `+attendanceColumns+` FROM attendance ORDER BY date, student_id`)
	if err != nil {
		errLog("Attendance", err)
		return nil
	}
	defer rows.Close()
	var out []domain.AttendanceRecord
	for rows.Next() {
		r, err := scanAttendance(rows)
		if err != nil {
			errLog("Attendance scan", err)
			continue
		}
		out = append(out, r)
	}
	return out
}

func (p *Postgres) AttendanceForClassDate(classID, date string) []domain.AttendanceRecord {
	rows, err := p.db.QueryContext(contextTODO(),
		`SELECT `+attendanceColumns+` FROM attendance WHERE class_id = $1 AND date = $2 ORDER BY student_id`,
		classID, date)
	if err != nil {
		errLog("AttendanceForClassDate", err)
		return nil
	}
	defer rows.Close()
	var out []domain.AttendanceRecord
	for rows.Next() {
		r, err := scanAttendance(rows)
		if err != nil {
			errLog("AttendanceForClassDate scan", err)
			continue
		}
		out = append(out, r)
	}
	return out
}

func (p *Postgres) upsertAttendance(tx *sql.Tx, r domain.AttendanceRecord) {
	_, err := tx.ExecContext(contextTODO(), `
		INSERT INTO attendance (id, student_id, class_id, date, status, check_in, check_out, old_status, reason)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		ON CONFLICT (student_id, date) DO UPDATE SET
			id = EXCLUDED.id, class_id = EXCLUDED.class_id, status = EXCLUDED.status,
			check_in = EXCLUDED.check_in, check_out = EXCLUDED.check_out,
			old_status = EXCLUDED.old_status, reason = EXCLUDED.reason`,
		r.ID, r.StudentID, r.ClassID, r.Date, r.Status,
		nullStr(r.CheckIn), nullStr(r.CheckOut), nullStr(r.OldStatus), nullStr(r.Reason))
	if err != nil {
		errLog("upsertAttendance", err)
	}
}

// SaveAttendance replaces the whole attendance log (bootstrap/import).
func (p *Postgres) SaveAttendance(records []domain.AttendanceRecord) {
	tx, err := p.db.BeginTx(contextTODO(), nil)
	if err != nil {
		errLog("SaveAttendance begin", err)
		return
	}
	defer tx.Rollback()
	if len(records) > 0 {
		ids := make([]string, 0, len(records))
		for _, r := range records {
			ids = append(ids, r.ID)
		}
		if _, err := tx.ExecContext(contextTODO(), `DELETE FROM attendance WHERE NOT (id = ANY($1))`, ids); err != nil {
			errLog("SaveAttendance delete", err)
			return
		}
	} else {
		if _, err := tx.ExecContext(contextTODO(), `DELETE FROM attendance`); err != nil {
			errLog("SaveAttendance clear", err)
			return
		}
	}
	for _, r := range records {
		p.upsertAttendance(tx, r)
	}
	if err := tx.Commit(); err != nil {
		errLog("SaveAttendance commit", err)
	}
}

// SaveDay replaces one class/date bucket.
func (p *Postgres) SaveDay(classID, date string, records []domain.AttendanceRecord) {
	tx, err := p.db.BeginTx(contextTODO(), nil)
	if err != nil {
		errLog("SaveDay begin", err)
		return
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(contextTODO(),
		`DELETE FROM attendance WHERE class_id = $1 AND date = $2`, classID, date); err != nil {
		errLog("SaveDay delete", err)
		return
	}
	for _, r := range records {
		p.upsertAttendance(tx, r)
	}
	if err := tx.Commit(); err != nil {
		errLog("SaveDay commit", err)
	}
}

// --- Gate (doc §13) ---

func (p *Postgres) GateEvents() []domain.GateEvent {
	rows, err := p.db.QueryContext(contextTODO(),
		`SELECT id, student_id, type, to_char(time, 'HH24:MI'), date::text,
		        COALESCE(reporter,''), COALESCE(person,''), COALESCE(detail,'')
		 FROM gate_events ORDER BY date DESC, time DESC`)
	if err != nil {
		errLog("GateEvents", err)
		return nil
	}
	defer rows.Close()
	var out []domain.GateEvent
	for rows.Next() {
		var e domain.GateEvent
		if err := rows.Scan(&e.ID, &e.StudentID, &e.Type, &e.Time, &e.Date, &e.Reporter, &e.Person, &e.Detail); err != nil {
			errLog("GateEvents scan", err)
			continue
		}
		out = append(out, e)
	}
	return out
}

func (p *Postgres) GateForStudent(id string) []domain.GateEvent {
	rows, err := p.db.QueryContext(contextTODO(),
		`SELECT id, student_id, type, to_char(time, 'HH24:MI'), date::text,
		        COALESCE(reporter,''), COALESCE(person,''), COALESCE(detail,'')
		 FROM gate_events WHERE student_id = $1 ORDER BY date DESC, time DESC`, id)
	if err != nil {
		errLog("GateForStudent", err)
		return nil
	}
	defer rows.Close()
	var out []domain.GateEvent
	for rows.Next() {
		var e domain.GateEvent
		if err := rows.Scan(&e.ID, &e.StudentID, &e.Type, &e.Time, &e.Date, &e.Reporter, &e.Person, &e.Detail); err != nil {
			errLog("GateForStudent scan", err)
			continue
		}
		out = append(out, e)
	}
	return out
}

func (p *Postgres) AddGateEvent(e domain.GateEvent) {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO gate_events (id, student_id, type, time, date, reporter, person, detail)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
		ON CONFLICT (id) DO NOTHING`,
		e.ID, e.StudentID, e.Type, e.Time, e.Date, nullStr(e.Reporter), nullStr(e.Person), nullStr(e.Detail))
	if err != nil {
		errLog("AddGateEvent", err)
	}
}

// --- Questions (doc §17) ---

const questionColumns = `id, type, subject_id, COALESCE(class_id,''), topic, difficulty,
	COALESCE(cognitive_level,''), marks::float8, stem, COALESCE(options::text,'[]'),
	COALESCE(correct_answer,''), COALESCE(explanation,''), COALESCE(marking_scheme,'')`

func scanQuestion(row interface{ Scan(...any) error }) (domain.Question, error) {
	var q domain.Question
	var opts string
	err := row.Scan(&q.ID, &q.Type, &q.SubjectID, &q.ClassID, &q.Topic, &q.Difficulty,
		&q.CognitiveLevel, &q.Marks, &q.Stem, &opts, &q.CorrectAnswer, &q.Explanation, &q.MarkingScheme)
	if err != nil {
		return q, err
	}
	_ = json.Unmarshal([]byte(opts), &q.Options)
	if q.Options == nil {
		q.Options = []string{}
	}
	return q, nil
}

func (p *Postgres) Questions() []domain.Question {
	rows, err := p.db.QueryContext(contextTODO(), `SELECT `+questionColumns+` FROM questions ORDER BY id`)
	if err != nil {
		errLog("Questions", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Question
	for rows.Next() {
		q, err := scanQuestion(rows)
		if err != nil {
			errLog("Questions scan", err)
			continue
		}
		out = append(out, q)
	}
	return out
}

func (p *Postgres) QuestionByID(id string) (domain.Question, bool) {
	row := p.db.QueryRowContext(contextTODO(), `SELECT `+questionColumns+` FROM questions WHERE id = $1`, id)
	q, err := scanQuestion(row)
	if err != nil {
		if err != sql.ErrNoRows {
			errLog("QuestionByID", err)
		}
		return domain.Question{}, false
	}
	return q, true
}

func (p *Postgres) SaveQuestion(q domain.Question) {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO questions (id, type, subject_id, class_id, topic, difficulty, cognitive_level,
			marks, stem, options, correct_answer, explanation, marking_scheme)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb,$11,$12,$13)
		ON CONFLICT (id) DO UPDATE SET
			type = EXCLUDED.type, subject_id = EXCLUDED.subject_id, class_id = EXCLUDED.class_id,
			topic = EXCLUDED.topic, difficulty = EXCLUDED.difficulty, cognitive_level = EXCLUDED.cognitive_level,
			marks = EXCLUDED.marks, stem = EXCLUDED.stem, options = EXCLUDED.options,
			correct_answer = EXCLUDED.correct_answer, explanation = EXCLUDED.explanation,
			marking_scheme = EXCLUDED.marking_scheme`,
		q.ID, q.Type, q.SubjectID, nullStr(q.ClassID), q.Topic, q.Difficulty,
		nullStr(q.CognitiveLevel), q.Marks, q.Stem, toJSON(q.Options),
		nullStr(q.CorrectAnswer), nullStr(q.Explanation), nullStr(q.MarkingScheme))
	if err != nil {
		errLog("SaveQuestion", err)
	}
}

func (p *Postgres) DeleteQuestion(id string) {
	_, err := p.db.ExecContext(contextTODO(), `DELETE FROM questions WHERE id = $1`, id)
	if err != nil {
		errLog("DeleteQuestion", err)
	}
}

// --- AI generation requests (doc §43) ---

func (p *Postgres) AIRequests() []domain.GenRequest {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT r.id, r.requester_id, COALESCE(u.name,''), r.subject_id, r.topic, r.type, r.count,
		       COALESCE(r.priority,''), COALESCE(r.class_id,''), COALESCE(r.created_at,''),
		       COALESCE(r.published_at,''), r.status, COALESCE(r.drafts::text,'[]')
		FROM question_gen_requests r LEFT JOIN users u ON u.id = r.requester_id
		ORDER BY r.id`)
	if err != nil {
		errLog("AIRequests", err)
		return nil
	}
	defer rows.Close()
	var out []domain.GenRequest
	for rows.Next() {
		g, err := scanGenRequest(rows)
		if err != nil {
			errLog("AIRequests scan", err)
			continue
		}
		out = append(out, g)
	}
	return out
}

func scanGenRequest(row interface{ Scan(...any) error }) (domain.GenRequest, error) {
	var g domain.GenRequest
	var drafts string
	err := row.Scan(&g.ID, &g.RequesterID, &g.RequesterName, &g.SubjectID, &g.Topic, &g.Type,
		&g.Count, &g.Priority, &g.ClassID, &g.CreatedAt, &g.PublishedAt, &g.Status, &drafts)
	if err == nil {
		_ = json.Unmarshal([]byte(drafts), &g.Drafts)
		if g.Drafts == nil {
			g.Drafts = []domain.Question{}
		}
	}
	return g, err
}

func (p *Postgres) AIRequestByID(id string) (domain.GenRequest, bool) {
	row := p.db.QueryRowContext(contextTODO(), `
		SELECT r.id, r.requester_id, COALESCE(u.name,''), r.subject_id, r.topic, r.type, r.count,
		       COALESCE(r.priority,''), COALESCE(r.class_id,''), COALESCE(r.created_at,''),
		       COALESCE(r.published_at,''), r.status, COALESCE(r.drafts::text,'[]')
		FROM question_gen_requests r LEFT JOIN users u ON u.id = r.requester_id
		WHERE r.id = $1`, id)
	g, err := scanGenRequest(row)
	if err != nil {
		if err != sql.ErrNoRows {
			errLog("AIRequestByID", err)
		}
		return domain.GenRequest{}, false
	}
	return g, true
}

func (p *Postgres) SaveAIRequest(r domain.GenRequest) {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO question_gen_requests (id, requester_id, subject_id, topic, type, count,
			priority, class_id, created_at, published_at, status, drafts)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12::jsonb)
		ON CONFLICT (id) DO UPDATE SET
			requester_id = EXCLUDED.requester_id, subject_id = EXCLUDED.subject_id,
			topic = EXCLUDED.topic, type = EXCLUDED.type, count = EXCLUDED.count,
			priority = EXCLUDED.priority, class_id = EXCLUDED.class_id,
			created_at = EXCLUDED.created_at, published_at = EXCLUDED.published_at,
			status = EXCLUDED.status, drafts = EXCLUDED.drafts`,
		r.ID, r.RequesterID, r.SubjectID, r.Topic, r.Type, r.Count,
		nullStr(r.Priority), nullStr(r.ClassID), nullStr(r.CreatedAt), nullStr(r.PublishedAt),
		r.Status, toJSON(r.Drafts))
	if err != nil {
		errLog("SaveAIRequest", err)
	}
}

// --- Assessments (doc §16) ---

const assessmentColumns = `id, title, type, subject_id, class_id, date::text, COALESCE(created_by,'')`

func scanAssessment(row interface{ Scan(...any) error }) (domain.Assessment, error) {
	var a domain.Assessment
	err := row.Scan(&a.ID, &a.Title, &a.Type, &a.SubjectID, &a.ClassID, &a.Date, &a.CreatedBy)
	return a, err
}

func (p *Postgres) questionsForAssessment(ctx context.Context, id string) []domain.Question {
	rows, err := p.db.QueryContext(ctx, `
		SELECT `+questionColumns+`
		FROM assessment_questions aq JOIN questions q ON q.id = aq.question_id
		WHERE aq.assessment_id = $1 ORDER BY aq.position`, id)
	if err != nil {
		errLog("questionsForAssessment", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Question
	for rows.Next() {
		q, err := scanQuestion(rows)
		if err != nil {
			errLog("questionsForAssessment scan", err)
			continue
		}
		out = append(out, q)
	}
	return out
}

func (p *Postgres) Assessments() []domain.Assessment {
	rows, err := p.db.QueryContext(contextTODO(), `SELECT `+assessmentColumns+` FROM assessments ORDER BY id`)
	if err != nil {
		errLog("Assessments", err)
		return nil
	}
	defer rows.Close()
	ctx := contextTODO()
	var out []domain.Assessment
	for rows.Next() {
		a, err := scanAssessment(rows)
		if err != nil {
			errLog("Assessments scan", err)
			continue
		}
		a.Questions = p.questionsForAssessment(ctx, a.ID)
		out = append(out, a)
	}
	return out
}

func (p *Postgres) AssessmentByID(id string) (domain.Assessment, bool) {
	row := p.db.QueryRowContext(contextTODO(), `SELECT `+assessmentColumns+` FROM assessments WHERE id = $1`, id)
	a, err := scanAssessment(row)
	if err != nil {
		if err != sql.ErrNoRows {
			errLog("AssessmentByID", err)
		}
		return domain.Assessment{}, false
	}
	a.Questions = p.questionsForAssessment(contextTODO(), a.ID)
	return a, true
}

func (p *Postgres) SaveAssessment(a domain.Assessment) {
	tx, err := p.db.BeginTx(contextTODO(), nil)
	if err != nil {
		errLog("SaveAssessment begin", err)
		return
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(contextTODO(), `
		INSERT INTO assessments (id, title, type, subject_id, class_id, date, created_by)
		VALUES ($1,$2,$3,$4,$5,$6,$7)
		ON CONFLICT (id) DO UPDATE SET
			title = EXCLUDED.title, type = EXCLUDED.type, subject_id = EXCLUDED.subject_id,
			class_id = EXCLUDED.class_id, date = EXCLUDED.date, created_by = EXCLUDED.created_by`,
		a.ID, a.Title, a.Type, a.SubjectID, a.ClassID, a.Date, nullStr(a.CreatedBy)); err != nil {
		errLog("SaveAssessment", err)
		return
	}
	if _, err := tx.ExecContext(contextTODO(),
		`DELETE FROM assessment_questions WHERE assessment_id = $1`, a.ID); err != nil {
		errLog("SaveAssessment questions delete", err)
		return
	}
	for i, q := range a.Questions {
		if _, err := tx.ExecContext(contextTODO(),
			`INSERT INTO assessment_questions (assessment_id, question_id, position)
			 VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, a.ID, q.ID, i); err != nil {
			errLog("SaveAssessment question link", err)
			return
		}
	}
	if err := tx.Commit(); err != nil {
		errLog("SaveAssessment commit", err)
	}
}

// --- Submissions (doc §26) ---

const submissionColumns = `id, assessment_id, student_id, class_id, date::text,
	COALESCE(answers::text,'{}'), COALESCE(teacher_marks::text,'{}'), earned::float8`

func scanSubmission(row interface{ Scan(...any) error }) (domain.Submission, error) {
	var s domain.Submission
	var answers, marks string
	err := row.Scan(&s.ID, &s.AssessmentID, &s.StudentID, &s.ClassID, &s.Date, &answers, &marks, &s.Earned)
	if err == nil {
		_ = json.Unmarshal([]byte(answers), &s.Answers)
		_ = json.Unmarshal([]byte(marks), &s.TeacherMarks)
		if s.Answers == nil {
			s.Answers = map[string]string{}
		}
		if s.TeacherMarks == nil {
			s.TeacherMarks = map[string]float64{}
		}
	}
	return s, err
}

func (p *Postgres) Submissions() []domain.Submission {
	rows, err := p.db.QueryContext(contextTODO(), `SELECT `+submissionColumns+` FROM submissions ORDER BY id`)
	if err != nil {
		errLog("Submissions", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Submission
	for rows.Next() {
		s, err := scanSubmission(rows)
		if err != nil {
			errLog("Submissions scan", err)
			continue
		}
		out = append(out, s)
	}
	return out
}

func (p *Postgres) SubmissionFor(assessmentID, studentID string) (domain.Submission, bool) {
	row := p.db.QueryRowContext(contextTODO(),
		`SELECT `+submissionColumns+` FROM submissions WHERE assessment_id = $1 AND student_id = $2`,
		assessmentID, studentID)
	s, err := scanSubmission(row)
	if err != nil {
		if err != sql.ErrNoRows {
			errLog("SubmissionFor", err)
		}
		return domain.Submission{}, false
	}
	return s, true
}

func (p *Postgres) SaveSubmission(s domain.Submission) {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO submissions (id, assessment_id, student_id, class_id, date, answers, teacher_marks, earned, status)
		VALUES ($1,$2,$3,$4,$5,$6::jsonb,$7::jsonb,$8,'auto_marked')
		ON CONFLICT (assessment_id, student_id) DO UPDATE SET
			id = EXCLUDED.id, class_id = EXCLUDED.class_id, date = EXCLUDED.date,
			answers = EXCLUDED.answers, teacher_marks = EXCLUDED.teacher_marks,
			earned = EXCLUDED.earned, status = EXCLUDED.status`,
		s.ID, s.AssessmentID, s.StudentID, s.ClassID, s.Date,
		toJSON(s.Answers), toJSON(s.TeacherMarks), s.Earned)
	if err != nil {
		errLog("SaveSubmission", err)
	}
}

// --- Interventions (doc §31) ---

const interventionColumns = `id, student_id, topic, action, COALESCE(assigned_by,''),
	COALESCE(created_date::text,''), status, COALESCE(reassessment_assessment_id,'')`

func scanIntervention(row interface{ Scan(...any) error }) (domain.Intervention, error) {
	var i domain.Intervention
	err := row.Scan(&i.ID, &i.StudentID, &i.Topic, &i.Action, &i.AssignedBy,
		&i.CreatedDate, &i.Status, &i.ReassessmentAssessmentID)
	return i, err
}

func (p *Postgres) Interventions() []domain.Intervention {
	rows, err := p.db.QueryContext(contextTODO(),
		`SELECT `+interventionColumns+` FROM interventions ORDER BY created_date, id`)
	if err != nil {
		errLog("Interventions", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Intervention
	for rows.Next() {
		i, err := scanIntervention(rows)
		if err != nil {
			errLog("Interventions scan", err)
			continue
		}
		out = append(out, i)
	}
	return out
}

func (p *Postgres) InterventionByID(id string) (domain.Intervention, bool) {
	row := p.db.QueryRowContext(contextTODO(),
		`SELECT `+interventionColumns+` FROM interventions WHERE id = $1`, id)
	i, err := scanIntervention(row)
	if err != nil {
		if err != sql.ErrNoRows {
			errLog("InterventionByID", err)
		}
		return domain.Intervention{}, false
	}
	return i, true
}

func (p *Postgres) InterventionsForStudent(id string) []domain.Intervention {
	rows, err := p.db.QueryContext(contextTODO(),
		`SELECT `+interventionColumns+` FROM interventions WHERE student_id = $1 ORDER BY created_date DESC, id DESC`, id)
	if err != nil {
		errLog("InterventionsForStudent", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Intervention
	for rows.Next() {
		i, err := scanIntervention(rows)
		if err != nil {
			errLog("InterventionsForStudent scan", err)
			continue
		}
		out = append(out, i)
	}
	return out
}

func (p *Postgres) SaveIntervention(i domain.Intervention) {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO interventions (id, student_id, topic, action, assigned_by, created_date, status, reassessment_assessment_id)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
		ON CONFLICT (id) DO UPDATE SET
			student_id = EXCLUDED.student_id, topic = EXCLUDED.topic, action = EXCLUDED.action,
			assigned_by = EXCLUDED.assigned_by, created_date = EXCLUDED.created_date,
			status = EXCLUDED.status, reassessment_assessment_id = EXCLUDED.reassessment_assessment_id`,
		i.ID, i.StudentID, i.Topic, i.Action, nullStr(i.AssignedBy),
		i.CreatedDate, i.Status, nullStr(i.ReassessmentAssessmentID))
	if err != nil {
		errLog("SaveIntervention", err)
	}
}

// --- Communication (doc §40) ---

func (p *Postgres) Messages() []domain.Message {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, from_id, to_id, COALESCE(related_student_id,''), COALESCE(subject,''),
		       body, timestamp, COALESCE(read, FALSE)
		FROM messages ORDER BY id`)
	if err != nil {
		errLog("Messages", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Message
	for rows.Next() {
		var m domain.Message
		if err := rows.Scan(&m.ID, &m.FromID, &m.ToID, &m.RelatedStudentID, &m.Subject,
			&m.Body, &m.Timestamp, &m.Read); err != nil {
			errLog("Messages scan", err)
			continue
		}
		out = append(out, m)
	}
	return out
}

func (p *Postgres) SaveMessage(m domain.Message) {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO messages (id, from_id, to_id, related_student_id, subject, body, timestamp, read)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
		ON CONFLICT (id) DO NOTHING`,
		m.ID, m.FromID, m.ToID, nullStr(m.RelatedStudentID), nullStr(m.Subject),
		m.Body, m.Timestamp, m.Read)
	if err != nil {
		errLog("SaveMessage", err)
	}
}

func (p *Postgres) Announcements() []domain.Announcement {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT a.id, a.title, a.body, a.audience, COALESCE(a.target_class_id,''),
		       a.author_id, COALESCE(u.name,''), a.timestamp
		FROM announcements a LEFT JOIN users u ON u.id = a.author_id
		ORDER BY a.timestamp DESC, a.id DESC`)
	if err != nil {
		errLog("Announcements", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Announcement
	for rows.Next() {
		var a domain.Announcement
		if err := rows.Scan(&a.ID, &a.Title, &a.Body, &a.Audience, &a.TargetClassID,
			&a.AuthorID, &a.AuthorName, &a.Timestamp); err != nil {
			errLog("Announcements scan", err)
			continue
		}
		out = append(out, a)
	}
	return out
}

func (p *Postgres) AddAnnouncement(a domain.Announcement) {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO announcements (id, title, body, audience, target_class_id, author_id, timestamp)
		VALUES ($1,$2,$3,$4,$5,$6,$7)
		ON CONFLICT (id) DO NOTHING`,
		a.ID, a.Title, a.Body, a.Audience, nullStr(a.TargetClassID), a.AuthorID, a.Timestamp)
	if err != nil {
		errLog("AddAnnouncement", err)
	}
}

func (p *Postgres) Notifications() []domain.Notification {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, kind, title, COALESCE(body,''), timestamp,
		       COALESCE(student_id,''), COALESCE(user_id,''), COALESCE(read, FALSE)
		FROM notifications ORDER BY timestamp DESC, id DESC`)
	if err != nil {
		errLog("Notifications", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Notification
	for rows.Next() {
		var n domain.Notification
		if err := rows.Scan(&n.ID, &n.Kind, &n.Title, &n.Body, &n.Timestamp,
			&n.StudentID, &n.UserID, &n.Read); err != nil {
			errLog("Notifications scan", err)
			continue
		}
		out = append(out, n)
	}
	return out
}

func (p *Postgres) AddNotification(n domain.Notification) {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO notifications (id, kind, title, body, timestamp, student_id, user_id)
		VALUES ($1,$2,$3,$4,$5,$6,$7)
		ON CONFLICT (id) DO NOTHING`,
		n.ID, n.Kind, n.Title, nullStr(n.Body), n.Timestamp, nullStr(n.StudentID), nullStr(n.UserID))
	if err != nil {
		errLog("AddNotification", err)
	}
}

func (p *Postgres) SetNotificationRead(id string) {
	_, err := p.db.ExecContext(contextTODO(), `UPDATE notifications SET read = TRUE WHERE id = $1`, id)
	if err != nil {
		errLog("SetNotificationRead", err)
	}
}

// --- Assignments (doc §41) ---

func (p *Postgres) completedForAssignment(ctx context.Context, id string) []string {
	rows, err := p.db.QueryContext(ctx,
		`SELECT student_id FROM assignment_completions WHERE assignment_id = $1 ORDER BY student_id`, id)
	if err != nil {
		errLog("completedForAssignment", err)
		return nil
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var sid string
		if err := rows.Scan(&sid); err != nil {
			errLog("completedForAssignment scan", err)
			continue
		}
		out = append(out, sid)
	}
	return out
}

func (p *Postgres) Assignments() []domain.Assignment {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, class_id, subject_id, title, COALESCE(instructions,''),
		       deadline::text, COALESCE(created_by,''), COALESCE(created_at,'')
		FROM assignments ORDER BY id`)
	if err != nil {
		errLog("Assignments", err)
		return nil
	}
	defer rows.Close()
	ctx := contextTODO()
	var out []domain.Assignment
	for rows.Next() {
		var a domain.Assignment
		if err := rows.Scan(&a.ID, &a.ClassID, &a.SubjectID, &a.Title, &a.Instructions,
			&a.Deadline, &a.CreatedBy, &a.CreatedAt); err != nil {
			errLog("Assignments scan", err)
			continue
		}
		a.CompletedBy = p.completedForAssignment(ctx, a.ID)
		out = append(out, a)
	}
	return out
}

func (p *Postgres) AssignmentByID(id string) (domain.Assignment, bool) {
	row := p.db.QueryRowContext(contextTODO(), `
		SELECT id, class_id, subject_id, title, COALESCE(instructions,''),
		       deadline::text, COALESCE(created_by,''), COALESCE(created_at,'')
		FROM assignments WHERE id = $1`, id)
	var a domain.Assignment
	err := row.Scan(&a.ID, &a.ClassID, &a.SubjectID, &a.Title, &a.Instructions,
		&a.Deadline, &a.CreatedBy, &a.CreatedAt)
	if err != nil {
		if err != sql.ErrNoRows {
			errLog("AssignmentByID", err)
		}
		return domain.Assignment{}, false
	}
	a.CompletedBy = p.completedForAssignment(contextTODO(), a.ID)
	return a, true
}

func (p *Postgres) SaveAssignment(a domain.Assignment) {
	tx, err := p.db.BeginTx(contextTODO(), nil)
	if err != nil {
		errLog("SaveAssignment begin", err)
		return
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(contextTODO(), `
		INSERT INTO assignments (id, class_id, subject_id, title, instructions, deadline, created_by, created_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
		ON CONFLICT (id) DO UPDATE SET
			class_id = EXCLUDED.class_id, subject_id = EXCLUDED.subject_id, title = EXCLUDED.title,
			instructions = EXCLUDED.instructions, deadline = EXCLUDED.deadline,
			created_by = EXCLUDED.created_by, created_at = EXCLUDED.created_at`,
		a.ID, a.ClassID, a.SubjectID, a.Title, nullStr(a.Instructions),
		a.Deadline, nullStr(a.CreatedBy), nullStr(a.CreatedAt)); err != nil {
		errLog("SaveAssignment", err)
		return
	}
	if _, err := tx.ExecContext(contextTODO(),
		`DELETE FROM assignment_completions WHERE assignment_id = $1`, a.ID); err != nil {
		errLog("SaveAssignment completions delete", err)
		return
	}
	for _, sid := range a.CompletedBy {
		if _, err := tx.ExecContext(contextTODO(),
			`INSERT INTO assignment_completions (assignment_id, student_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`,
			a.ID, sid); err != nil {
			errLog("SaveAssignment completion", err)
			return
		}
	}
	if err := tx.Commit(); err != nil {
		errLog("SaveAssignment commit", err)
	}
}

// --- Audit (doc §49) ---

func (p *Postgres) AuditLogs() []domain.AuditEntry {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id::text, action, actor, COALESCE(target,''), COALESCE(detail,''),
		       COALESCE(reason,''), timestamp
		FROM audit_logs ORDER BY id`)
	if err != nil {
		errLog("AuditLogs", err)
		return nil
	}
	defer rows.Close()
	var out []domain.AuditEntry
	for rows.Next() {
		var e domain.AuditEntry
		if err := rows.Scan(&e.ID, &e.Action, &e.Actor, &e.Target, &e.Detail, &e.Reason, &e.Timestamp); err != nil {
			errLog("AuditLogs scan", err)
			continue
		}
		out = append(out, e)
	}
	return out
}

func (p *Postgres) AddAudit(e domain.AuditEntry) {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO audit_logs (action, actor, target, detail, reason, timestamp)
		VALUES ($1,$2,$3,$4,$5,$6)`,
		e.Action, e.Actor, nullStr(e.Target), nullStr(e.Detail), nullStr(e.Reason), e.Timestamp)
	if err != nil {
		errLog("AddAudit", err)
	}
}

// --- Refresh-token sessions ---

func (p *Postgres) SaveRefreshToken(hash, userID string, expiresAt int64) {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO refresh_tokens (hash, user_id, expires_at) VALUES ($1,$2,$3)
		ON CONFLICT (hash) DO UPDATE SET user_id = EXCLUDED.user_id, expires_at = EXCLUDED.expires_at`,
		hash, userID, expiresAt)
	if err != nil {
		errLog("SaveRefreshToken", err)
	}
}

func (p *Postgres) RefreshTokenLookup(hash string) (string, int64, bool) {
	var userID string
	var expiresAt int64
	row := p.db.QueryRowContext(contextTODO(),
		`SELECT user_id, expires_at FROM refresh_tokens WHERE hash = $1`, hash)
	err := row.Scan(&userID, &expiresAt)
	if err != nil {
		if err != sql.ErrNoRows {
			errLog("RefreshTokenLookup", err)
		}
		return "", 0, false
	}
	return userID, expiresAt, true
}

func (p *Postgres) DeleteRefreshToken(hash string) {
	_, err := p.db.ExecContext(contextTODO(), `DELETE FROM refresh_tokens WHERE hash = $1`, hash)
	if err != nil {
		errLog("DeleteRefreshToken", err)
	}
}

func (p *Postgres) DeleteRefreshTokensForUser(userID string) {
	_, err := p.db.ExecContext(contextTODO(), `DELETE FROM refresh_tokens WHERE user_id = $1`, userID)
	if err != nil {
		errLog("DeleteRefreshTokensForUser", err)
	}
}
