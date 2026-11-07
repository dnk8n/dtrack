#!/usr/bin/env bash
# Run the Playwright end-to-end tests against the running debug-mode UI
# (see docs/testing.md). Prerequisites: stack up in debug mode and database
# bootstrapped (./initdb.sh && make debug).
set -euo pipefail
cd "$(dirname "$0")"
[ -d node_modules ] || npm ci
npx playwright install ${CI:+--with-deps} chromium
npx playwright test
