#!/usr/bin/env bash
# Run the pgTAP suite in the isolated test environment (see tests/lib.sh):
# a fresh cluster is bootstrapped for every run. pg_prove and the pgTAP
# packages come from the image's `test` build target, which the dev compose
# override selects; production images carry no test tooling.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# shellcheck disable=SC2119  # no extra services needed beyond postgres
recreate_test_env

if ! docker compose exec -T postgres bash -c 'command -v pg_prove' >/dev/null 2>&1; then
    echo "pg_prove not found in the test postgres container — the image was" >&2
    echo "not built with its test target (config/docker-compose.overrides/dev.yaml)." >&2
    exit 1
fi

docker compose exec -T postgres psql -q -U "${POSTGRES_USER}" -d "${POSTGRES_DB_APP}" \
    -c 'CREATE EXTENSION IF NOT EXISTS pgtap'

docker compose exec -T postgres rm -rf /tmp/dtrack-db-tests
docker compose cp tests/db postgres:/tmp/dtrack-db-tests
docker compose exec -T postgres \
    bash -c "pg_prove -U '${POSTGRES_USER}' -d '${POSTGRES_DB_APP}' /tmp/dtrack-db-tests/*.sql"
