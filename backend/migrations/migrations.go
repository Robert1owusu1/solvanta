// Package migrations embeds the SQL schema so the API server can apply it at
// boot without depending on a live file path.
package migrations

import (
	"embed"
	"io/fs"
	"sort"
	"strings"
)

// Every *.sql file in this directory. They are concatenated in filename order
// and executed as one batch at boot, so adding a numbered file is all a schema
// change needs — there is no version table, and a live database is re-run
// against the whole script on every start. Each statement must therefore be
// idempotent (IF NOT EXISTS), which is how the schema has always been written.
//
//go:embed *.sql
var files embed.FS

// SQL is every migration in this package, in filename order.
var SQL = concat()

func concat() string {
	names, err := fs.Glob(files, "*.sql")
	if err != nil {
		panic("migrations: " + err.Error())
	}
	sort.Strings(names)
	var b strings.Builder
	for _, n := range names {
		data, err := files.ReadFile(n)
		if err != nil {
			panic("migrations: " + err.Error())
		}
		b.Write(data)
		b.WriteByte('\n')
	}
	return b.String()
}
