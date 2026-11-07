#!/usr/bin/env bash
# Run the pgTAP suite in its isolated test environment (see tests/lib.sh):
# a fresh cluster bootstrapped for every run, stopped (state kept) at the
# end. pg_prove and the pgTAP packages come from the image's `test` build
# target, which the dev compose override selects; production images carry
# no test tooling.
set -euo pipefail
export TEST_SUITE=db
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

trap stop_test_env EXIT
# shellcheck disable=SC2119  # db suite needs no services beyond postgres
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
status=0
output=$(docker compose exec -T postgres \
    bash -c "pg_prove -U '${POSTGRES_USER}' -d '${POSTGRES_DB_APP}' /tmp/dtrack-db-tests/*.sql") || status=$?
printf '%s\n' "$output"
[ "$status" -eq 0 ] || exit "$status"

# pg_prove (TAP::Harness) reports a passing todo() as "TODO passed" and
# still exits 0, so a fixed (or silently changed) expected-fail would go
# unnoticed. Fail instead, so the todo marker has to be removed deliberately
# (docs/testing.md, policy 2).
if grep -q 'TODO passed' <<<"$output"; then
    echo "An expected-fail (todo) test now passes: see 'TODO passed' above." >&2
    echo "If the defect was fixed on purpose, remove its todo() marker and" >&2
    echo "update docs/testing.md \"Known defects\"." >&2
    exit 1
fi
