#!/usr/bin/env bash
# Run the HTTP tests against a running PostgREST (see docs/testing.md).
# Prerequisites: stack up in debug mode with the database bootstrapped
# (make setup). Cleans residue from previous runs first, so repeated runs
# start from the same state.
set -euo pipefail
cd "$(dirname "$0")"

./cleanup-test-data.sh
[ -d node_modules ] || npm ci
npx vitest run api
