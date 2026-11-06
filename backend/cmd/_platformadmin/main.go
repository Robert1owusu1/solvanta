// Command _platformadmin is a one-off operational tool: it clears all tenant
// data from the configured database and (re)creates a single super-admin
// account. The leading underscore keeps it out of `go build ./...`, `go vet`
// and `go test`, so it never ships with the server.
//
// Usage (POSTGRES_DSN from the environment / backend/.env):
//
//	POSTGRES_DSN=... SUPERADMIN_EMAIL=you@example.com SUPERADMIN_PASSWORD=... \
//	  go run ./cmd/_platformadmin
//
// It is destructive: every school/workspace schema (school_*) is dropped and
// the registry tables are cleared. Only run it against a database you intend
// to wipe.
package main

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/store"
)

func main() {
	dsn := os.Getenv("POSTGRES_DSN")
	email := strings.ToLower(strings.TrimSpace(os.Getenv("SUPERADMIN_EMAIL")))
	pass := os.Getenv("SUPERADMIN_PASSWORD")
	if dsn == "" || email == "" || pass == "" {
		fmt.Fprintln(os.Stderr, "need POSTGRES_DSN, SUPERADMIN_EMAIL and SUPERADMIN_PASSWORD")
		os.Exit(2)
	}
	ctx := context.Background()

	// --- 1. Reset: drop every tenant schema and clear the registry. ---------
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		fmt.Fprintln(os.Stderr, "connect:", err)
		os.Exit(1)
	}
	rows, err := conn.Query(ctx,
		`SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'school\_%'`)
	if err != nil {
		fmt.Fprintln(os.Stderr, "list schemas:", err)
		os.Exit(1)
	}
	var schemas []string
	for rows.Next() {
		var s string
		if rows.Scan(&s) == nil {
			schemas = append(schemas, s)
		}
	}
	rows.Close()
	for _, s := range schemas {
		if _, err := conn.Exec(ctx, fmt.Sprintf(`DROP SCHEMA IF EXISTS %q CASCADE`, s)); err != nil {
			fmt.Fprintln(os.Stderr, "drop", s, ":", err)
			os.Exit(1)
		}
		fmt.Println("dropped tenant schema:", s)
	}
	// Clear the registry (ignore errors if the tables do not exist yet).
	for _, q := range []string{
		`TRUNCATE public.user_directory`,
		`TRUNCATE public.tenants`,
	} {
		if _, err := conn.Exec(ctx, q); err != nil {
			fmt.Println("note:", q, "->", err)
		}
	}
	conn.Close(ctx)
	fmt.Println("registry cleared; all test users removed.")

	// --- 2. Recreate the default tenant (empty) and the super admin. --------
	tenants, err := store.NewPostgresTenants(dsn, false)
	if err != nil {
		fmt.Fprintln(os.Stderr, "open tenants:", err)
		os.Exit(1)
	}
	defer tenants.Close()

	def := domain.DefaultSchoolID()
	st, err := tenants.For(def)
	if err != nil {
		fmt.Fprintln(os.Stderr, "default tenant:", err)
		os.Exit(1)
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(pass), bcrypt.DefaultCost)
	if err != nil {
		fmt.Fprintln(os.Stderr, "hash:", err)
		os.Exit(1)
	}
	// Saving through the tenant store also registers the email in the
	// public.user_directory, so login can resolve it.
	admin := domain.User{
		ID:       "USR-SUPER",
		Name:     "Solvanta Super Admin",
		Email:    email,
		Phone:    "0240000000",
		Password: string(hash),
		Role:     domain.RoleSuperAdmin,
	}
	if err := st.SaveUser(admin); err != nil {
		fmt.Fprintln(os.Stderr, "save super admin:", err)
		os.Exit(1)
	}
	fmt.Println("created super admin:", email, "(role:", admin.Role+")")
	fmt.Println("done.")
}
