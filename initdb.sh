#!/usr/bin/env bash
# Bring the local DTrack database up to date: a thin wrapper around
# `dtrack-ops init` (dtrack/ops/dtrack-ops), run from the ops image built
# from this checkout. Safe to run at any time:
#
#   1. New cluster only (no `dtrack` database yet): the one-off superuser
#      bootstrap in dtrack/db/bootstrap/.
#   2. Every run: set the admin and authenticator passwords from .env.
#   3. Every run: apply pending migrations in dtrack/db/migrations/ (dbmate).
#
# It never creates a power user: run ./power-user.sh for that (see
# docs/runbooks/new-tenant.md). Servers don't use this script; they run the
# published ops image directly (docs/runbooks/server-install.md).
#
# Pass --force to remove the containers and data volume and start over.
# Pass --dev-logging (development only, used by `make initdb`) to enable
# verbose statement logging on a newly bootstrapped cluster.
#
# Respects COMPOSE_FILE, so `make initdb` targets the same compose
# configuration as `make demo`.
set -euo pipefail
cd "$(dirname "$0")"

force=false
init_args=()
for arg in "$@"; do
    case "$arg" in
        --force) force=true ;;
        --dev-logging) init_args+=(--dev-logging) ;;
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

if [[ "$force" == true ]]; then
    echo "--> Removing containers and data volume (--force)"
    docker compose down --volumes
fi

docker compose up --detach --build postgres
docker compose run --rm --build ops init ${init_args[@]+"${init_args[@]}"}
