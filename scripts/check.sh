#!/usr/bin/env bash
# Runs every check the project expects before a merge or a deploy:
# Flutter analyze + tests, then Go vet + tests.
#
#   scripts/check.sh
#
# Optional:
#   TEST_POSTGRES_DSN=postgres://...   also run the PostgreSQL integration
#                                      tests. They TRUNCATE every table, so
#                                      point this at a throwaway database,
#                                      never the real one.
#   SOLVANTA_API_URL=http://127.0.0.1:8080   also run the app's live API
#                                      tests against a running dev server.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n== %s\n' "$1"; }

step "flutter analyze"
flutter analyze

step "flutter test"
flutter test

step "go vet"
(cd backend && go vet ./...)

step "go test"
# -p 1: the store and API packages share the Postgres test database and the
# store tests truncate it, so packages must not run at the same time.
(cd backend && go test -count=1 -p 1 ./...)

if [ -z "${TEST_POSTGRES_DSN:-}" ]; then
  echo "(PostgreSQL integration tests skipped: TEST_POSTGRES_DSN not set)"
fi

printf '\nAll checks passed.\n'
