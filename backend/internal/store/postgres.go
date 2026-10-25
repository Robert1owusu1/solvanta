package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	"solvanta/backend/internal/domain"
	"solvanta/backend/migrations"
)

// Postgres is a Store implementation backed by PostgreSQL. It uses the schema
// in migrations/001_init.sql, which stores the same camelCase enum strings and
// display-level date/time strings the Flutter client sends and renders.
//
// Payload writes return an error, so a caller can decline to report success
// for a row that was never stored. Reads still cannot fail loudly — they fall
// back to empty/zero values — so anything that must know whether a read
// failed (a connection dropping mid-query) asks StoreErrors, or the health
// endpoint, instead of the individual call.
type Postgres struct {
	db *sql.DB

	// Writes return their error, but the detail (SQL, driver text) belongs in
	// a log rather than in an API response, and reads have no channel at all.
	// Every method therefore records here as well as returning where it can —
	// so a failure survives even where a caller deliberately ignores the
	// returned error (the seeder and most of this package's tests do), and the
	// boot path, /health and the tests can all ask whether anything failed.
	errMu     sync.Mutex
	errCount  int
	errLast   error
	errLastAt time.Time
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
	// database/sql starts with an UNLIMITED number of open connections and only
	// two idle. That is harmless against an in-process server but against a
	// remote pooler (Supabase's session pooler, PgBouncer, RDS Proxy) a load
	// spike opens connections until the server's limit is exhausted and starts
	// refusing the app outright. The Store contract is many short queries with
	// no long-held transactions, so a small bounded pool is plenty.
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(30 * time.Minute)
	db.SetConnMaxIdleTime(5 * time.Minute)
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
		// Seeding writes hundreds of rows through Store methods that cannot
		// report failure. Verify afterwards rather than boot an empty
		// application and call it healthy.
		before, _, _ := p.StoreErrors()
		Seed(p)
		if after, last, _ := p.StoreErrors(); after != before {
			db.Close()
			return nil, fmt.Errorf("seed: %w", last)
		}
	}
	return p, nil
}

// Close releases the underlying connection pool.
func (p *Postgres) Close() error { return p.db.Close() }

// p.errLog is the single choke point for storage failures. It logs for the
// operator and latches the failure, so reads (which have no channel at all)
// and writes whose error a caller chose to ignore can still be audited
// afterwards rather than passing unnoticed.
func (p *Postgres) errLog(verb string, err error) {
	log.Printf("postgres %s: %v", verb, err)
	p.errMu.Lock()
	defer p.errMu.Unlock()
	p.errCount++
	p.errLast = fmt.Errorf("%s: %w", verb, err)
	p.errLastAt = time.Now()
}

// StoreErrors reports how many storage operations have failed since this store
// was created, along with the most recent failure. A caller that cannot act on
// an individual error uses this instead of pretending the operation succeeded.
func (p *Postgres) StoreErrors() (count int, last error, at time.Time) {
	p.errMu.Lock()
	defer p.errMu.Unlock()
	return p.errCount, p.errLast, p.errLastAt
}

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
		p.errLog("School", err)
	}
	return s
}

func (p *Postgres) SaveSchool(s domain.School) error {
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
		p.errLog("SaveSchool", err)
		return err
	}

	return nil
}

func (p *Postgres) Term() domain.SchoolTerm {
	var t domain.SchoolTerm
	row := p.db.QueryRowContext(contextTODO(),
		`SELECT year, name, start_date::text, end_date::text FROM school_terms ORDER BY id DESC LIMIT 1`)
	err := row.Scan(&t.Year, &t.Name, &t.Start, &t.End)
	if err != nil && err != sql.ErrNoRows {
		p.errLog("Term", err)
	}
	return t
}

func (p *Postgres) SaveTerm(t domain.SchoolTerm) error {
	_, err := p.db.ExecContext(contextTODO(),
		`INSERT INTO school_terms (school_id, year, name, start_date, end_date)
		 VALUES ($1, $2, $3, $4, $5)`,
		domain.DefaultSchoolID(), t.Year, t.Name, t.Start, t.End)
	if err != nil {
		p.errLog("SaveTerm", err)
		return err
	}

	return nil
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
		p.errLog("studentIDsForUser", err)
		return nil
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var sid string
		if err := rows.Scan(&sid); err != nil {
			p.errLog("studentIDsForUser scan", err)
			continue
		}
		out = append(out, sid)
	}
	return out
}

func (p *Postgres) Users() []domain.User {
	rows, err := p.db.QueryContext(contextTODO(), `SELECT `+userColumns+` FROM users ORDER BY id`)
	if err != nil {
		p.errLog("Users", err)
		return nil
	}
	defer rows.Close()
	ctx := contextTODO()
	var out []domain.User
	for rows.Next() {
		u, err := scanUser(rows)
		if err != nil {
			p.errLog("Users scan", err)
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
			p.errLog("UserByID", err)
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
			p.errLog("UserByEmail", err)
		}
		return domain.User{}, false
	}
	u.StudentIDs = p.studentIDsForUser(contextTODO(), u.ID)
	return u, true
}

