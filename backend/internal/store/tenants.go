package store

import (
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"solvanta/backend/internal/domain"
)

// Tenants gives every school a Store of its own. Nothing is shared between
// schools: a handler that forgets a school filter still cannot reach another
// school's rows, because they are not in the store it was handed.
//
// Platform accounts (the super admin, whose SchoolID is empty) live in the
// default school's store, so For("") is the default school.
//
// One thing is platform-wide: the directory of sign-in emails. Every store
// handed out claims an account's email there before saving it, so an email
// belongs to exactly one account in one school, and sign-in goes straight to
// that school.
type Tenants interface {
	// For returns a registered school's store, or ErrUnknownSchool.
	For(schoolID string) (Store, error)
	// Create registers a new, empty school and returns its store.
	Create(schoolID string) (Store, error)
	// Schools lists the registered school IDs, sorted.
	Schools() []string
	// SchoolForEmail is the school holding the account with this sign-in
	// email (lower case).
	SchoolForEmail(email string) (string, bool)
	// Suspended reports whether a school's access is suspended.
	Suspended(schoolID string) bool
	SetSuspended(schoolID string, suspended bool) error
	// Delete removes a school and everything in it. The default school
	// cannot be deleted.
	Delete(schoolID string) error
}

// ErrUnknownSchool is returned for a school the platform has not registered.
var ErrUnknownSchool = errors.New("unknown school")

// ErrSchoolExists is returned when creating a school that already exists.
var ErrSchoolExists = errors.New("school already exists")

// ErrEmailTaken is returned when saving an account whose email another
// account (in any school) already signs in with.
var ErrEmailTaken = errors.New("email already in use")

// ErrDefaultSchool is returned when deleting the default school.
var ErrDefaultSchool = errors.New("the default school cannot be deleted")

var schoolIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,40}$`)

// ValidSchoolID reports whether id can name a school (and its schema).
func ValidSchoolID(id string) bool { return schoolIDPattern.MatchString(id) }

func tenantKey(schoolID string) string {
	if schoolID == "" {
		return domain.DefaultSchoolID()
	}
	return schoolID
}

// schoolStore is a school's Store that claims each account's email in the
// platform directory before saving the account.
type schoolStore struct {
	Store
	school string
	claim  func(email, school, userID string) error
}

func (s schoolStore) SaveUser(u domain.User) error {
	if email := strings.ToLower(strings.TrimSpace(u.Email)); email != "" {
		if err := s.claim(email, s.school, u.ID); err != nil {
			return err
		}
	}
	return s.Store.SaveUser(u)
}

// Unwrap returns the store underneath (for health checks).
func (s schoolStore) Unwrap() Store { return s.Store }

// Unwrap returns the concrete store under a school's store.
func Unwrap(st Store) Store {
	if w, ok := st.(interface{ Unwrap() Store }); ok {
		return w.Unwrap()
	}
	return st
}

// --- In memory ---------------------------------------------------------------

type dirEntry struct{ school, user string }

// MemoryTenants keeps one Memory store per school.
type MemoryTenants struct {
	mu        sync.RWMutex
	schools   map[string]*Memory
	dir       map[string]dirEntry
	suspended map[string]bool
}

// NewMemoryTenants registers def as the default school's store.
func NewMemoryTenants(def *Memory) *MemoryTenants {
	t := &MemoryTenants{
		schools:   map[string]*Memory{domain.DefaultSchoolID(): def},
		dir:       map[string]dirEntry{},
		suspended: map[string]bool{},
	}
	for _, u := range def.Users() {
		if e := strings.ToLower(strings.TrimSpace(u.Email)); e != "" {
			t.dir[e] = dirEntry{domain.DefaultSchoolID(), u.ID}
		}
	}
	return t
}

func (t *MemoryTenants) claim(email, school, userID string) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if e, ok := t.dir[email]; ok && e != (dirEntry{school, userID}) {
		return ErrEmailTaken
	}
	t.dir[email] = dirEntry{school, userID}
	return nil
}

func (t *MemoryTenants) For(schoolID string) (Store, error) {
	key := tenantKey(schoolID)
	t.mu.RLock()
	defer t.mu.RUnlock()
	if m, ok := t.schools[key]; ok {
		return schoolStore{m, key, t.claim}, nil
	}
	return nil, ErrUnknownSchool
}

// Memory returns a school's store as *Memory, for tests that seed it.
func (t *MemoryTenants) Memory(schoolID string) *Memory {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.schools[tenantKey(schoolID)]
}

func (t *MemoryTenants) Create(schoolID string) (Store, error) {
	if !ValidSchoolID(schoolID) {
		return nil, fmt.Errorf("invalid school id %q", schoolID)
	}
	t.mu.Lock()
	if _, ok := t.schools[schoolID]; ok {
		t.mu.Unlock()
		return nil, ErrSchoolExists
	}
	t.schools[schoolID] = NewUnseeded()
	t.mu.Unlock()
	return t.For(schoolID)
}

func (t *MemoryTenants) Schools() []string {
	t.mu.RLock()
	defer t.mu.RUnlock()
	out := make([]string, 0, len(t.schools))
	for id := range t.schools {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

func (t *MemoryTenants) SchoolForEmail(email string) (string, bool) {
	t.mu.RLock()
	defer t.mu.RUnlock()
	e, ok := t.dir[strings.ToLower(strings.TrimSpace(email))]
	return e.school, ok
}

func (t *MemoryTenants) Suspended(schoolID string) bool {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.suspended[tenantKey(schoolID)]
}

func (t *MemoryTenants) SetSuspended(schoolID string, v bool) error {
	key := tenantKey(schoolID)
	t.mu.Lock()
	defer t.mu.Unlock()
	if _, ok := t.schools[key]; !ok {
		return ErrUnknownSchool
	}
	t.suspended[key] = v
	return nil
}

func (t *MemoryTenants) Delete(schoolID string) error {
	key := tenantKey(schoolID)
	if key == domain.DefaultSchoolID() {
		return ErrDefaultSchool
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if _, ok := t.schools[key]; !ok {
		return ErrUnknownSchool
	}
	delete(t.schools, key)
	delete(t.suspended, key)
	for email, e := range t.dir {
		if e.school == key {
			delete(t.dir, email)
		}
	}
	return nil
}

// --- PostgreSQL --------------------------------------------------------------

// PostgresTenants gives each school its own PostgreSQL schema (school_<id>),
// with its own migrations and a small connection pool, opened on first use
// and closed again after IdleAfter without requests — so connections track
// the schools in use, not the schools registered. The registry
// (public.tenants) and the email directory (public.user_directory) are
// shared.
type PostgresTenants struct {
	dsn      string
	registry *sql.DB

	// IdleAfter closes a school's pool after this long unused.
	IdleAfter time.Duration

	mu        sync.Mutex
	open      map[string]*Postgres
	lastUsed  map[string]time.Time
	known     map[string]bool
	suspended map[string]bool
	stop      chan struct{}
}

// NewPostgresTenants connects, makes sure the default school exists (seeding
// it with the demo data when seed is true) and returns the registry.
func NewPostgresTenants(dsn string, seed bool) (*PostgresTenants, error) {
	reg, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, err
	}
	reg.SetMaxOpenConns(2)
	if err := reg.Ping(); err != nil {
		reg.Close()
		return nil, err
	}
	for _, q := range []string{
		`CREATE TABLE IF NOT EXISTS public.tenants (
			school_id   TEXT PRIMARY KEY,
			created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
		)`,
		`ALTER TABLE public.tenants ADD COLUMN IF NOT EXISTS suspended BOOLEAN NOT NULL DEFAULT false`,
		`CREATE TABLE IF NOT EXISTS public.user_directory (
			email      TEXT PRIMARY KEY,
			school_id  TEXT NOT NULL,
			user_id    TEXT NOT NULL
		)`,
	} {
		if _, err := reg.Exec(q); err != nil {
			reg.Close()
			return nil, fmt.Errorf("registry: %w", err)
		}
	}
	t := &PostgresTenants{
		dsn: dsn, registry: reg, IdleAfter: 10 * time.Minute,
		open: map[string]*Postgres{}, lastUsed: map[string]time.Time{},
		known: map[string]bool{}, suspended: map[string]bool{},
		stop: make(chan struct{}),
	}
	rows, err := reg.Query(`SELECT school_id, suspended FROM public.tenants`)
	if err != nil {
		reg.Close()
		return nil, err
	}
	for rows.Next() {
		var id string
		var susp bool
		if rows.Scan(&id, &susp) == nil {
			t.known[id] = true
			t.suspended[id] = susp
		}
	}
	rows.Close()
	def := domain.DefaultSchoolID()
	if !t.known[def] {
		if _, err := t.create(def, seed); err != nil {
			reg.Close()
			return nil, fmt.Errorf("default school: %w", err)
		}
	} else if seed {
		pg, err := t.For(def)
		if err != nil {
			return nil, err
		}
		Seed(pg)
	}
	if err := t.backfillDirectory(); err != nil {
		reg.Close()
		return nil, err
	}
	go t.closeIdle()
	return t, nil
}

// backfillDirectory fills an empty email directory from every school's
// accounts — a database written before the directory existed (or seeded
// below the directory).
func (t *PostgresTenants) backfillDirectory() error {
	for _, id := range t.Schools() {
		st, err := t.For(id)
		if err != nil {
			return err
		}
		for _, u := range st.Users() {
			email := strings.ToLower(strings.TrimSpace(u.Email))
			if email == "" {
				continue
			}
			if _, err := t.registry.Exec(`INSERT INTO public.user_directory (email, school_id, user_id)
				VALUES ($1, $2, $3) ON CONFLICT (email) DO NOTHING`, email, id, u.ID); err != nil {
				return fmt.Errorf("directory: %w", err)
			}
		}
	}
	return nil
}

func (t *PostgresTenants) claim(email, school, userID string) error {
	res, err := t.registry.Exec(`
		INSERT INTO public.user_directory (email, school_id, user_id) VALUES ($1, $2, $3)
		ON CONFLICT (email) DO UPDATE SET school_id = EXCLUDED.school_id
		WHERE user_directory.school_id = EXCLUDED.school_id
		  AND user_directory.user_id = EXCLUDED.user_id`, email, school, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrEmailTaken
	}
	return nil
}

// schemaFor is the schema holding a school's tables.
func schemaFor(schoolID string) string {
	return "school_" + strings.ToLower(strings.ReplaceAll(schoolID, "-", "_"))
}

// withSearchPath points a DSN's connections at schema.
func withSearchPath(dsn, schema string) (string, error) {
	if strings.HasPrefix(dsn, "postgres://") || strings.HasPrefix(dsn, "postgresql://") {
		u, err := url.Parse(dsn)
		if err != nil {
			return "", err
		}
		q := u.Query()
		q.Set("search_path", schema)
		u.RawQuery = q.Encode()
		return u.String(), nil
	}
	return dsn + " search_path=" + schema, nil
}

func (t *PostgresTenants) For(schoolID string) (Store, error) {
	key := tenantKey(schoolID)
	t.mu.Lock()
	defer t.mu.Unlock()
	if !t.known[key] {
		return nil, ErrUnknownSchool
	}
	pg, ok := t.open[key]
	if !ok {
		var err error
		if pg, err = t.connect(key, false); err != nil {
			return nil, err
		}
	}
	t.lastUsed[key] = time.Now()
	return schoolStore{pg, key, t.claim}, nil
}

// closeIdle closes the pools of schools nobody has used for IdleAfter, so
// a platform of many schools holds connections only for the active ones.
// A closed school reopens on its next request.
func (t *PostgresTenants) closeIdle() {
	tick := time.NewTicker(time.Minute)
	defer tick.Stop()
	for {
		select {
		case <-t.stop:
			return
		case <-tick.C:
			t.CloseIdle(time.Now())
		}
	}
}

// CloseIdle closes every pool unused since before now - IdleAfter.
func (t *PostgresTenants) CloseIdle(now time.Time) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	closed := 0
	for id, pg := range t.open {
		if now.Sub(t.lastUsed[id]) >= t.IdleAfter {
			pg.Close()
			delete(t.open, id)
			closed++
		}
	}
	return closed
}

// OpenPools is how many schools hold a connection pool now.
func (t *PostgresTenants) OpenPools() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.open)
}

// connect opens a school's schema; t.mu must be held.
func (t *PostgresTenants) connect(schoolID string, seed bool) (*Postgres, error) {
	dsn, err := withSearchPath(t.dsn, schemaFor(schoolID))
	if err != nil {
		return nil, err
	}
	pg, err := NewPostgres(dsn, seed)
	if err != nil {
		return nil, fmt.Errorf("school %s: %w", schoolID, err)
	}
	// Many schools share one server's connection limit: keep each pool small.
	pg.db.SetMaxOpenConns(4)
	pg.db.SetMaxIdleConns(2)
	t.open[schoolID] = pg
	return pg, nil
}

func (t *PostgresTenants) Create(schoolID string) (Store, error) {
	return t.create(schoolID, false)
}

func (t *PostgresTenants) create(schoolID string, seed bool) (Store, error) {
	if !ValidSchoolID(schoolID) {
		return nil, fmt.Errorf("invalid school id %q", schoolID)
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.known[schoolID] {
		return nil, ErrSchoolExists
	}
	// The schema name is built only from a validated id, never raw input.
	if _, err := t.registry.Exec(`CREATE SCHEMA IF NOT EXISTS ` + schemaFor(schoolID)); err != nil {
		return nil, err
	}
	pg, err := t.connect(schoolID, seed)
	if err != nil {
		return nil, err
	}
	if _, err := t.registry.Exec(
		`INSERT INTO public.tenants (school_id) VALUES ($1) ON CONFLICT DO NOTHING`, schoolID); err != nil {
		return nil, err
	}
	t.known[schoolID] = true
	t.lastUsed[schoolID] = time.Now()
	return schoolStore{pg, schoolID, t.claim}, nil
}

func (t *PostgresTenants) Schools() []string {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make([]string, 0, len(t.known))
	for id := range t.known {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

func (t *PostgresTenants) SchoolForEmail(email string) (string, bool) {
	var id string
	err := t.registry.QueryRow(`SELECT school_id FROM public.user_directory WHERE email = $1`,
		strings.ToLower(strings.TrimSpace(email))).Scan(&id)
	return id, err == nil
}

func (t *PostgresTenants) Suspended(schoolID string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.suspended[tenantKey(schoolID)]
}

func (t *PostgresTenants) SetSuspended(schoolID string, v bool) error {
	key := tenantKey(schoolID)
	t.mu.Lock()
	defer t.mu.Unlock()
	if !t.known[key] {
		return ErrUnknownSchool
	}
	if _, err := t.registry.Exec(`UPDATE public.tenants SET suspended = $2 WHERE school_id = $1`, key, v); err != nil {
		return err
	}
	t.suspended[key] = v
	return nil
}

func (t *PostgresTenants) Delete(schoolID string) error {
	key := tenantKey(schoolID)
	if key == domain.DefaultSchoolID() {
		return ErrDefaultSchool
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if !t.known[key] {
		return ErrUnknownSchool
	}
	if pg, ok := t.open[key]; ok {
		pg.Close()
		delete(t.open, key)
	}
	tx, err := t.registry.Begin()
	if err != nil {
		return err
	}
	for _, q := range []string{
		// The schema name is built only from a validated, registered id.
		`DROP SCHEMA IF EXISTS ` + schemaFor(key) + ` CASCADE`,
		`DELETE FROM public.user_directory WHERE school_id = $1`,
		`DELETE FROM public.tenants WHERE school_id = $1`,
	} {
		var err error
		if strings.Contains(q, "$1") {
			_, err = tx.Exec(q, key)
		} else {
			_, err = tx.Exec(q)
		}
		if err != nil {
			tx.Rollback()
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	delete(t.known, key)
	delete(t.suspended, key)
	delete(t.lastUsed, key)
	return nil
}

// Close releases every school's pool and the registry.
func (t *PostgresTenants) Close() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	select {
	case <-t.stop:
	default:
		close(t.stop)
	}
	for id, pg := range t.open {
		pg.Close()
		delete(t.open, id)
	}
	return t.registry.Close()
}

// --- One store -----------------------------------------------------------------

type singleSchool struct{ st Store }

// SingleSchool serves one existing store as the default school — for tests
// and tools built around a single store. It cannot create schools.
func SingleSchool(st Store) Tenants {
	if m, ok := st.(*Memory); ok {
		return NewMemoryTenants(m)
	}
	return singleSchool{st}
}

func (t singleSchool) For(schoolID string) (Store, error) {
	if tenantKey(schoolID) == domain.DefaultSchoolID() {
		return t.st, nil
	}
	return nil, ErrUnknownSchool
}

func (t singleSchool) Create(string) (Store, error) {
	return nil, errors.New("this server holds a single school")
}

func (t singleSchool) Schools() []string { return []string{domain.DefaultSchoolID()} }

func (t singleSchool) SchoolForEmail(email string) (string, bool) {
	_, ok := t.st.UserByEmail(strings.ToLower(strings.TrimSpace(email)))
	return domain.DefaultSchoolID(), ok
}

func (t singleSchool) Suspended(string) bool { return false }

func (t singleSchool) SetSuspended(string, bool) error {
	return errors.New("this server holds a single school")
}

func (t singleSchool) Delete(string) error { return ErrDefaultSchool }
