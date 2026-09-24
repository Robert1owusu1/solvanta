// Package migrations embeds the SQL schema so the API server can apply it at
// boot without depending on a live file path.
package migrations

import _ "embed"

//go:embed 001_init.sql
var SQL string
