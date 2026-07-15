#!/usr/bin/env bash
# Run the Playwright end-to-end tests against the running debug-mode UI
# (see docs/testing.md). Prerequisites: stack up in debug mode with the
# database bootstrapped (make setup). Cleans residue from previous runs
# first, so repeated runs start from the same state.
set -euo pipefail
cd "$(dirname "$0")"

./cleanup-test-data.sh
[ -d node_modules ] || npm ci
npx playwright install ${CI:+--with-deps} chromium
npx playwright test
