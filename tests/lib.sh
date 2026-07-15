# shellcheck shell=bash
# Shared plumbing for the test runners — source it, don't execute it.
#
# Tests run in a completely isolated environment: a separate compose project
# (own postgres cluster, PostgREST and UI on their own host ports) built from
# the same compose files as dev/debug plus config/docker-compose.overrides/
# test.yaml. Every runner invocation tears down the previous test environment
# and recreates it from the ground up with the real bootstrap (initdb.sh);
# afterwards it is left running for inspection until the next run.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

export COMPOSE_PROJECT_NAME="${DTRACK_TEST_PROJECT:-dtrack-test}"
export COMPOSE_FILE="docker-compose.yaml:config/docker-compose.overrides/dev.yaml:config/docker-compose.overrides/debug.yaml:config/docker-compose.overrides/test.yaml"

# Where the suites reach the test stack (helpers.ts / playwright.config.ts
# read the same variables).
export DTRACK_TEST_API_URI="${DTRACK_TEST_API_URI:-http://localhost:3001}"
export DTRACK_TEST_APP_URI="${DTRACK_TEST_APP_URI:-http://localhost:5175}"

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

# Tear down the previous test environment (containers + volume) and stand up
# a fresh one: bootstrap the new cluster, then start the requested services
# (postgres alone needs no arguments).
# shellcheck disable=SC2120  # callers may pass no services (postgres only)
recreate_test_env() {
    cd "${REPO_ROOT}" || return 1
    echo "--> Recreating isolated test environment (compose project ${COMPOSE_PROJECT_NAME})"
    docker compose down --volumes --remove-orphans
    ./initdb.sh
    if [[ "$#" -gt 0 ]]; then
        docker compose up -d --build "$@"
    fi
}
