#!/usr/bin/env bash
# Bring the DTrack database up to date. Safe to run at any time:
#
#   1. New cluster only (no `dtrack` database yet): the one-off superuser
#      bootstrap in dtrack/db/bootstrap/ creates the admin and authenticator
#      roles, the database, cyanaudit and the superuser-owned auth functions.
#   2. Every run: set the admin and authenticator passwords from .env
#      (dtrack/db/set-passwords.sql, values passed as psql variables).
#   3. Every run: apply pending migrations in dtrack/db/migrations/ with
#      dbmate (the compose `migrate` service), as admin.
#
# It never creates a power user: run ./power-user.sh for that (see
# docs/runbooks/new-tenant.md). Background: docs/architecture.md.
#
# Pass --force to remove the containers and data volume and start over.
# Pass --dev-logging (development only, used by `make initdb`) to enable
# verbose statement logging on a newly bootstrapped cluster; deployed servers
# must run without it.
#
# Respects COMPOSE_FILE, so `make initdb` targets the same compose
# configuration as `make demo`. Called bare (as on deployed servers) it uses
# the default compose file resolution (the server .env sets COMPOSE_FILE).
set -euo pipefail
cd "$(dirname "$0")"

force=false
dev_logging=false
for arg in "$@"; do
    case "$arg" in
        --force) force=true ;;
        --dev-logging) dev_logging=true ;;
        *)
            echo "usage: $0 [--force] [--dev-logging]" >&2
            exit 2
            ;;
    esac
done

if [[ ! -f .env ]]; then
    echo "No .env file found — run 'make env' (or: cp .env.tpl .env) first." >&2
    exit 1
fi
set -a
# shellcheck source=/dev/null
source .env
set +a

: "${POSTGRES_USER:?set POSTGRES_USER in .env}"
: "${POSTGRES_PASSWORD_APP:?set POSTGRES_PASSWORD_APP in .env}"
: "${POSTGRES_PASSWORD_APP_ADMIN:?set POSTGRES_PASSWORD_APP_ADMIN in .env}"

wait_for_postgres() {
    local i
    for i in $(seq 1 60); do
        if docker compose exec -T postgres pg_isready --quiet -U "${POSTGRES_USER}" 2>/dev/null; then
            return 0
        fi
        [[ "$i" == 1 ]] && echo "Waiting for postgres to accept connections..."
        sleep 1
    done
    echo "postgres did not become ready within 60s" >&2
    return 1
}

# psql as the superuser inside the postgres container; SQL comes on stdin.
psql_superuser() {
    local db="$1"
    docker compose exec -T postgres psql --quiet --no-psqlrc --set ON_ERROR_STOP=1 \
        -o /dev/null -U "${POSTGRES_USER}" -d "$db"
}

# Quote a value as a single-quoted psql meta-command argument.
psql_quote() {
    local s="${1//\\/\\\\}"
    printf "'%s'" "${s//\'/\'\'}"
}

if [[ "$force" == true ]]; then
    echo "--> Removing containers and data volume (--force)"
    docker compose down --volumes
fi

docker compose up --detach --build postgres
wait_for_postgres

bootstrapped=false
if [[ "$(docker compose exec -T postgres psql --no-psqlrc --tuples-only --no-align \
    -U "${POSTGRES_USER}" -d postgres \
    -c "SELECT count(*) FROM pg_database WHERE datname = 'dtrack'")" != "1" ]]; then
    echo "--> Bootstrapping a new cluster (dtrack/db/bootstrap/)"
    psql_superuser postgres <dtrack/db/bootstrap/01.create-db.sql
    docker compose exec -T postgres bash -s -- -U "${POSTGRES_USER}" -d dtrack \
        <dtrack/db/bootstrap/02.install-cyanaudit.sh
    psql_superuser dtrack <dtrack/db/bootstrap/03.roles.sql
    psql_superuser dtrack <dtrack/db/bootstrap/04.auth-mgmt.sql
    bootstrapped=true
fi

echo "--> Setting application role passwords"
{
    printf '\\set admin_password %s\n' "$(psql_quote "${POSTGRES_PASSWORD_APP_ADMIN}")"
    printf '\\set authenticator_password %s\n' "$(psql_quote "${POSTGRES_PASSWORD_APP}")"
    cat dtrack/db/set-passwords.sql
} | psql_superuser postgres

echo "--> Applying migrations (dtrack/db/migrations/)"
docker compose run --rm --no-deps migrate

# Verbose logging for development only (make initdb passes --dev-logging):
# log_statement = 'all' writes every statement, including sensitive data, to
# the server log — never enable it on a deployed instance. ALTER SYSTEM is
# idempotent and independent of the image's data-directory layout.
if [[ "$dev_logging" == true && "$bootstrapped" == true ]]; then
    echo "ALTER SYSTEM SET log_statement = 'all'; ALTER SYSTEM SET log_min_messages = 'notice';" |
        psql_superuser postgres
    echo "--> Restarting postgres to apply dev logging configuration"
    docker compose restart postgres
    wait_for_postgres
fi

echo "Database 'dtrack' is up to date."
