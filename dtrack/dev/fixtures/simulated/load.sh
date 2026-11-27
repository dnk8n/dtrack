#!/usr/bin/env bash
# Load simulated fixture data (see README.md) into the local stack's database.
#
#   FIXTURE_LEAD=lena.lead@example.com FIXTURE_MEMBER=bob.basic@example.com \
#     dtrack/dev/fixtures/simulated/load.sh
#
# FIXTURE_ADMIN defaults to POSTGRES_USER_APP_POWER from .env. All three users
# must already exist (signed in once, or created on the Employees screen).
set -euo pipefail
cd "$(dirname "$0")/../../../.."

set -a
# shellcheck source=/dev/null
source .env
set +a

: "${FIXTURE_LEAD:?set FIXTURE_LEAD to the lead email address}"
: "${FIXTURE_MEMBER:?set FIXTURE_MEMBER to the member email address}"
FIXTURE_ADMIN="${FIXTURE_ADMIN:-$POSTGRES_USER_APP_POWER}"

docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD_APP" postgres psql --quiet -X \
    -U authenticator -d dtrack \
    -v admin="$FIXTURE_ADMIN" -v lead="$FIXTURE_LEAD" -v member="$FIXTURE_MEMBER" \
    -f - <dtrack/dev/fixtures/simulated/fixtures.sql
