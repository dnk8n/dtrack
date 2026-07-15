# shellcheck shell=bash
# Shared plumbing for the test runners — source it, don't execute it.
#
# Tests never touch the dev/debug database. Every run gets a fresh
# test_<epoch-seconds>_<app-db> database cloned from template_<app-db>, the
# pristine snapshot `make initdb` takes right after bootstrapping. Old test
# databases are pruned (newest 3 kept for post-mortems) before each run.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

# Default to the same compose file set as `make debug`, so recreating
# postgrest keeps its published port and debug JWT secret.
export COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yaml:config/docker-compose.overrides/dev.yaml:config/docker-compose.overrides/debug.yaml}"

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
    echo "No .env file found — run 'make env' first." >&2
    exit 1
fi
set -a
# shellcheck source=/dev/null
source "${REPO_ROOT}/.env"
set +a

TEMPLATE_DB="template_${POSTGRES_DB_APP}"

psql_super() {
    local db="$1"
    shift
    (cd "${REPO_ROOT}" && docker compose exec -T postgres \
        psql --quiet --tuples-only --no-align --set ON_ERROR_STOP=1 \
        -U "${POSTGRES_USER}" -d "${db}" "$@")
}

db_exists() {
    [[ "$(psql_super postgres -c "SELECT count(*) FROM pg_database WHERE datname = '$1'")" == "1" ]]
}

# Drop all but the newest 3 test databases.
prune_test_dbs() {
    local db
    while IFS= read -r db; do
        [[ -n "${db}" ]] || continue
        echo "--> Dropping old test database ${db}"
        psql_super postgres -c "DROP DATABASE \"${db}\" WITH (FORCE)"
    done < <(psql_super postgres -c "
        SELECT datname FROM pg_database
        WHERE datname ~ '^test_[0-9]+_${POSTGRES_DB_APP}$'
        ORDER BY datname DESC OFFSET 3")
}

# Prune, then create a fresh test database from the template. Sets TEST_DB.
create_test_db() {
    if ! db_exists "${TEMPLATE_DB}"; then
        echo "Template database '${TEMPLATE_DB}' not found — run 'make initdb'" >&2
        echo "(it snapshots the freshly bootstrapped schema for test runs)." >&2
        exit 1
    fi
    prune_test_dbs
    TEST_DB="test_$(date +%s)_${POSTGRES_DB_APP}"
    while db_exists "${TEST_DB}"; do # epoch-second collision with a kept db
        sleep 1
        TEST_DB="test_$(date +%s)_${POSTGRES_DB_APP}"
    done
    echo "--> Creating test database ${TEST_DB} from ${TEMPLATE_DB}"
    psql_super postgres -c "CREATE DATABASE \"${TEST_DB}\" TEMPLATE \"${TEMPLATE_DB}\""
    # Database-level settings are not copied from templates; mirror the
    # search_path the bootstrap sets (dtrack/db/sql/000.…/000.createdb.sql).
    psql_super postgres -c "ALTER DATABASE \"${TEST_DB}\"
        SET search_path TO public, pre, auth, api, internal, cyanaudit"
}

# Recreate postgrest bound to the given database and wait until it answers.
point_postgrest_at() {
    (cd "${REPO_ROOT}" && POSTGRES_DB_APP="$1" docker compose up -d postgrest)
    local i
    for i in $(seq 1 60); do
        if curl -fsS "${DTRACK_TEST_API_URI:-http://localhost:3000}/" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "PostgREST did not become ready within 60s" >&2
    return 1
}

# Rebind postgrest to the dev/debug database. Install as an EXIT trap right
# before point_postgrest_at, so the dev stack is restored even on failure.
restore_postgrest() {
    local rc=$?
    echo "--> Restoring PostgREST to ${POSTGRES_DB_APP}"
    (cd "${REPO_ROOT}" && docker compose up -d postgrest >/dev/null 2>&1) || true
    exit "${rc}"
}