func (p *Postgres) SaveUser(u domain.User) error {
	tx, err := p.db.BeginTx(contextTODO(), nil)
	if err != nil {
		p.errLog("SaveUser begin", err)
		return err
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
		p.errLog("SaveUser", err)
		return err
	}
	if _, err := tx.ExecContext(contextTODO(), `DELETE FROM user_students WHERE user_id = $1`, u.ID); err != nil {
		p.errLog("SaveUser links delete", err)
		return err
	}
	// One statement for every link instead of one round trip per student: a
	// linked parent (all seven of the seed's do this) cost N round trips
	// against a remote pooler otherwise.
	if len(u.StudentIDs) > 0 {
		if _, err := tx.ExecContext(contextTODO(), `
			INSERT INTO user_students (user_id, student_id)
			SELECT $1, sid FROM jsonb_array_elements_text($2::jsonb) AS sid
			ON CONFLICT DO NOTHING`,
			u.ID, toJSON(u.StudentIDs)); err != nil {
			p.errLog("SaveUser link", err)
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		p.errLog("SaveUser commit", err)
		return err
	}

	return nil
}

// --- Classes ---

func (p *Postgres) Classes() []domain.ClassRoom {
	rows, err := p.db.QueryContext(contextTODO(),
		`SELECT id, name, COALESCE(stream,''), COALESCE(teacher_id,'') FROM class_rooms ORDER BY id`)
	if err != nil {
		p.errLog("Classes", err)
		return nil
	}
	defer rows.Close()
	var out []domain.ClassRoom
	for rows.Next() {
		var c domain.ClassRoom
		if err := rows.Scan(&c.ID, &c.Name, &c.Stream, &c.TeacherID); err != nil {
			p.errLog("Classes scan", err)
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
			p.errLog("ClassByID", err)
		}
		return domain.ClassRoom{}, false
	}
	return c, true
}

func (p *Postgres) SaveClass(c domain.ClassRoom) error {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO class_rooms (id, name, stream, teacher_id) VALUES ($1, $2, $3, $4)
		ON CONFLICT (id) DO UPDATE SET
			name = EXCLUDED.name, stream = EXCLUDED.stream, teacher_id = EXCLUDED.teacher_id`,
		c.ID, c.Name, nullStr(c.Stream), nullStr(c.TeacherID))
	if err != nil {
		p.errLog("SaveClass", err)
		return err
	}

	return nil
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
		p.errLog("contactsForStudents", err)
		return nil
	}
	defer rows.Close()
	out := map[string][]contactRow{}
	for rows.Next() {
		var sid, kind, name, phone, rel string
		if err := rows.Scan(&sid, &kind, &name, &phone, &rel); err != nil {
			p.errLog("contactsForStudents scan", err)
			continue
		}
		out[sid] = append(out[sid], contactRow{Kind: kind, Person: domain.Person{Name: name, Phone: phone, Relation: rel}})
	}
	return out
}

// contactsForStudent is the single-student form of contactsForStudents.
// StudentByID used to resolve ONE student's contacts by reading the entire
// contact table, so every gate check-in paid to ship every other student's
// guardians back across the pool.
func (p *Postgres) contactsForStudent(ctx context.Context, studentID string) []contactRow {
	rows, err := p.db.QueryContext(ctx,
		`SELECT kind, name, COALESCE(phone,''), COALESCE(relation,'')
		 FROM student_contacts WHERE student_id = $1 ORDER BY id`, studentID)
	if err != nil {
		p.errLog("contactsForStudent", err)
		return nil
	}
	defer rows.Close()
	var out []contactRow
	for rows.Next() {
		var kind, name, phone, rel string
		if err := rows.Scan(&kind, &name, &phone, &rel); err != nil {
			p.errLog("contactsForStudent scan", err)
			continue
		}
		out = append(out, contactRow{Kind: kind, Person: domain.Person{Name: name, Phone: phone, Relation: rel}})
	}
	return out
}

func (p *Postgres) attachContacts(s *domain.Student, contacts []contactRow) {
	for _, c := range contacts {
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
		p.errLog("Students", err)
		return nil
	}
	defer rows.Close()
	contacts := p.contactsForStudents(contextTODO())
	var out []domain.Student
	for rows.Next() {
		s, err := scanStudent(rows)
		if err != nil {
			p.errLog("Students scan", err)
			continue
		}
		p.attachContacts(&s, contacts[s.ID])
		out = append(out, s)
	}
	return out
}

func (p *Postgres) StudentByID(id string) (domain.Student, bool) {
	row := p.db.QueryRowContext(contextTODO(), `SELECT `+studentColumns+` FROM students WHERE id = $1`, id)
	s, err := scanStudent(row)
	if err != nil {
		if err != sql.ErrNoRows {
			p.errLog("StudentByID", err)
		}
		return domain.Student{}, false
	}
	p.attachContacts(&s, p.contactsForStudent(contextTODO(), id))
	return s, true
}

func (p *Postgres) StudentsByParentUser(id string) []domain.Student {
	rows, err := p.db.QueryContext(contextTODO(),
		`SELECT `+studentColumns+` FROM students WHERE parent_user_id = $1 ORDER BY id`, id)
	if err != nil {
		p.errLog("StudentsByParentUser", err)
		return nil
	}
	defer rows.Close()
	contacts := p.contactsForStudents(contextTODO())
	var out []domain.Student
	for rows.Next() {
		s, err := scanStudent(rows)
		if err != nil {
			p.errLog("StudentsByParentUser scan", err)
			continue
		}
		p.attachContacts(&s, contacts[s.ID])
		out = append(out, s)
	}
	return out
}

func (p *Postgres) SaveStudent(s domain.Student) error {
	tx, err := p.db.BeginTx(contextTODO(), nil)
	if err != nil {
		p.errLog("SaveStudent begin", err)
		return err
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
		p.errLog("SaveStudent", err)
		return err
	}
	if _, err := tx.ExecContext(contextTODO(), `DELETE FROM student_contacts WHERE student_id = $1`, s.ID); err != nil {
		p.errLog("SaveStudent contacts delete", err)
		return err
	}
	writeContacts := func(kind string, people []domain.Person) error {
		if len(people) == 0 {
			return nil
		}
		// One statement per contact kind instead of one round trip per person:
		// every student carries guardians, emergency contacts and authorized
		// pickups, so a student's contacts alone used to cost several round
		// trips against a remote pooler.
		if _, err := tx.ExecContext(contextTODO(), `
			INSERT INTO student_contacts (student_id, kind, name, phone, relation)
			SELECT $1, $2, v->>'name', NULLIF(v->>'phone',''), NULLIF(v->>'relation','')
			FROM jsonb_array_elements($3::jsonb) AS v`,
			s.ID, kind, toJSON(people)); err != nil {
			p.errLog("SaveStudent contact", err)
			return err
		}
		return nil
	}
	// Contacts ride the same transaction as the student row, so one failing
	// kind rolls all of it back rather than committing a student whose
	// guardians were silently dropped.
	for _, c := range []struct {
		kind   string
		people []domain.Person
	}{
		{"guardian", s.Guardians},
		{"emergency", s.EmergencyContacts},
		{"authorizedPickup", s.AuthorizedPickup},
	} {
		if err := writeContacts(c.kind, c.people); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		p.errLog("SaveStudent commit", err)
		return err
	}

	return nil
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
		p.errLog("Attendance", err)
		return nil
	}
	defer rows.Close()
	var out []domain.AttendanceRecord
	for rows.Next() {
		r, err := scanAttendance(rows)
		if err != nil {
			p.errLog("Attendance scan", err)
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
		p.errLog("AttendanceForClassDate", err)
		return nil
	}
	defer rows.Close()
	var out []domain.AttendanceRecord
	for rows.Next() {
		r, err := scanAttendance(rows)
		if err != nil {
			p.errLog("AttendanceForClassDate scan", err)
			continue
		}
		out = append(out, r)
	}
	return out
}

// upsertAttendanceBatch writes every record with a single statement. Both
// attendance writers used to issue one round trip per record inside their
// transaction, so seeding a term cost one round trip per student/day (~150ms
// each against a remote pooler). The conflict clause is passed in because
// SaveAttendance must never overwrite a record recorded at runtime (DO NOTHING)
// while SaveDay replaces that class/date bucket (DO UPDATE).
func (p *Postgres) upsertAttendanceBatch(tx *sql.Tx, conflict string, records []domain.AttendanceRecord) error {
	if len(records) == 0 {
		return nil
	}
	// Field names match domain.AttendanceRecord's json tags. JSON extraction
	// yields text, so the DATE/TIME columns need casts the bound-parameter form
	// used to get from inference; the omitempty ones are wrapped in NULLIF so an
	// absent/empty value stays NULL rather than blowing up `''::time`.
	_, err := tx.ExecContext(contextTODO(), `
		INSERT INTO attendance (id, student_id, class_id, date, status, check_in, check_out, old_status, reason)
		SELECT v->>'id', v->>'studentId', v->>'classId', (v->>'date')::date, v->>'status',
		       NULLIF(v->>'checkIn','')::time, NULLIF(v->>'checkOut','')::time,
		       NULLIF(v->>'oldStatus',''), NULLIF(v->>'reason','')
		FROM jsonb_array_elements($1::jsonb) AS v
		`+conflict, toJSON(records))
	return err
}

// SaveAttendance merges records into the attendance log. It is the bootstrap
// path (the seed), so it must be idempotent and non-destructive: a student/day
// that already has a record is left exactly as it is, and no other attendance
// is ever deleted. This previously deleted every row whose id was not in the
// supplied set — and deleted the whole table for an empty set — so restarting
// the server with seed=true silently destroyed attendance recorded at runtime.
func (p *Postgres) SaveAttendance(records []domain.AttendanceRecord) error {
	if len(records) == 0 {
		return nil
	}
	tx, err := p.db.BeginTx(contextTODO(), nil)
	if err != nil {
		p.errLog("SaveAttendance begin", err)
		return err
	}
	defer tx.Rollback()
	// No conflict target on purpose: bare DO NOTHING guards every unique
	// constraint (student_id+date and id), so an existing real record always
	// wins over the seeded one.
	if err := p.upsertAttendanceBatch(tx, `ON CONFLICT DO NOTHING`, records); err != nil {
		p.errLog("SaveAttendance insert", err)
		return err
	}
	if err := tx.Commit(); err != nil {
		p.errLog("SaveAttendance commit", err)
		return err
	}

	return nil
}

// SaveDay replaces one class/date bucket.
func (p *Postgres) SaveDay(classID, date string, records []domain.AttendanceRecord) error {
	tx, err := p.db.BeginTx(contextTODO(), nil)
	if err != nil {
		p.errLog("SaveDay begin", err)
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(contextTODO(),
		`DELETE FROM attendance WHERE class_id = $1 AND date = $2`, classID, date); err != nil {
		p.errLog("SaveDay delete", err)
		return err
	}
	// Abort — rolling back the delete above — if the batch fails, rather than
	// committing a day that was only partly rewritten.
	if err := p.upsertAttendanceBatch(tx, `
		ON CONFLICT (student_id, date) DO UPDATE SET
			id = EXCLUDED.id, class_id = EXCLUDED.class_id, status = EXCLUDED.status,
			check_in = EXCLUDED.check_in, check_out = EXCLUDED.check_out,
			old_status = EXCLUDED.old_status, reason = EXCLUDED.reason`, records); err != nil {
		p.errLog("SaveDay upsert", err)
		return err
	}
	if err := tx.Commit(); err != nil {
		p.errLog("SaveDay commit", err)
		return err
	}

	return nil
}

// --- Gate (doc §13) ---

func (p *Postgres) GateEvents() []domain.GateEvent {
	rows, err := p.db.QueryContext(contextTODO(),
		`SELECT id, student_id, type, to_char(time, 'HH24:MI'), date::text,
		        COALESCE(reporter,''), COALESCE(person,''), COALESCE(detail,'')
		 FROM gate_events ORDER BY date DESC, time DESC`)
	if err != nil {
		p.errLog("GateEvents", err)
		return nil
	}
	defer rows.Close()
	var out []domain.GateEvent
	for rows.Next() {
		var e domain.GateEvent
		if err := rows.Scan(&e.ID, &e.StudentID, &e.Type, &e.Time, &e.Date, &e.Reporter, &e.Person, &e.Detail); err != nil {
			p.errLog("GateEvents scan", err)
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
		p.errLog("GateForStudent", err)
		return nil
	}
	defer rows.Close()
	var out []domain.GateEvent
	for rows.Next() {
		var e domain.GateEvent
		if err := rows.Scan(&e.ID, &e.StudentID, &e.Type, &e.Time, &e.Date, &e.Reporter, &e.Person, &e.Detail); err != nil {
			p.errLog("GateForStudent scan", err)
			continue
		}
		out = append(out, e)
	}
	return out
}

func (p *Postgres) AddGateEvent(e domain.GateEvent) error {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO gate_events (id, student_id, type, time, date, reporter, person, detail)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
		ON CONFLICT (id) DO NOTHING`,
		e.ID, e.StudentID, e.Type, e.Time, e.Date, nullStr(e.Reporter), nullStr(e.Person), nullStr(e.Detail))
	if err != nil {
		p.errLog("AddGateEvent", err)
		return err
	}

	return nil
}

