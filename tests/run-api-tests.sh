#!/usr/bin/env bash
# Run the HTTP tests in their isolated test environment (see tests/lib.sh):
# a fresh cluster and PostgREST recreated for every run, stopped (state
# kept) at the end. The dev/debug stack is never touched.
set -euo pipefail
export TEST_SUITE=api
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

trap stop_test_env EXIT
recreate_test_env
wait_for_url "${DTRACK_TEST_API_URI}/"

cd "${TESTS_DIR}"
[ -d node_modules ] || npm ci
npx vitest run api
