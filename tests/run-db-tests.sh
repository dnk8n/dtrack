#!/usr/bin/env bash
# Run the pgTAP suite in a fresh test database (see tests/lib.sh for the
# test-database lifecycle). pg_prove and the pgTAP packages come from the
# image's `test` build target, which the dev compose override selects
# (make dev / make debug); production images carry no test tooling.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "${REPO_ROOT}"

if ! docker compose exec -T postgres bash -c 'command -v pg_prove' >/dev/null 2>&1; then
    echo "pg_prove not found in the postgres container." >&2
    echo "Start the stack via 'make debug' (or 'make dev') so the image is" >&2
    echo "built with its test target, which includes pgTAP." >&2
    exit 1
fi

create_test_db
psql_super "${TEST_DB}" -c 'CREATE EXTENSION IF NOT EXISTS pgtap'

docker compose exec -T postgres rm -rf /tmp/dtrack-db-tests
docker compose cp tests/db postgres:/tmp/dtrack-db-tests
docker compose exec -T postgres \
    bash -c "pg_prove -U '${POSTGRES_USER}' -d '${TEST_DB}' /tmp/dtrack-db-tests/*.sql"
