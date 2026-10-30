// Package migrations embeds the SQL schema so the API server can apply it at
// boot without depending on a live file path.
package migrations

import (
	"embed"
	"io/fs"
	"sort"
)

// Every *.sql file in this directory, applied in filename order. Each file
// runs once per database schema and is recorded in schema_migrations (see
// store.applyMigrations), so a new numbered file is all a schema change needs.
// The files written before that table existed are idempotent (IF NOT EXISTS),
// so recording them on a database that already has their tables is safe.
//
//go:embed *.sql
var files embed.FS

// File is one migration: its file name (the version) and its SQL.
type File struct {
	Name string
	SQL  string
}

// Files lists every migration in filename order.
func Files() []File {
	names, err := fs.Glob(files, "*.sql")
	if err != nil {
		panic("migrations: " + err.Error())
	}
	sort.Strings(names)
	out := make([]File, 0, len(names))
	for _, n := range names {
		data, err := files.ReadFile(n)
		if err != nil {
			panic("migrations: " + err.Error())
		}
		out = append(out, File{Name: n, SQL: string(data)})
	}
	return out
}
