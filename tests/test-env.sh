#!/usr/bin/env bash
# Bring a suite's stopped test environment back up for inspection — the data
# from its last run is still in the project's volume.
# Usage: TEST_SUITE=db|api|e2e tests/test-env.sh   (or: make test-up-<suite>)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "${REPO_ROOT}"

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
