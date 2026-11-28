#!/usr/bin/env bash
# Make someone a power user on the local stack: the "God mode" role that
# bypasses row-level security and can change everything. Use it sparingly —
# normally once, for the first administrator of a new tenant, who then
# manages everyone else from the Employees screen
# (docs/runbooks/new-tenant.md). Idempotent. A thin wrapper around
# `dtrack-ops power-user`; servers run that directly.
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

docker compose run --rm --build ops power-user "$email"