// --- Questions (doc §17) ---

const questionColumns = `id, type, subject_id, COALESCE(class_id,''), topic, difficulty,
	COALESCE(cognitive_level,''), marks::float8, stem, COALESCE(options::text,'[]'),
	COALESCE(correct_answer,''), COALESCE(explanation,''), COALESCE(marking_scheme,'')`

// questionDests returns the Scan destinations for questionColumns, preceded by
// any extra columns the caller selected before them. Splitting the field list
// out lets the batched reader scan assessment_id alongside the question without
// duplicating the column list — and therefore drifting from it.
func questionDests(q *domain.Question, opts *string, extra ...any) []any {
	return append(extra,
		&q.ID, &q.Type, &q.SubjectID, &q.ClassID, &q.Topic, &q.Difficulty,
		&q.CognitiveLevel, &q.Marks, &q.Stem, opts,
		&q.CorrectAnswer, &q.Explanation, &q.MarkingScheme)
}

// finishQuestion decodes the options column, which is stored as JSON text and
// may come back NULL when a question has no options at all.
func finishQuestion(q *domain.Question, opts string) {
	_ = json.Unmarshal([]byte(opts), &q.Options)
	if q.Options == nil {
		q.Options = []string{}
	}
}

func scanQuestion(row interface{ Scan(...any) error }) (domain.Question, error) {
	var q domain.Question
	var opts string
	if err := row.Scan(questionDests(&q, &opts)...); err != nil {
		return q, err
	}
	finishQuestion(&q, opts)
	return q, nil
}

func (p *Postgres) Questions() []domain.Question {
	rows, err := p.db.QueryContext(contextTODO(), `SELECT `+questionColumns+` FROM questions ORDER BY id`)
	if err != nil {
		p.errLog("Questions", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Question
	for rows.Next() {
		q, err := scanQuestion(rows)
		if err != nil {
			p.errLog("Questions scan", err)
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
			p.errLog("QuestionByID", err)
		}
		return domain.Question{}, false
	}
	return q, true
}

func (p *Postgres) SaveQuestion(q domain.Question) error {
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
		p.errLog("SaveQuestion", err)
		return err
	}

	return nil
}

func (p *Postgres) DeleteQuestion(id string) error {
	_, err := p.db.ExecContext(contextTODO(), `DELETE FROM questions WHERE id = $1`, id)
	if err != nil {
		p.errLog("DeleteQuestion", err)
		return err
	}

	return nil
}

// DeleteClass removes a class. The handler refuses classes still in use, so
// no foreign key to class_rooms is left dangling.
func (p *Postgres) DeleteClass(id string) error {
	_, err := p.db.ExecContext(contextTODO(), `DELETE FROM class_rooms WHERE id = $1`, id)
	if err != nil {
		p.errLog("DeleteClass", err)
		return err
	}

	return nil
}

func (p *Postgres) DeleteAnnouncement(id string) error {
	_, err := p.db.ExecContext(contextTODO(), `DELETE FROM announcements WHERE id = $1`, id)
	if err != nil {
		p.errLog("DeleteAnnouncement", err)
		return err
	}

	return nil
}

// DeleteAssignment removes an assignment; its completions cascade.
func (p *Postgres) DeleteAssignment(id string) error {
	_, err := p.db.ExecContext(contextTODO(), `DELETE FROM assignments WHERE id = $1`, id)
	if err != nil {
		p.errLog("DeleteAssignment", err)
		return err
	}

	return nil
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
		p.errLog("AIRequests", err)
		return nil
	}
	defer rows.Close()
	var out []domain.GenRequest
	for rows.Next() {
		g, err := scanGenRequest(rows)
		if err != nil {
			p.errLog("AIRequests scan", err)
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
			p.errLog("AIRequestByID", err)
		}
		return domain.GenRequest{}, false
	}
	return g, true
}

func (p *Postgres) SaveAIRequest(r domain.GenRequest) error {
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
		p.errLog("SaveAIRequest", err)
		return err
	}

	return nil
}

// --- Assessments (doc §16) ---

const assessmentColumns = `id, title, type, subject_id, class_id, date::text, COALESCE(created_by,'')`

func scanAssessment(row interface{ Scan(...any) error }) (domain.Assessment, error) {
	var a domain.Assessment
	err := row.Scan(&a.ID, &a.Title, &a.Type, &a.SubjectID, &a.ClassID, &a.Date, &a.CreatedBy)
	return a, err
}

// questionsForAssessments loads the questions of every given assessment in a
// single round trip, grouped by assessment id.
//
// This replaces one query per assessment. Against a remote pooler (~150ms per
// round trip) that difference is the whole story of GET /api/assessments: four
// assessments used to cost five round trips, and the cost scaled with the size
// of the school instead of staying constant.
func (p *Postgres) questionsForAssessments(ctx context.Context, ids []string) map[string][]domain.Question {
	out := make(map[string][]domain.Question, len(ids))
	if len(ids) == 0 {
		return out
	}
	rows, err := p.db.QueryContext(ctx, `
		SELECT aq.assessment_id, `+questionColumns+`
		FROM assessment_questions aq JOIN questions q ON q.id = aq.question_id
		WHERE aq.assessment_id IN (SELECT jsonb_array_elements_text($1::jsonb))
		ORDER BY aq.assessment_id, aq.position`, toJSON(ids))
	if err != nil {
		p.errLog("questionsForAssessments", err)
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var aid string
		var q domain.Question
		var opts string
		if err := rows.Scan(questionDests(&q, &opts, &aid)...); err != nil {
			p.errLog("questionsForAssessments scan", err)
			continue
		}
		finishQuestion(&q, opts)
		out[aid] = append(out[aid], q)
	}
	return out
}

// questionsForAssessment is the single-assessment form. It is one round trip
// either way, so it reuses the batch instead of keeping a second query alive.
func (p *Postgres) questionsForAssessment(ctx context.Context, id string) []domain.Question {
	return p.questionsForAssessments(ctx, []string{id})[id]
}

func (p *Postgres) Assessments() []domain.Assessment {
	rows, err := p.db.QueryContext(contextTODO(), `SELECT `+assessmentColumns+` FROM assessments ORDER BY id`)
	if err != nil {
		p.errLog("Assessments", err)
		return nil
	}
	var out []domain.Assessment
	for rows.Next() {
		a, err := scanAssessment(rows)
		if err != nil {
			p.errLog("Assessments scan", err)
			continue
		}
		out = append(out, a)
	}
	// Release this reader before the follow-up query so the batch below does
	// not need a second pooled connection.
	rows.Close()

	ids := make([]string, 0, len(out))
	for i := range out {
		ids = append(ids, out[i].ID)
	}
	byAssessment := p.questionsForAssessments(contextTODO(), ids)
	for i := range out {
		out[i].Questions = byAssessment[out[i].ID]
	}
	return out
}

