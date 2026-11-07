#!/usr/bin/env bash
# Run the HTTP tests against a running PostgREST (see docs/testing.md).
# Prerequisites: stack up in debug mode and database bootstrapped
# (./initdb.sh && make debug).
set -euo pipefail
cd "$(dirname "$0")"
[ -d node_modules ] || npm ci
npx vitest run api
