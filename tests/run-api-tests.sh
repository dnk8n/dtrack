#!/usr/bin/env bash
# Run the HTTP tests against PostgREST bound to a fresh test database
# (see tests/lib.sh for the test-database lifecycle). PostgREST is pointed
# back at the dev/debug database when the run ends, pass or fail.
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
npx vitest run api