func (p *Postgres) AssessmentByID(id string) (domain.Assessment, bool) {
	row := p.db.QueryRowContext(contextTODO(), `SELECT `+assessmentColumns+` FROM assessments WHERE id = $1`, id)
	a, err := scanAssessment(row)
	if err != nil {
		if err != sql.ErrNoRows {
			p.errLog("AssessmentByID", err)
		}
		return domain.Assessment{}, false
	}
	a.Questions = p.questionsForAssessment(contextTODO(), a.ID)
	return a, true
}

func (p *Postgres) SaveAssessment(a domain.Assessment) error {
	tx, err := p.db.BeginTx(contextTODO(), nil)
	if err != nil {
		p.errLog("SaveAssessment begin", err)
		return err
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(contextTODO(), `
		INSERT INTO assessments (id, title, type, subject_id, class_id, date, created_by)
		VALUES ($1,$2,$3,$4,$5,$6,$7)
		ON CONFLICT (id) DO UPDATE SET
			title = EXCLUDED.title, type = EXCLUDED.type, subject_id = EXCLUDED.subject_id,
			class_id = EXCLUDED.class_id, date = EXCLUDED.date, created_by = EXCLUDED.created_by`,
		a.ID, a.Title, a.Type, a.SubjectID, a.ClassID, a.Date, nullStr(a.CreatedBy)); err != nil {
		p.errLog("SaveAssessment", err)
		return err
	}
	if _, err := tx.ExecContext(contextTODO(),
		`DELETE FROM assessment_questions WHERE assessment_id = $1`, a.ID); err != nil {
		p.errLog("SaveAssessment questions delete", err)
		return err
	}
	for i, q := range a.Questions {
		if _, err := tx.ExecContext(contextTODO(),
			`INSERT INTO assessment_questions (assessment_id, question_id, position)
			 VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, a.ID, q.ID, i); err != nil {
			p.errLog("SaveAssessment question link", err)
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		p.errLog("SaveAssessment commit", err)
		return err
	}

	return nil
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
		p.errLog("Submissions", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Submission
	for rows.Next() {
		s, err := scanSubmission(rows)
		if err != nil {
			p.errLog("Submissions scan", err)
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
			p.errLog("SubmissionFor", err)
		}
		return domain.Submission{}, false
	}
	return s, true
}

// SaveSubmission upserts a submission. answers and teacher_marks are NOT NULL,
// but toJSON intentionally yields SQL NULL for an empty map - which is right for
// the nullable questions.options and requests.drafts columns, and wrong here: an
// unattempted or not-yet-marked submission was rejected with SQLSTATE 23502 and
// the row silently dropped. Coalesce so "empty" stores '{}' instead.
func (p *Postgres) SaveSubmission(s domain.Submission) error {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO submissions (id, assessment_id, student_id, class_id, date, answers, teacher_marks, earned, status)
		VALUES ($1,$2,$3,$4,$5,COALESCE($6::jsonb,'{}'::jsonb),COALESCE($7::jsonb,'{}'::jsonb),$8,'auto_marked')
		ON CONFLICT (assessment_id, student_id) DO UPDATE SET
			id = EXCLUDED.id, class_id = EXCLUDED.class_id, date = EXCLUDED.date,
			answers = EXCLUDED.answers, teacher_marks = EXCLUDED.teacher_marks,
			earned = EXCLUDED.earned, status = EXCLUDED.status`,
		s.ID, s.AssessmentID, s.StudentID, s.ClassID, s.Date,
		toJSON(s.Answers), toJSON(s.TeacherMarks), s.Earned)
	if err != nil {
		p.errLog("SaveSubmission", err)
		return err
	}

	return nil
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
		p.errLog("Interventions", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Intervention
	for rows.Next() {
		i, err := scanIntervention(rows)
		if err != nil {
			p.errLog("Interventions scan", err)
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
			p.errLog("InterventionByID", err)
		}
		return domain.Intervention{}, false
	}
	return i, true
}

func (p *Postgres) InterventionsForStudent(id string) []domain.Intervention {
	rows, err := p.db.QueryContext(contextTODO(),
		`SELECT `+interventionColumns+` FROM interventions WHERE student_id = $1 ORDER BY created_date DESC, id DESC`, id)
	if err != nil {
		p.errLog("InterventionsForStudent", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Intervention
	for rows.Next() {
		i, err := scanIntervention(rows)
		if err != nil {
			p.errLog("InterventionsForStudent scan", err)
			continue
		}
		out = append(out, i)
	}
	return out
}

func (p *Postgres) SaveIntervention(i domain.Intervention) error {
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
		p.errLog("SaveIntervention", err)
		return err
	}

	return nil
}

// --- Communication (doc §40) ---

func (p *Postgres) Messages() []domain.Message {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, from_id, to_id, COALESCE(related_student_id,''), COALESCE(subject,''),
		       body, timestamp, COALESCE(read, FALSE),
		       COALESCE(delivered_at,''), COALESCE(read_at,'')
		FROM messages ORDER BY id`)
	if err != nil {
		p.errLog("Messages", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Message
	for rows.Next() {
		var m domain.Message
		if err := rows.Scan(&m.ID, &m.FromID, &m.ToID, &m.RelatedStudentID, &m.Subject,
			&m.Body, &m.Timestamp, &m.Read, &m.DeliveredAt, &m.ReadAt); err != nil {
			p.errLog("Messages scan", err)
			continue
		}
		out = append(out, m)
	}
	return out
}

func (p *Postgres) SaveMessage(m domain.Message) error {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO messages (id, from_id, to_id, related_student_id, subject, body, timestamp, read)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
		ON CONFLICT (id) DO NOTHING`,
		m.ID, m.FromID, m.ToID, nullStr(m.RelatedStudentID), nullStr(m.Subject),
		m.Body, m.Timestamp, m.Read)
	if err != nil {
		p.errLog("SaveMessage", err)
		return err
	}

	return nil
}

func (p *Postgres) Announcements() []domain.Announcement {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT a.id, a.title, a.body, a.audience, COALESCE(a.target_class_id,''),
		       a.author_id, COALESCE(u.name,''), a.timestamp
		FROM announcements a LEFT JOIN users u ON u.id = a.author_id
		ORDER BY a.timestamp DESC, a.id DESC`)
	if err != nil {
		p.errLog("Announcements", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Announcement
	for rows.Next() {
		var a domain.Announcement
		if err := rows.Scan(&a.ID, &a.Title, &a.Body, &a.Audience, &a.TargetClassID,
			&a.AuthorID, &a.AuthorName, &a.Timestamp); err != nil {
			p.errLog("Announcements scan", err)
			continue
		}
		out = append(out, a)
	}
	return out
}

func (p *Postgres) AddAnnouncement(a domain.Announcement) error {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO announcements (id, title, body, audience, target_class_id, author_id, timestamp)
		VALUES ($1,$2,$3,$4,$5,$6,$7)
		ON CONFLICT (id) DO NOTHING`,
		a.ID, a.Title, a.Body, a.Audience, nullStr(a.TargetClassID), a.AuthorID, a.Timestamp)
	if err != nil {
		p.errLog("AddAnnouncement", err)
		return err
	}

	return nil
}

func (p *Postgres) Notifications() []domain.Notification {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, kind, title, COALESCE(body,''), timestamp,
		       COALESCE(student_id,''), COALESCE(user_id,''), COALESCE(read, FALSE)
		FROM notifications ORDER BY timestamp DESC, id DESC`)
	if err != nil {
		p.errLog("Notifications", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Notification
	for rows.Next() {
		var n domain.Notification
		if err := rows.Scan(&n.ID, &n.Kind, &n.Title, &n.Body, &n.Timestamp,
			&n.StudentID, &n.UserID, &n.Read); err != nil {
			p.errLog("Notifications scan", err)
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
		p.errLog("AddNotification", err)
	}
}

func (p *Postgres) SetNotificationRead(id string) error {
	_, err := p.db.ExecContext(contextTODO(), `UPDATE notifications SET read = TRUE WHERE id = $1`, id)
	if err != nil {
		p.errLog("SetNotificationRead", err)
		return err
	}

	return nil
}

func (p *Postgres) MarkNotificationReadBy(id, userID string) error {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO notification_reads (notification_id, user_id) VALUES ($1,$2)
		ON CONFLICT DO NOTHING`, id, userID)
	if err != nil {
		p.errLog("MarkNotificationReadBy", err)
		return err
	}

	return nil
}

func (p *Postgres) NotificationReadsBy(userID string) map[string]bool {
	out := map[string]bool{}
	rows, err := p.db.QueryContext(contextTODO(),
		`SELECT notification_id FROM notification_reads WHERE user_id = $1`, userID)
	if err != nil {
		p.errLog("NotificationReadsBy", err)
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			p.errLog("NotificationReadsBy scan", err)
			continue
		}
		out[id] = true
	}
	return out
}

