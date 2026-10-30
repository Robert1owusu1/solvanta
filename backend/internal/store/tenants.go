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

	"solvanta/backend/internal/domain"
)

// Tenants gives every school a Store of its own. Nothing is shared between
// schools: a handler that forgets a school filter still cannot reach another
// school's rows, because they are not in the store it was handed.
//
// Platform accounts (the super admin, whose SchoolID is empty) live in the
// default school's store, so For("") is the default school.
type Tenants interface {
	// For returns a registered school's store, or ErrUnknownSchool.
	For(schoolID string) (Store, error)
	// Create registers a new, empty school and returns its store.
	Create(schoolID string) (Store, error)
	// Schools lists the registered school IDs, sorted.
	Schools() []string
}

// ErrUnknownSchool is returned for a school the platform has not registered.
var ErrUnknownSchool = errors.New("unknown school")

// ErrSchoolExists is returned when creating a school that already exists.
var ErrSchoolExists = errors.New("school already exists")

var schoolIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,40}$`)

// ValidSchoolID reports whether id can name a school (and its schema).
func ValidSchoolID(id string) bool { return schoolIDPattern.MatchString(id) }

func tenantKey(schoolID string) string {
	if schoolID == "" {
		return domain.DefaultSchoolID()
	}
	return schoolID
}

// --- In memory ---------------------------------------------------------------

// MemoryTenants keeps one Memory store per school.
type MemoryTenants struct {
	mu      sync.RWMutex
	schools map[string]*Memory
}

// NewMemoryTenants registers def as the default school's store.
func NewMemoryTenants(def *Memory) *MemoryTenants {
	return &MemoryTenants{schools: map[string]*Memory{domain.DefaultSchoolID(): def}}
}

func (t *MemoryTenants) For(schoolID string) (Store, error) {
	t.mu.RLock()
	defer t.mu.RUnlock()
	if m, ok := t.schools[tenantKey(schoolID)]; ok {
		return m, nil
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
	defer t.mu.Unlock()
	if _, ok := t.schools[schoolID]; ok {
		return nil, ErrSchoolExists
	}
	m := NewUnseeded()
	t.schools[schoolID] = m
	return m, nil
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

// --- PostgreSQL --------------------------------------------------------------

// PostgresTenants gives each school its own PostgreSQL schema (school_<id>),
// with its own migrations and connection pool. The registry of schools is
// the tenants table in the public schema.
type PostgresTenants struct {
	dsn      string
	registry *sql.DB

	mu    sync.Mutex
	open  map[string]*Postgres
	known map[string]bool
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
	if _, err := reg.Exec(`CREATE TABLE IF NOT EXISTS public.tenants (
		school_id   TEXT PRIMARY KEY,
		created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
	)`); err != nil {
		reg.Close()
		return nil, fmt.Errorf("tenants table: %w", err)
	}
	t := &PostgresTenants{dsn: dsn, registry: reg, open: map[string]*Postgres{}, known: map[string]bool{}}
	rows, err := reg.Query(`SELECT school_id FROM public.tenants`)
	if err != nil {
		reg.Close()
		return nil, err
	}
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			t.known[id] = true
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
	return t, nil
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
	if pg, ok := t.open[key]; ok {
		return pg, nil
	}
	if !t.known[key] {
		return nil, ErrUnknownSchool
	}
	return t.connect(key, false)
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
	return pg, nil
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

// Close releases every school's pool and the registry.
func (t *PostgresTenants) Close() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, pg := range t.open {
		pg.Close()
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
