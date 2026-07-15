#!/usr/bin/env bash
# Run the HTTP tests against the isolated test environment (see tests/lib.sh):
# a fresh cluster and PostgREST on :3001, recreated for every run and left
# up afterwards for inspection. The dev/debug stack is never touched.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

recreate_test_env postgrest
wait_for_url "${DTRACK_TEST_API_URI}/"

cd "${TESTS_DIR}"
[ -d node_modules ] || npm ci
npx vitest run api
