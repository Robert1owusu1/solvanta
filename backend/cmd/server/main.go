// Command server runs the SOLVANTA backend API. Configuration is read from
// environment ("PORT", "ADDR", "SECRET", "ALLOWED_ORIGINS", "ENV",
// "POSTGRES_DSN", "SEED"). Storage defaults to the in-memory development store
// (seeded together with the client app); setting POSTGRES_DSN switches to the
// PostgreSQL-backed store (schema applied at boot).
package main

import (
	"log"
	"os"
	"strings"

	"solvanta/backend/internal/httpapi"
	"solvanta/backend/internal/store"
)

func main() {
	addr := os.Getenv("ADDR")
	if addr == "" {
		addr = ":" + firstNonEmpty(os.Getenv("PORT"), "8080")
	}
	cfg := httpapi.Config{
		Secret:     os.Getenv("SECRET"),
		Production: os.Getenv("ENV") == "production",
	}
	if origins := os.Getenv("ALLOWED_ORIGINS"); origins != "" {
		for _, o := range strings.Split(origins, ",") {
			if o = strings.TrimSpace(o); o != "" {
				cfg.AllowedOrigins = append(cfg.AllowedOrigins, o)
			}
		}
	}

	var st store.Store
	if dsn := os.Getenv("POSTGRES_DSN"); dsn != "" {
		log.Println("using PostgreSQL store")
		pg, err := store.NewPostgres(dsn, os.Getenv("SEED") != "false")
		if err != nil {
			log.Fatalf("postgres: %v", err)
		}
		defer pg.Close()
		st = pg
	} else {
		log.Println("using in-memory store (set POSTGRES_DSN for persistence)")
		st = store.New()
	}

	server, err := httpapi.NewServer(st, cfg)
	if err != nil {
		log.Fatal(err)
	}
	r := server.Router()

	log.Printf("SOLVANTA backend listening on %s (env=%s)", addr, envLabel(cfg))
	if err := r.Run(addr); err != nil {
		log.Fatal(err)
	}
}

func envLabel(cfg httpapi.Config) string {
	if cfg.Production {
		return "production"
	}
	return "development"
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
