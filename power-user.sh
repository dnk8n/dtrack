#!/usr/bin/env bash
# Make someone a power user: the "God mode" role that bypasses row-level
# security and can change everything. Use it sparingly — normally once, for
# the first administrator of a new tenant, who then manages everyone else
# from the Employees screen (docs/runbooks/new-tenant.md). Idempotent.
#
#   ./power-user.sh someone@example.com
#
# The email must be exactly the user's UPN as Entra puts it in the ID token
# (preferred_username), case included. With no argument it falls back to
# POSTGRES_USER_APP_POWER from .env (local development and the test suites).
set -euo pipefail
cd "$(dirname "$0")"

if [[ -f .env ]]; then
    set -a
    # shellcheck source=/dev/null
    source .env
    set +a
fi

email="${1:-${POSTGRES_USER_APP_POWER:-}}"
if [[ -z "$email" || "$#" -gt 1 ]]; then
    echo "usage: $0 <email>" >&2
    exit 2
fi

echo "--> Granting power to ${email}"
docker compose exec -T postgres psql --quiet --no-psqlrc --set ON_ERROR_STOP=1 \
    -o /dev/null -U admin -d dtrack --set email="$email" <dtrack/db/power-user.sql
