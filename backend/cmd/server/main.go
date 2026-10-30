// Command server runs the SOLVANTA backend API. Configuration is read from
// environment ("PORT", "ADDR", "SECRET", "ALLOWED_ORIGINS", "TRUSTED_PROXIES", "ENV",
// "POSTGRES_DSN", "SEED"). Storage defaults to the in-memory development store
// (seeded together with the client app); setting POSTGRES_DSN switches to the
// PostgreSQL-backed store (schema applied at boot).
package main

import (
	"log"
	"os"
	"strings"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/httpapi"
	"solvanta/backend/internal/store"
)

func main() {
	addr := os.Getenv("ADDR")
	if addr == "" {
		// Loopback by default. The API carries school records and boots with
		// seeded demo accounts, so a laptop on shared Wi-Fi should not offer it
		// to the network without meaning to. The emulator's `adb reverse` and
		// the parity suite both reach it at 127.0.0.1; the Docker image sets
		// ADDR=:8080 explicitly, and any real deployment should too.
		addr = "127.0.0.1:" + firstNonEmpty(os.Getenv("PORT"), "8080")
	}
	cfg := httpapi.Config{
		Secret:     os.Getenv("SECRET"),
		Production: os.Getenv("ENV") == "production",
	}
	cfg.AllowedOrigins = splitList(os.Getenv("ALLOWED_ORIGINS"))
	cfg.TrustedProxies = splitList(os.Getenv("TRUSTED_PROXIES"))

	// Every school gets a store of its own (store.Tenants): a PostgreSQL
	// schema each in production, or an in-memory store each for development.
	var tenants store.Tenants
	if dsn := os.Getenv("POSTGRES_DSN"); dsn != "" {
		log.Println("using PostgreSQL, one schema per school")
		pg, err := store.NewPostgresTenants(dsn, shouldSeed(cfg.Production))
		if err != nil {
			log.Fatalf("postgres: %v", err)
		}
		defer pg.Close()
		tenants = pg
	} else {
		// In memory, a restart loses every school's records: never in
		// production.
		if cfg.Production {
			log.Fatal("POSTGRES_DSN must be set in production: the in-memory store loses all data on restart")
		}
		log.Println("using in-memory stores (set POSTGRES_DSN for persistence)")
		def := store.NewUnseeded()
		if shouldSeed(cfg.Production) {
			def = store.New()
		}
		tenants = store.NewMemoryTenants(def)
	}

	// Gin's debug mode prints every route at boot and warns on each start;
	// production runs quiet unless GIN_MODE is set explicitly.
	if cfg.Production && os.Getenv("GIN_MODE") == "" {
		gin.SetMode(gin.ReleaseMode)
	}

	server, err := httpapi.NewTenantServer(tenants, cfg)
	if err != nil {
		log.Fatal(err)
	}
	r := server.Router()

	log.Printf("SOLVANTA backend listening on %s (env=%s)", addr, envLabel(cfg))
	// Stated loudly and once at boot: which engine actually serves maths
	// content and which serves handwriting, and why. Without this a
	// deployment that meant to buy a key can run for weeks on the mock with
	// nothing in the logs to say so.
	log.Println(server.OCRStatus())
	log.Println(server.SMSStatus())
	if err := r.Run(addr); err != nil {
		log.Fatal(err)
	}
}

// shouldSeed decides whether to load the demo dataset at boot. Development
// seeds by default so the sample logins work out of the box (SEED=false turns
// it off). Production never seeds unless SEED is set explicitly: the seed
// creates accounts with publicly known passwords (super@solvanta.app/super123,
// admin@solvanta.app/admin123, …) and previously defaulted to ON, so any
// production box with POSTGRES_DSN set silently grew a super-admin.
func shouldSeed(production bool) bool {
	v := strings.ToLower(strings.TrimSpace(os.Getenv("SEED")))
	yes := v == "true" || v == "1" || v == "yes"
	if !production {
		no := v == "false" || v == "0" || v == "no"
		return !no
	}
	if yes {
		log.Println("WARNING: SEED=true in production - demo accounts with publicly known passwords are being created; rotate them now or unset SEED")
	}
	return yes
}

func envLabel(cfg httpapi.Config) string {
	if cfg.Production {
		return "production"
	}
	return "development"
}

// splitList reads a comma-separated env value, dropping blanks.
func splitList(v string) []string {
	var out []string
	for _, item := range strings.Split(v, ",") {
		if item = strings.TrimSpace(item); item != "" {
			out = append(out, item)
		}
	}
	return out
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
