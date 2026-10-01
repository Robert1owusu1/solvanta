// Command _createdb creates the dedicated database the Postgres integration
// tests run against, so the `TRUNCATE ... CASCADE` those tests perform can
// never reach development data. Idempotent: it reports and exits if the
// database is already there.
//
// It lives outside the normal build — the directory name starts with "_",
// which the go tool ignores for `./...` patterns — so `go build ./...`,
// `go vet ./...` and `go test ./...` never pick it up.
//
// Usage (POSTGRES_DSN comes from .env):
//     run-dev.cmd -Check          &rem confirms the env is parsed
//     go run ./cmd/_createdb      &rem creates solvanta_test if missing
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/jackc/pgx/v5"
)

const name = "solvanta_test"

func main() {
	dsn := os.Getenv("POSTGRES_DSN")
	if dsn == "" {
		fmt.Fprintln(os.Stderr, "POSTGRES_DSN is not set")
		os.Exit(2)
	}
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close(ctx)

	var exists bool
	if err := conn.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)`, name,
	).Scan(&exists); err != nil {
		fmt.Fprintf(os.Stderr, "lookup: %v\n", err)
		os.Exit(1)
	}
	if exists {
		fmt.Printf("database %q already exists\n", name)
		return
	}

	// Simple-query protocol via PgConn: CREATE DATABASE must not run inside a
	// transaction block, and a bare Exec() would be free to open one.
	if _, err := conn.PgConn().Exec(ctx, "CREATE DATABASE " + name).ReadAll(); err != nil {
		fmt.Fprintf(os.Stderr, "create %q: %v\n", name, err)
		os.Exit(1)
	}
	fmt.Printf("created database %q\n", name)
}
