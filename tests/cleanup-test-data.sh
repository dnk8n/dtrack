#!/usr/bin/env bash
# Delete residue from previous API/E2E test runs (see tests/cleanup.sql).
# Runs automatically at the start of run-api-tests.sh and run-e2e-tests.sh;
# also useful standalone to tidy a long-lived dev database.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose exec -T postgres psql --quiet --set ON_ERROR_STOP=1 \
    -U postgres -d dtrack -f - <tests/cleanup.sql
echo "--> Previous test-run data removed."
