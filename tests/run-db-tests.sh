#!/usr/bin/env bash
# Run the pgTAP suite against the running dev/CI postgres container.
#
# pgTAP is installed into the *running container* at test time (packages from
# the PGDG apt repo already configured in the postgres image), so the
# production image stays untouched. The extension lives in the database until
# the volume is recreated; every test file is a single transaction that rolls
# back, so no test data persists.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "--> Ensuring pgTAP and pg_prove are installed in the postgres container"
docker compose exec -T -u root postgres bash -c '
    command -v pg_prove >/dev/null && dpkg -s postgresql-15-pgtap >/dev/null 2>&1 || {
        apt-get update -qq &&
        apt-get install -y -qq postgresql-15-pgtap libtap-parser-sourcehandler-pgtap-perl
    }' >/dev/null

docker compose exec -T postgres psql -q -U postgres -d dtrack \
    -c 'CREATE EXTENSION IF NOT EXISTS pgtap;'

echo "--> Copying tests into the container and running pg_prove"
docker compose exec -T postgres rm -rf /tmp/dtrack-db-tests
docker compose cp tests/db postgres:/tmp/dtrack-db-tests
docker compose exec -T postgres \
    bash -c 'pg_prove -U postgres -d dtrack /tmp/dtrack-db-tests/*.sql'
