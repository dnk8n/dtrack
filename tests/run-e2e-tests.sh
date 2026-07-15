#!/usr/bin/env bash
# Run the Playwright end-to-end tests against the isolated test environment
# (see tests/lib.sh): a fresh cluster, PostgREST on :3001 and the debug-mode
# UI on :5175 (built with its API base pointing at the test PostgREST),
# recreated for every run and left up afterwards for inspection. The
# dev/debug stack is never touched.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

recreate_test_env postgrest react-admin
wait_for_url "${DTRACK_TEST_API_URI}/"
wait_for_url "${DTRACK_TEST_APP_URI}/"

cd "${TESTS_DIR}"
[ -d node_modules ] || npm ci
npx playwright install ${CI:+--with-deps} chromium
npx playwright test
