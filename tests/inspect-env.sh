#!/usr/bin/env bash
# Bring a suite's stopped test environment back up for post-mortem or
# debugging — the data from its last run is still in the project's volume.
# Never bootstraps or reruns anything; a test *run* (make test-<suite>) is
# what clobbers the volume and recreates the environment.
# Usage: TEST_SUITE=db|api|e2e tests/inspect-env.sh   (or: make test-inspect-<suite>)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "${REPO_ROOT}"

if [[ -z "$(docker compose ps --all --quiet)" ]]; then
    echo "No previous ${TEST_SUITE} test run found (nothing to inspect)." >&2
    echo "Run one first: make test-${TEST_SUITE}" >&2
    exit 1
fi

docker compose up -d --no-build "${TEST_SERVICES[@]}"

echo
echo "${TEST_SUITE} test environment is up (compose project ${COMPOSE_PROJECT_NAME}):"
echo "  postgres   localhost:${TEST_PG_PORT} (psql -h localhost -p ${TEST_PG_PORT} -U admin -d dtrack)"
for service in "${TEST_SERVICES[@]}"; do
    case "${service}" in
        postgrest) echo "  PostgREST  ${DTRACK_TEST_API_URI}" ;;
        react-admin) echo "  UI         ${DTRACK_TEST_APP_URI}" ;;
    esac
done
echo "Stop again with: docker compose stop (same COMPOSE_PROJECT_NAME), or make clean."
