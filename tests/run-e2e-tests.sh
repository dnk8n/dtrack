#!/usr/bin/env bash
# Run the Playwright end-to-end tests against the debug-mode UI, with
# PostgREST bound to a fresh test database for the duration (see
# tests/lib.sh for the test-database lifecycle); the UI talks to PostgREST
# on :3000, so it follows automatically. PostgREST is pointed back at the
# dev/debug database when the run ends, pass or fail.
# Prerequisites: stack up in debug mode with the database bootstrapped
# (make setup).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

create_test_db
trap restore_postgrest EXIT
point_postgrest_at "${TEST_DB}"

cd "${TESTS_DIR}"
[ -d node_modules ] || npm ci
npx playwright install ${CI:+--with-deps} chromium
npx playwright test
