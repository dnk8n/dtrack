# shellcheck shell=bash
# Shared plumbing for the test runners — source it with TEST_SUITE set to
# db | api | e2e; don't execute it.
#
# Each suite runs in its own isolated environment: a compose project per
# suite (own postgres cluster, PostgREST and UI on their own host ports)
# built from the same compose files as dev/debug plus
# config/docker-compose.overrides/test.yaml — so the suites can run in
# parallel without contact, next to the dev stack. Every runner invocation
# tears its previous environment down and recreates it from the ground up
# with the real bootstrap (initdb.sh). When a run ends the containers are
# stopped, not removed: `make test-inspect-<suite>` brings the environment
# back for post-mortem/debugging, with the run's data still in its volume.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

: "${TEST_SUITE:?set TEST_SUITE to db, api or e2e before sourcing lib.sh}"

case "${TEST_SUITE}" in
    db)
        TEST_PG_PORT=5433 TEST_API_PORT=3003 TEST_UI_PORT=5177
        TEST_SERVICES=(postgres)
        ;;
    api)
        TEST_PG_PORT=5434 TEST_API_PORT=3002 TEST_UI_PORT=5176
        TEST_SERVICES=(postgres postgrest)
        ;;
    e2e)
        # The UI bakes its API base at build time and the nginx CSP
        # allowlists 3001, so the e2e suite owns 3001/5175.
        TEST_PG_PORT=5435 TEST_API_PORT=3001 TEST_UI_PORT=5175
        TEST_SERVICES=(postgres postgrest react-admin)
        ;;
    *)
        echo "Unknown TEST_SUITE '${TEST_SUITE}' (expected db, api or e2e)" >&2
        exit 2
        ;;
esac
export TEST_PG_PORT TEST_API_PORT TEST_UI_PORT

export COMPOSE_PROJECT_NAME="dtrack-test-${TEST_SUITE}"
export COMPOSE_FILE="docker-compose.yaml:config/docker-compose.overrides/dev.yaml:config/docker-compose.overrides/debug.yaml:config/docker-compose.overrides/test.yaml"

# Where the suites reach their test stack (helpers.ts / playwright.config.ts
# read the same variables).
export DTRACK_TEST_API_URI="${DTRACK_TEST_API_URI:-http://localhost:${TEST_API_PORT}}"
export DTRACK_TEST_APP_URI="${DTRACK_TEST_APP_URI:-http://localhost:${TEST_UI_PORT}}"

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
    echo "No .env file found — run 'make env' first." >&2
    exit 1
fi
set -a
# shellcheck source=/dev/null
source "${REPO_ROOT}/.env"
set +a

wait_for_url() {
    local url="$1"
    for _ in $(seq 1 120); do
        if curl -fsS "${url}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "${url} did not become ready within 120s" >&2
    return 1
}

# Tear down this suite's previous test environment (containers + volume) and
# stand up a fresh one: bootstrap the new cluster, then start the suite's
# remaining services.
recreate_test_env() {
    cd "${REPO_ROOT}" || return 1
    echo "--> Recreating isolated ${TEST_SUITE} test environment (compose project ${COMPOSE_PROJECT_NAME})"
    docker compose down --volumes --remove-orphans
    ./initdb.sh
    if [[ "${#TEST_SERVICES[@]}" -gt 1 ]]; then
        docker compose up -d --build "${TEST_SERVICES[@]:1}"
    fi
}

# Stop (don't remove) the suite's containers so state stays retrievable.
# Install as an EXIT trap: runs on success and failure, preserving the code.
stop_test_env() {
    local rc=$?
    echo "--> Stopping ${TEST_SUITE} test environment (state kept; inspect with: make test-inspect-${TEST_SUITE})"
    (cd "${REPO_ROOT}" && docker compose stop >/dev/null 2>&1) || true
    exit "${rc}"
}
