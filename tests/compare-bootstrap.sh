#!/usr/bin/env bash
# One-off check for the move to dbmate (#47): bootstrap one cluster with the
# old envsubst-based initdb.sh at OLD_REF and another with the current
# bootstrap + migrations, then require identical schemas, roles and
# cyanaudit configuration. Delete this script and its CI job once the first
# migration after the baseline lands (the schemas will then differ on
# purpose).
#
#   tests/compare-bootstrap.sh <old git ref>
set -euo pipefail
cd "$(dirname "$0")/.."

old_ref="${1:?usage: $0 <old git ref>}"
work="$(mktemp -d)"
old_tree="${work}/old"
export COMPOSE_FILE=docker-compose.yaml

cleanup() {
    (cd "${old_tree}" 2>/dev/null && COMPOSE_PROJECT_NAME=dtrack-cmp-old docker compose down -v >/dev/null 2>&1) || true
    COMPOSE_PROJECT_NAME=dtrack-cmp-new docker compose down -v >/dev/null 2>&1 || true
    git worktree remove --force "${old_tree}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Normalised: pg_dump's per-run \restrict keys, and cyanaudit's active
# partition, whose name (tb_audit_event_YYYYMMDD_HHMM) and range constraint
# carry the install time. The two clusters are built minutes apart, so the
# name differs whenever they straddle a minute boundary.
dump() {
    dump_raw | sed -E -e '/^\\(un)?restrict /d' \
        -e "s/(partition_range_chk CHECK \(\(recorded >= )'[^']*'/\\1'<install time>'/" \
        -e 's/tb_audit_event_[0-9]{8}_[0-9]{4}/tb_audit_event_<install time>/g'
}

dump_raw() {
    docker compose exec -T postgres pg_dump -U postgres --schema-only \
        --exclude-schema=dbmate dtrack
    docker compose exec -T postgres pg_dumpall -U postgres --roles-only \
        --no-role-passwords
    docker compose exec -T postgres psql -U postgres -d dtrack --no-psqlrc \
        --tuples-only --no-align -c 'SELECT name, value FROM cyanaudit.tb_config ORDER BY name' \
        -c 'SELECT table_schema, table_name, column_name, enabled, loggable
              FROM cyanaudit.tb_audit_field ORDER BY 1, 2, 3'
}

echo "--> Old bootstrap (${old_ref})"
git worktree add --detach "${old_tree}" "${old_ref}" >/dev/null
cp "${old_tree}/.env.tpl" "${old_tree}/.env"
(cd "${old_tree}" && COMPOSE_PROJECT_NAME=dtrack-cmp-old && export COMPOSE_PROJECT_NAME &&
    ./initdb.sh >&2 && dump) >"${work}/old.sql"

echo "--> New bootstrap (working tree)"
(COMPOSE_PROJECT_NAME=dtrack-cmp-new && export COMPOSE_PROJECT_NAME &&
    ./initdb.sh >&2 && ./power-user.sh >&2 && dump) >"${work}/new.sql"

if diff -u "${work}/old.sql" "${work}/new.sql"; then
    echo "Old and new bootstrap produce the same schema, roles and audit configuration."
else
    echo "The new bootstrap differs from the old one (diff above)." >&2
    exit 1
fi
