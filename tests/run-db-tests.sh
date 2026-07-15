#!/usr/bin/env bash
# Run the pgTAP suite against the running dev/CI postgres container.
#
# pg_prove and the pgTAP packages come from the image's `test` build target,
# which the dev compose override selects (make dev / make debug); production
# images carry no test tooling. Every test file is a single transaction that
# rolls back, so no test data persists.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! docker compose exec -T postgres bash -c 'command -v pg_prove' >/dev/null 2>&1; then
    echo "pg_prove not found in the postgres container." >&2
    echo "Start the stack via 'make debug' (or 'make dev') so the image is" >&2
    echo "built with its test target, which includes pgTAP." >&2
    exit 1
fi

docker compose exec -T postgres psql -q -U postgres -d dtrack \
    -c 'CREATE EXTENSION IF NOT EXISTS pgtap;'

docker compose exec -T postgres rm -rf /tmp/dtrack-db-tests
docker compose cp tests/db postgres:/tmp/dtrack-db-tests
docker compose exec -T postgres \
    bash -c 'pg_prove -U postgres -d dtrack /tmp/dtrack-db-tests/*.sql'