// SetMessageReceipt stamps the first delivery/read time; later reports never
// move a stamp.
func (p *Postgres) SetMessageReceipt(id, deliveredAt, readAt string) error {
	_, err := p.db.ExecContext(contextTODO(), `
		UPDATE messages SET
			delivered_at = COALESCE(delivered_at, NULLIF($2,'')),
			read_at      = COALESCE(read_at, NULLIF($3,'')),
			read         = read OR $3 <> ''
		WHERE id = $1`, id, deliveredAt, readAt)
	if err != nil {
		p.errLog("SetMessageReceipt", err)
		return err
	}

	return nil
}

// --- Assignments (doc §41) ---

// completedForAssignments loads every assignment's completion list in one
// round trip instead of one query per assignment (see questionsForAssessments
// for why the difference matters against a remote pooler).
func (p *Postgres) completedForAssignments(ctx context.Context, ids []string) map[string][]string {
	out := make(map[string][]string, len(ids))
	if len(ids) == 0 {
		return out
	}
	rows, err := p.db.QueryContext(ctx, `
		SELECT assignment_id, student_id FROM assignment_completions
		WHERE assignment_id IN (SELECT jsonb_array_elements_text($1::jsonb))
		ORDER BY assignment_id, student_id`, toJSON(ids))
	if err != nil {
		p.errLog("completedForAssignments", err)
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var aid, sid string
		if err := rows.Scan(&aid, &sid); err != nil {
			p.errLog("completedForAssignments scan", err)
			continue
		}
		out[aid] = append(out[aid], sid)
	}
	return out
}

// completedForAssignment is the single-assignment form of the batch above.
func (p *Postgres) completedForAssignment(ctx context.Context, id string) []string {
	return p.completedForAssignments(ctx, []string{id})[id]
}

func (p *Postgres) Assignments() []domain.Assignment {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, class_id, subject_id, title, COALESCE(instructions,''),
		       deadline::text, COALESCE(created_by,''), COALESCE(created_at,'')
		FROM assignments ORDER BY id`)
	if err != nil {
		p.errLog("Assignments", err)
		return nil
	}
	var out []domain.Assignment
	for rows.Next() {
		var a domain.Assignment
		if err := rows.Scan(&a.ID, &a.ClassID, &a.SubjectID, &a.Title, &a.Instructions,
			&a.Deadline, &a.CreatedBy, &a.CreatedAt); err != nil {
			p.errLog("Assignments scan", err)
			continue
		}
		out = append(out, a)
	}
	// Release this reader before the follow-up query (see Assessments).
	rows.Close()

	ids := make([]string, 0, len(out))
	for i := range out {
		ids = append(ids, out[i].ID)
	}
	completed := p.completedForAssignments(contextTODO(), ids)
	for i := range out {
		out[i].CompletedBy = completed[out[i].ID]
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
			p.errLog("AssignmentByID", err)
		}
		return domain.Assignment{}, false
	}
	a.CompletedBy = p.completedForAssignment(contextTODO(), a.ID)
	return a, true
}

func (p *Postgres) SaveAssignment(a domain.Assignment) error {
	tx, err := p.db.BeginTx(contextTODO(), nil)
	if err != nil {
		p.errLog("SaveAssignment begin", err)
		return err
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
		p.errLog("SaveAssignment", err)
		return err
	}
	if _, err := tx.ExecContext(contextTODO(),
		`DELETE FROM assignment_completions WHERE assignment_id = $1`, a.ID); err != nil {
		p.errLog("SaveAssignment completions delete", err)
		return err
	}
	// Single statement for every completer (see the same pattern in SaveUser).
	if len(a.CompletedBy) > 0 {
		if _, err := tx.ExecContext(contextTODO(), `
			INSERT INTO assignment_completions (assignment_id, student_id)
			SELECT $1, sid FROM jsonb_array_elements_text($2::jsonb) AS sid
			ON CONFLICT DO NOTHING`,
			a.ID, toJSON(a.CompletedBy)); err != nil {
			p.errLog("SaveAssignment completion", err)
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		p.errLog("SaveAssignment commit", err)
		return err
	}

	return nil
}

// --- Fees & payments (client's fees module) ---

// Invoices returns every invoice with AmountPaid summed from the payments
// table in the same round trip, and Status resolved in Go from those two
// numbers and the due date. Neither is a column: a payment recorded on a
// second device would leave a stored copy wrong, and the whole point of this
// table is that two devices see one bill. Dates come back as ::text because
// the client writes 'yyyy-MM-dd' strings and reads them back the same way.
func (p *Postgres) Invoices() []domain.Invoice {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT i.id, i.student_id, i.issue_date::text, i.due_date::text,
		       i.term, COALESCE(i.line_items, '[]'::jsonb), COALESCE(p.paid, 0)
		FROM invoices i
		LEFT JOIN (SELECT invoice_id, SUM(amount) AS paid
		           FROM payments GROUP BY invoice_id) p
		  ON p.invoice_id = i.id
		ORDER BY i.issue_date, i.id`)
	if err != nil {
		p.errLog("Invoices", err)
		return nil
	}
	defer rows.Close()
	today := todayString()
	var out []domain.Invoice
	for rows.Next() {
		var inv domain.Invoice
		var items string
		if err := rows.Scan(&inv.ID, &inv.StudentID, &inv.IssueDate, &inv.DueDate,
			&inv.Term, &items, &inv.AmountPaid); err != nil {
			p.errLog("Invoices scan", err)
			continue
		}
		// An empty line_items is written as '{}'/'[]' — tolerate a NULL from
		// a hand-edited row rather than dropping the whole invoice.
		if items != "" {
			_ = json.Unmarshal([]byte(items), &inv.LineItems)
		}
		inv.Status = inv.ResolveStatus(today)
		out = append(out, inv)
	}
	return out
}

func (p *Postgres) InvoiceByID(id string) (domain.Invoice, bool) {
	for _, inv := range p.Invoices() {
		if inv.ID == id {
			return inv, true
		}
	}
	return domain.Invoice{}, false
}

// SaveInvoice upserts on the client-chosen id: invoice terms are corrected
// rather than re-minted, so a replayed POST of an unchanged invoice is a
// no-op and a genuinely edited one replaces the previous terms. The derived
// amountPaid/status the client may also send are ignored — they are recomputed
// on read, from payments this server has seen.
func (p *Postgres) SaveInvoice(inv domain.Invoice) error {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO invoices (id, student_id, issue_date, due_date, term, line_items)
		VALUES ($1,$2,$3,$4,$5,COALESCE($6::jsonb,'[]'::jsonb))
		ON CONFLICT (id) DO UPDATE SET
			student_id = EXCLUDED.student_id, issue_date = EXCLUDED.issue_date,
			due_date = EXCLUDED.due_date, term = EXCLUDED.term,
			line_items = EXCLUDED.line_items`,
		inv.ID, inv.StudentID, inv.IssueDate, inv.DueDate,
		nullStr(inv.Term), toJSON(inv.LineItems))
	if err != nil {
		p.errLog("SaveInvoice", err)
		return err
	}

	return nil
}

// SavePayment records one money movement. ON CONFLICT (id) DO NOTHING rather
// than DO UPDATE: the device firm-commits a payment locally and replays it
// through the outbox, so the same id arriving twice is one collection seen
// twice, not a correction of the first. Nothing is overwritten, and a replay
// that races the original writes nothing the second time.
func (p *Postgres) SavePayment(pay domain.Payment) error {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO payments (id, invoice_id, student_id, amount, method, reference, paid_at, recorded_by)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
		ON CONFLICT (id) DO NOTHING`,
		pay.ID, pay.InvoiceID, nullStr(pay.StudentID), pay.Amount, pay.Method,
		nullStr(pay.Reference), pay.PaidAt, pay.RecordedBy)
	if err != nil {
		p.errLog("SavePayment", err)
		return err
	}

	return nil
}

