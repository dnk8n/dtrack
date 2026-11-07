#!/usr/bin/env bash
# Bootstrap the DTrack database by executing everything under dtrack/db/sql/
# in lexicographic order. Directory names encode which user runs the files on
# which database (see docs/architecture.md); files are piped through envsubst
# so $VARIABLES resolve from .env.
#
# Idempotent: if the application database already exists this is a no-op.
# Pass --force to remove the containers and data volume and start over.
# Pass --dev-logging (development only — used by `make initdb`) to enable
# verbose statement logging; deployed servers must run without it.
#
# Respects COMPOSE_FILE, so `make initdb` targets the same compose
# configuration as `make debug`. Called bare (as on deployed servers) it uses
# the default compose file resolution.
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

if [[ "$force" == true ]]; then
    echo "--> Removing containers and data volume (--force)"
    docker compose down --volumes
fi

docker compose up --detach --build postgres
wait_for_postgres

psql_admin() {
    docker compose exec -T postgres psql --quiet --tuples-only --no-align \
        --set ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" "$@"
}

db_exists() {
    [[ "$(psql_admin -c "SELECT count(*) FROM pg_database WHERE datname = '$1'")" == "1" ]]
}

if db_exists "${POSTGRES_DB_APP}"; then
    echo "Database '${POSTGRES_DB_APP}' already exists — nothing to do (use --force to recreate)."
    exit 0
fi

execute_files() {
    local dir="$1"
    local base_dir user_var db_var user db file
    base_dir="$(basename "$dir")"

    # Directory naming: <NNN>.<user-env-var>.<db-env-var>
    user_var="$(cut -d. -f2 <<<"$base_dir" | tr '[:lower:]' '[:upper:]')"
    db_var="$(cut -d. -f3 <<<"$base_dir" | tr '[:lower:]' '[:upper:]')"
    user="${!user_var}"
    db="${!db_var}"

    while IFS= read -r -d '' file; do
        if [[ "$file" == *.sql ]]; then
            echo "--> Executing $file as $user on $db"
            envsubst <"$file" | docker compose exec -T postgres \
                psql --quiet --set ON_ERROR_STOP=1 -o /dev/null -U "$user" -d "$db"
        elif [[ "$file" == *.sh ]]; then
            echo "--> Executing $file as bash script ($user on $db)"
            envsubst <"$file" | docker compose exec -T postgres bash -- /dev/stdin -U "$user" -d "$db"
        fi
    done < <(find "$dir" -type f \( -name '*.sql' -o -name '*.sh' \) -print0 | sort -z)
}

for dir in dtrack/db/sql/*; do
    echo "Processing $dir:"
    execute_files "$dir"
done

# Verbose logging for development only (make initdb passes --dev-logging):
# log_statement = 'all' writes every statement, including sensitive data, to
# the server log — never enable it on a deployed instance. ALTER SYSTEM is
# idempotent and independent of the image's data-directory layout.
if [[ "$dev_logging" == true ]]; then
    psql_admin -c "ALTER SYSTEM SET log_statement = 'all'"
    psql_admin -c "ALTER SYSTEM SET log_min_messages = 'notice'"
    echo "--> Restarting postgres to apply dev logging configuration"
    docker compose restart postgres
    wait_for_postgres
fi

echo "Database '${POSTGRES_DB_APP}' bootstrapped."
