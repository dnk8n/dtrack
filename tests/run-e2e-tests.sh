#!/usr/bin/env bash
# Run the Playwright end-to-end tests in their isolated test environment
# (see tests/lib.sh): a fresh cluster, PostgREST and the debug-mode UI
# (built with its API base pointing at this suite's PostgREST port),
# recreated for every run and stopped (state kept) at the end. The
# dev/debug stack is never touched.
set -euo pipefail
export TEST_SUITE=e2e
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

trap stop_test_env EXIT
recreate_test_env
wait_for_url "${DTRACK_TEST_API_URI}/"
wait_for_url "${DTRACK_TEST_APP_URI}/"

cd "${TESTS_DIR}"
[ -d node_modules ] || npm ci
npx playwright install ${CI:+--with-deps} chromium
npx playwright test