func (p *Postgres) Payments() []domain.Payment {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, invoice_id, COALESCE(student_id,''), amount, method,
		       reference, paid_at, recorded_by
		FROM payments ORDER BY paid_at, id`)
	if err != nil {
		p.errLog("Payments", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Payment
	for rows.Next() {
		var pay domain.Payment
		if err := rows.Scan(&pay.ID, &pay.InvoiceID, &pay.StudentID, &pay.Amount,
			&pay.Method, &pay.Reference, &pay.PaidAt, &pay.RecordedBy); err != nil {
			p.errLog("Payments scan", err)
			continue
		}
		out = append(out, pay)
	}
	return out
}

// --- Audit (doc §49) ---

func (p *Postgres) AuditLogs() []domain.AuditEntry {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id::text, action, actor, COALESCE(target,''), COALESCE(detail,''),
		       COALESCE(reason,''), timestamp
		FROM audit_logs ORDER BY id`)
	if err != nil {
		p.errLog("AuditLogs", err)
		return nil
	}
	defer rows.Close()
	var out []domain.AuditEntry
	for rows.Next() {
		var e domain.AuditEntry
		if err := rows.Scan(&e.ID, &e.Action, &e.Actor, &e.Target, &e.Detail, &e.Reason, &e.Timestamp); err != nil {
			p.errLog("AuditLogs scan", err)
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
		p.errLog("AddAudit", err)
	}
}

// --- Refresh-token sessions ---

func (p *Postgres) SaveRefreshToken(hash, userID string, expiresAt int64) error {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO refresh_tokens (hash, user_id, expires_at) VALUES ($1,$2,$3)
		ON CONFLICT (hash) DO UPDATE SET user_id = EXCLUDED.user_id, expires_at = EXCLUDED.expires_at`,
		hash, userID, expiresAt)
	if err != nil {
		p.errLog("SaveRefreshToken", err)
		return err
	}

	return nil
}

func (p *Postgres) RefreshTokenLookup(hash string) (string, int64, bool) {
	var userID string
	var expiresAt int64
	row := p.db.QueryRowContext(contextTODO(),
		`SELECT user_id, expires_at FROM refresh_tokens WHERE hash = $1`, hash)
	err := row.Scan(&userID, &expiresAt)
	if err != nil {
		if err != sql.ErrNoRows {
			p.errLog("RefreshTokenLookup", err)
		}
		return "", 0, false
	}
	return userID, expiresAt, true
}

func (p *Postgres) DeleteRefreshToken(hash string) error {
	_, err := p.db.ExecContext(contextTODO(), `DELETE FROM refresh_tokens WHERE hash = $1`, hash)
	if err != nil {
		p.errLog("DeleteRefreshToken", err)
		return err
	}

	return nil
}

func (p *Postgres) DeleteRefreshTokensForUser(userID string) error {
	_, err := p.db.ExecContext(contextTODO(), `DELETE FROM refresh_tokens WHERE user_id = $1`, userID)
	if err != nil {
		p.errLog("DeleteRefreshTokensForUser", err)
		return err
	}

	return nil
}

// --- Client records (see domain.Record) ---

func (p *Postgres) Records(kind string) []domain.Record {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, COALESCE(student_id,''), COALESCE(class_id,''), COALESCE(owner_id,''),
		       updated_at, data::text
		FROM client_records WHERE kind = $1 ORDER BY id`, kind)
	if err != nil {
		p.errLog("Records", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Record
	for rows.Next() {
		r := domain.Record{Kind: kind}
		var data string
		if err := rows.Scan(&r.ID, &r.StudentID, &r.ClassID, &r.OwnerID, &r.UpdatedAt, &data); err != nil {
			p.errLog("Records scan", err)
			continue
		}
		r.Data = json.RawMessage(data)
		out = append(out, r)
	}
	return out
}

func (p *Postgres) RecordByID(kind, id string) (domain.Record, bool) {
	r := domain.Record{Kind: kind, ID: id}
	var data string
	err := p.db.QueryRowContext(contextTODO(), `
		SELECT COALESCE(student_id,''), COALESCE(class_id,''), COALESCE(owner_id,''),
		       updated_at, data::text
		FROM client_records WHERE kind = $1 AND id = $2`, kind, id).
		Scan(&r.StudentID, &r.ClassID, &r.OwnerID, &r.UpdatedAt, &data)
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) {
			p.errLog("RecordByID", err)
		}
		return domain.Record{}, false
	}
	r.Data = json.RawMessage(data)
	return r, true
}

func (p *Postgres) SaveRecord(r domain.Record) error {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO client_records (kind, id, student_id, class_id, owner_id, updated_at, data)
		VALUES ($1,$2,$3,$4,$5,$6,$7::jsonb)
		ON CONFLICT (kind, id) DO UPDATE SET
			student_id = EXCLUDED.student_id, class_id = EXCLUDED.class_id,
			owner_id = EXCLUDED.owner_id, updated_at = EXCLUDED.updated_at, data = EXCLUDED.data`,
		r.Kind, r.ID, nullStr(r.StudentID), nullStr(r.ClassID), nullStr(r.OwnerID),
		r.UpdatedAt, string(r.Data))
	if err != nil {
		p.errLog("SaveRecord", err)
		return err
	}

	return nil
}

func (p *Postgres) DeleteRecord(kind, id string) error {
	tx, err := p.db.BeginTx(contextTODO(), nil)
	if err != nil {
		p.errLog("DeleteRecord begin", err)
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(contextTODO(),
		`DELETE FROM client_records WHERE kind = $1 AND id = $2`, kind, id); err != nil {
		p.errLog("DeleteRecord", err)
		return err
	}
	if kind == domain.RecordScans {
		if _, err := tx.ExecContext(contextTODO(), `DELETE FROM scan_images WHERE id = $1`, id); err != nil {
			p.errLog("DeleteRecord image", err)
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		p.errLog("DeleteRecord commit", err)
		return err
	}

	return nil
}

func (p *Postgres) SaveScanImage(id, contentType string, data []byte) error {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO scan_images (id, content_type, data) VALUES ($1,$2,$3)
		ON CONFLICT (id) DO UPDATE SET content_type = EXCLUDED.content_type, data = EXCLUDED.data`,
		id, contentType, data)
	if err != nil {
		p.errLog("SaveScanImage", err)
		return err
	}

	return nil
}

func (p *Postgres) ScanImage(id string) (string, []byte, bool) {
	var ct string
	var data []byte
	err := p.db.QueryRowContext(contextTODO(),
		`SELECT content_type, data FROM scan_images WHERE id = $1`, id).Scan(&ct, &data)
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) {
			p.errLog("ScanImage", err)
		}
		return "", nil, false
	}
	return ct, data, true
}

// =============================================================================
// Marking Schemes (Postgres implementation)
// =============================================================================

func (p *Postgres) MarkingSchemes() []domain.MarkingScheme {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, COALESCE(assessment_id,''), COALESCE(assignment_id,''),
		       version, COALESCE(parent_scheme_id,''), created_by, created_at
		FROM marking_schemes ORDER BY created_at DESC`)
	if err != nil {
		p.errLog("MarkingSchemes", err)
		return nil
	}
	defer rows.Close()
	var out []domain.MarkingScheme
	for rows.Next() {
		var ms domain.MarkingScheme
		if err := rows.Scan(&ms.ID, &ms.AssessmentID, &ms.AssignmentID, &ms.Version,
			&ms.ParentSchemeID, &ms.CreatedBy, &ms.CreatedAt); err != nil {
			p.errLog("MarkingSchemes scan", err)
			continue
		}
		out = append(out, ms)
	}
	return out
}

func (p *Postgres) MarkingSchemeByID(id string) (domain.MarkingScheme, bool) {
	var ms domain.MarkingScheme
	err := p.db.QueryRowContext(contextTODO(), `
		SELECT id, COALESCE(assessment_id,''), COALESCE(assignment_id,''),
		       version, COALESCE(parent_scheme_id,''), created_by, created_at
		FROM marking_schemes WHERE id = $1`, id).
		Scan(&ms.ID, &ms.AssessmentID, &ms.AssignmentID, &ms.Version,
			&ms.ParentSchemeID, &ms.CreatedBy, &ms.CreatedAt)
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) {
			p.errLog("MarkingSchemeByID", err)
		}
		return domain.MarkingScheme{}, false
	}
	return ms, true
}

func (p *Postgres) MarkingSchemesByAssessment(assessmentID string) []domain.MarkingScheme {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, COALESCE(assessment_id,''), COALESCE(assignment_id,''),
		       version, COALESCE(parent_scheme_id,''), created_by, created_at
		FROM marking_schemes WHERE assessment_id = $1 ORDER BY version DESC`, assessmentID)
	if err != nil {
		p.errLog("MarkingSchemesByAssessment", err)
		return nil
	}
	defer rows.Close()
	var out []domain.MarkingScheme
	for rows.Next() {
		var ms domain.MarkingScheme
		if err := rows.Scan(&ms.ID, &ms.AssessmentID, &ms.AssignmentID, &ms.Version,
			&ms.ParentSchemeID, &ms.CreatedBy, &ms.CreatedAt); err != nil {
			p.errLog("MarkingSchemesByAssessment scan", err)
			continue
		}
		out = append(out, ms)
	}
	return out
}

func (p *Postgres) MarkingSchemesByAssignment(assignmentID string) []domain.MarkingScheme {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, COALESCE(assessment_id,''), COALESCE(assignment_id,''),
		       version, COALESCE(parent_scheme_id,''), created_by, created_at
		FROM marking_schemes WHERE assignment_id = $1 ORDER BY version DESC`, assignmentID)
	if err != nil {
		p.errLog("MarkingSchemesByAssignment", err)
		return nil
	}
	defer rows.Close()
	var out []domain.MarkingScheme
	for rows.Next() {
		var ms domain.MarkingScheme
		if err := rows.Scan(&ms.ID, &ms.AssessmentID, &ms.AssignmentID, &ms.Version,
			&ms.ParentSchemeID, &ms.CreatedBy, &ms.CreatedAt); err != nil {
			p.errLog("MarkingSchemesByAssignment scan", err)
			continue
		}
		out = append(out, ms)
	}
	return out
}

func (p *Postgres) SaveMarkingScheme(ms domain.MarkingScheme) error {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO marking_schemes (id, assessment_id, assignment_id, version,
		                           parent_scheme_id, created_by, created_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7)
		ON CONFLICT (id) DO UPDATE SET
			assessment_id = EXCLUDED.assessment_id,
			assignment_id = EXCLUDED.assignment_id,
			version = EXCLUDED.version,
			parent_scheme_id = EXCLUDED.parent_scheme_id,
			created_by = EXCLUDED.created_by,
			created_at = EXCLUDED.created_at`,
		ms.ID, nullStr(ms.AssessmentID), nullStr(ms.AssignmentID),
		ms.Version, nullStr(ms.ParentSchemeID), ms.CreatedBy, ms.CreatedAt)
	if err != nil {
		p.errLog("SaveMarkingScheme", err)
		return err
	}
	return nil
}

func (p *Postgres) DeleteMarkingScheme(id string) error {
	_, err := p.db.ExecContext(contextTODO(), `DELETE FROM marking_schemes WHERE id = $1`, id)
	if err != nil {
		p.errLog("DeleteMarkingScheme", err)
		return err
	}
	return nil
}

func (p *Postgres) LatestSchemeVersion(assessmentID, assignmentID string) int {
	var version int
	var row *sql.Row
	if assessmentID != "" {
		row = p.db.QueryRowContext(contextTODO(),
			`SELECT COALESCE(MAX(version),0) FROM marking_schemes WHERE assessment_id = $1`, assessmentID)
	} else {
		row = p.db.QueryRowContext(contextTODO(),
			`SELECT COALESCE(MAX(version),0) FROM marking_schemes WHERE assignment_id = $1`, assignmentID)
	}
	err := row.Scan(&version)
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) {
			p.errLog("LatestSchemeVersion", err)
		}
		return 0
	}
	return version
}

func (p *Postgres) SubmissionsByScheme(schemeID string) []domain.Submission {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, assessment_id, student_id, class_id, date,
		       answers::text, teacher_marks::text, earned,
		       COALESCE(marking_scheme_id,''), COALESCE(marking_scheme_version,0)
		FROM submissions WHERE marking_scheme_id = $1`, schemeID)
	if err != nil {
		p.errLog("SubmissionsByScheme", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Submission
	for rows.Next() {
		var sub domain.Submission
		var answers, marks string
		if err := rows.Scan(&sub.ID, &sub.AssessmentID, &sub.StudentID, &sub.ClassID, &sub.Date,
			&answers, &marks, &sub.Earned, &sub.MarkingSchemeID, &sub.MarkingSchemeVersion); err != nil {
			p.errLog("SubmissionsByScheme scan", err)
			continue
		}
		_ = json.Unmarshal([]byte(answers), &sub.Answers)
		_ = json.Unmarshal([]byte(marks), &sub.TeacherMarks)
		out = append(out, sub)
	}
	return out
}

// =============================================================================
// Scheme Questions (Postgres implementation)
// =============================================================================

func (p *Postgres) SchemeQuestions(schemeID string) []domain.SchemeQuestion {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, scheme_id, question_number, total_marks,
		       mark_breakdown::text, created_at
		FROM scheme_questions WHERE scheme_id = $1 ORDER BY question_number`, schemeID)
	if err != nil {
		p.errLog("SchemeQuestions", err)
		return nil
	}
	defer rows.Close()
	var out []domain.SchemeQuestion
	for rows.Next() {
		var sq domain.SchemeQuestion
		var mb string
		if err := rows.Scan(&sq.ID, &sq.SchemeID, &sq.QuestionNumber, &sq.TotalMarks,
			&mb, &sq.CreatedAt); err != nil {
			p.errLog("SchemeQuestions scan", err)
			continue
		}
		// mark_breakdown is JSONB, unmarshal it
		if mb != "" {
			_ = json.Unmarshal([]byte(mb), &sq.MarkBreakdown)
		}
		// Load accepted answers and misconceptions for this question
		sq.AcceptedAnswers = p.AcceptedAnswers(sq.ID)
		sq.Misconceptions = p.Misconceptions(sq.ID)
		out = append(out, sq)
	}
	return out
}

func (p *Postgres) SchemeQuestionByID(id string) (domain.SchemeQuestion, bool) {
	var sq domain.SchemeQuestion
	var mb string
	err := p.db.QueryRowContext(contextTODO(), `
		SELECT id, scheme_id, question_number, total_marks,
		       mark_breakdown::text, created_at
		FROM scheme_questions WHERE id = $1`, id).
		Scan(&sq.ID, &sq.SchemeID, &sq.QuestionNumber, &sq.TotalMarks,
			&mb, &sq.CreatedAt)
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) {
			p.errLog("SchemeQuestionByID", err)
		}
		return domain.SchemeQuestion{}, false
	}
	if mb != "" {
		_ = json.Unmarshal([]byte(mb), &sq.MarkBreakdown)
	}
	sq.AcceptedAnswers = p.AcceptedAnswers(sq.ID)
	sq.Misconceptions = p.Misconceptions(sq.ID)
	return sq, true
}

func (p *Postgres) SaveSchemeQuestion(sq domain.SchemeQuestion) error {
	mb, _ := json.Marshal(sq.MarkBreakdown)
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO scheme_questions (id, scheme_id, question_number, total_marks,
		                            mark_breakdown, created_at)
		VALUES ($1,$2,$3,$4,$5,$6)
		ON CONFLICT (id) DO UPDATE SET
			scheme_id = EXCLUDED.scheme_id,
			question_number = EXCLUDED.question_number,
			total_marks = EXCLUDED.total_marks,
			mark_breakdown = EXCLUDED.mark_breakdown,
			created_at = EXCLUDED.created_at`,
		sq.ID, sq.SchemeID, sq.QuestionNumber, sq.TotalMarks,
		string(mb), sq.CreatedAt)
	if err != nil {
		p.errLog("SaveSchemeQuestion", err)
		return err
	}
	return nil
}

func (p *Postgres) DeleteSchemeQuestion(id string) error {
	_, err := p.db.ExecContext(contextTODO(), `DELETE FROM scheme_questions WHERE id = $1`, id)
	if err != nil {
		p.errLog("DeleteSchemeQuestion", err)
		return err
	}
	return nil
}

// =============================================================================
// Accepted Answers (Postgres implementation)
// =============================================================================

func (p *Postgres) AcceptedAnswers(schemeQuestionID string) []domain.AcceptedAnswer {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, scheme_question_id, answer_text, normalized_form,
		       marks_awarded, is_primary, created_at
		FROM scheme_accepted_answers WHERE scheme_question_id = $1
		ORDER BY is_primary DESC, id`, schemeQuestionID)
	if err != nil {
		p.errLog("AcceptedAnswers", err)
		return nil
	}
	defer rows.Close()
	var out []domain.AcceptedAnswer
	for rows.Next() {
		var aa domain.AcceptedAnswer
		if err := rows.Scan(&aa.ID, &aa.SchemeQuestionID, &aa.AnswerText,
			&aa.NormalizedForm, &aa.MarksAwarded, &aa.IsPrimary, &aa.CreatedAt); err != nil {
			p.errLog("AcceptedAnswers scan", err)
			continue
		}
		out = append(out, aa)
	}
	return out
}

func (p *Postgres) SaveAcceptedAnswer(aa domain.AcceptedAnswer) error {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO scheme_accepted_answers (id, scheme_question_id, answer_text,
		                                     normalized_form, marks_awarded, is_primary, created_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7)
		ON CONFLICT (id) DO UPDATE SET
			scheme_question_id = EXCLUDED.scheme_question_id,
			answer_text = EXCLUDED.answer_text,
			normalized_form = EXCLUDED.normalized_form,
			marks_awarded = EXCLUDED.marks_awarded,
			is_primary = EXCLUDED.is_primary,
			created_at = EXCLUDED.created_at`,
		aa.ID, aa.SchemeQuestionID, aa.AnswerText, aa.NormalizedForm,
		aa.MarksAwarded, aa.IsPrimary, aa.CreatedAt)
	if err != nil {
		p.errLog("SaveAcceptedAnswer", err)
		return err
	}
	return nil
}

func (p *Postgres) DeleteAcceptedAnswer(id int64) error {
	_, err := p.db.ExecContext(contextTODO(), `DELETE FROM scheme_accepted_answers WHERE id = $1`, id)
	if err != nil {
		p.errLog("DeleteAcceptedAnswer", err)
		return err
	}
	return nil
}

// =============================================================================
// Misconceptions (Postgres implementation)
// =============================================================================

func (p *Postgres) Misconceptions(schemeQuestionID string) []domain.Misconception {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, scheme_question_id, wrong_answer_pattern,
		       likely_cause, marks_awarded, created_at
		FROM scheme_misconceptions WHERE scheme_question_id = $1 ORDER BY id`, schemeQuestionID)
	if err != nil {
		p.errLog("Misconceptions", err)
		return nil
	}
	defer rows.Close()
	var out []domain.Misconception
	for rows.Next() {
		var msc domain.Misconception
		if err := rows.Scan(&msc.ID, &msc.SchemeQuestionID, &msc.WrongAnswerPattern,
			&msc.LikelyCause, &msc.MarksAwarded, &msc.CreatedAt); err != nil {
			p.errLog("Misconceptions scan", err)
			continue
		}
		out = append(out, msc)
	}
	return out
}

func (p *Postgres) SaveMisconception(msc domain.Misconception) error {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO scheme_misconceptions (id, scheme_question_id, wrong_answer_pattern,
		                                   likely_cause, marks_awarded, created_at)
		VALUES ($1,$2,$3,$4,$5,$6)
		ON CONFLICT (id) DO UPDATE SET
			scheme_question_id = EXCLUDED.scheme_question_id,
			wrong_answer_pattern = EXCLUDED.wrong_answer_pattern,
			likely_cause = EXCLUDED.likely_cause,
			marks_awarded = EXCLUDED.marks_awarded,
			created_at = EXCLUDED.created_at`,
		msc.ID, msc.SchemeQuestionID, msc.WrongAnswerPattern,
		msc.LikelyCause, msc.MarksAwarded, msc.CreatedAt)
	if err != nil {
		p.errLog("SaveMisconception", err)
		return err
	}
	return nil
}

func (p *Postgres) DeleteMisconception(id int64) error {
	_, err := p.db.ExecContext(contextTODO(), `DELETE FROM scheme_misconceptions WHERE id = $1`, id)
	if err != nil {
		p.errLog("DeleteMisconception", err)
		return err
	}
	return nil
}

// =============================================================================
// Scan Pages (Postgres implementation)
// =============================================================================

func (p *Postgres) ScanPages(submissionID string) []domain.ScanPage {
	rows, err := p.db.QueryContext(contextTODO(), `
		SELECT id, submission_id, COALESCE(scheme_id,''), page_number,
		       COALESCE(image_id,''), COALESCE(ocr_text,''), COALESCE(ocr_confidence,0),
		       ocr_status, COALESCE(ocr_metadata::text,'{}'), created_at
		FROM scan_pages WHERE submission_id = $1 ORDER BY page_number`, submissionID)
	if err != nil {
		p.errLog("ScanPages", err)
		return nil
	}
	defer rows.Close()
	var out []domain.ScanPage
	for rows.Next() {
		var sp domain.ScanPage
		if err := rows.Scan(&sp.ID, &sp.SubmissionID, &sp.SchemeID, &sp.PageNumber,
			&sp.ImageID, &sp.OCRText, &sp.OCRConfidence, &sp.OCRStatus,
			&sp.OCRMetadata, &sp.CreatedAt); err != nil {
			p.errLog("ScanPages scan", err)
			continue
		}
		out = append(out, sp)
	}
	return out
}

func (p *Postgres) ScanPageByID(id string) (domain.ScanPage, bool) {
	var sp domain.ScanPage
	err := p.db.QueryRowContext(contextTODO(), `
		SELECT id, submission_id, COALESCE(scheme_id,''), page_number,
		       COALESCE(image_id,''), COALESCE(ocr_text,''), COALESCE(ocr_confidence,0),
		       ocr_status, COALESCE(ocr_metadata::text,'{}'), created_at
		FROM scan_pages WHERE id = $1`, id).
		Scan(&sp.ID, &sp.SubmissionID, &sp.SchemeID, &sp.PageNumber,
			&sp.ImageID, &sp.OCRText, &sp.OCRConfidence, &sp.OCRStatus,
			&sp.OCRMetadata, &sp.CreatedAt)
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) {
			p.errLog("ScanPageByID", err)
		}
		return domain.ScanPage{}, false
	}
	return sp, true
}

func (p *Postgres) SaveScanPage(sp domain.ScanPage) error {
	_, err := p.db.ExecContext(contextTODO(), `
		INSERT INTO scan_pages (id, submission_id, scheme_id, page_number,
		                        image_id, ocr_text, ocr_confidence, ocr_status,
		                        ocr_metadata, created_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
		ON CONFLICT (id) DO UPDATE SET
			submission_id = EXCLUDED.submission_id,
			scheme_id = EXCLUDED.scheme_id,
			page_number = EXCLUDED.page_number,
			image_id = EXCLUDED.image_id,
			ocr_text = EXCLUDED.ocr_text,
			ocr_confidence = EXCLUDED.ocr_confidence,
			ocr_status = EXCLUDED.ocr_status,
			ocr_metadata = EXCLUDED.ocr_metadata,
			created_at = EXCLUDED.created_at`,
		sp.ID, sp.SubmissionID, nullStr(sp.SchemeID), sp.PageNumber,
		nullStr(sp.ImageID), sp.OCRText, sp.OCRConfidence, sp.OCRStatus,
		nullStr(sp.OCRMetadata), sp.CreatedAt)
	if err != nil {
		p.errLog("SaveScanPage", err)
		return err
	}
	return nil
}

func (p *Postgres) DeleteScanPage(id string) error {
	_, err := p.db.ExecContext(contextTODO(), `DELETE FROM scan_pages WHERE id = $1`, id)
	if err != nil {
		p.errLog("DeleteScanPage", err)
		return err
	}
	return nil
}
