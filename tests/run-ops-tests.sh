#!/usr/bin/env bash
# Exercise the server's operations path in an isolated environment (see
# tests/lib.sh): the same dtrack-ops commands a server runs from the
# published ops image, built here from the checkout.
#
#   init + power-user (via recreate_test_env) -> data -> backup -> wipe ->
#   init -> restore -> the same users, roles and audit history; then
#   rotate-keys into a keys volume (needs outbound HTTPS to Microsoft).
set -euo pipefail
export TEST_SUITE=ops
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# Backups are written by the container as root, so keep them out of the
# checkout (a temporary directory, removed through a container at the end).
OPS_BACKUP_DIR="$(mktemp -d)"
export OPS_BACKUP_DIR

trap cleanup EXIT
# shellcheck disable=SC2119  # ops suite needs no services beyond postgres
recreate_test_env

ops() { docker compose run --rm -T ops "$@"; }
# Run a command in a throwaway ops container with the backup directory mounted.
in_backups() { docker run --rm -v "${OPS_BACKUP_DIR}:/backups" --entrypoint "$1" dtrack-ops:local "${@:2}"; }
cleanup() {
    local rc=$?
    in_backups sh -c 'rm -rf /backups/*' >/dev/null 2>&1 || true
    rmdir "${OPS_BACKUP_DIR}" 2>/dev/null || true
    (exit "${rc}") || stop_test_env
    stop_test_env
}
sql() { docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d dtrack -Atc "$1"; }
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

echo "--> Adding users"
for u in ops.lead@example.com ops.member@example.com; do
    docker compose exec -T postgres psql -q -U admin -d dtrack -c "SELECT auth.create_user('$u')" >/dev/null
done
users_before="$(sql 'SELECT count(*) FROM auth.users')"
audit_before="$(sql 'SELECT count(*) FROM cyanaudit.vw_audit_log')"
echo "users=${users_before} audit=${audit_before}"
[[ "${users_before}" -ge 3 ]] || fail "expected at least 3 users before backup"

echo "--> ops backup"
ops backup
backup="$(in_backups sh -c 'cd /backups && ls -1 dtrack-*.tar | tail -1')"
[[ -n "${backup}" ]] || fail "no backup written"
[[ "$(in_backups stat -c %a "/backups/${backup}")" == 640 ]] || fail "backup mode is not 640"
in_backups tar -tf "/backups/${backup}" | grep -q '^dtrack.dump$' || fail "backup lacks dtrack.dump"

echo "--> ops restore refuses a database that has data"
if ops restore "${backup}"; then
    fail "restore over existing data should have been refused"
fi

echo "--> Wiping, re-initialising and restoring"
docker compose down --volumes
# Cyan Audit names its log partitions after the minute they were created
# (tb_audit_event_YYYYMMDD_HHMM). A database initialised in the same minute
# as a partition in the backup already has that table, and the restore of
# that partition is skipped (ops restore then fails, see below). Real
# restores never initialise in the minute an old partition was created; here
# wait the minute out.
partitions="$(in_backups tar -tf "/backups/${backup}" | grep -o '[0-9]\{8\}_[0-9]\{4\}' || true)"
while grep -qx "$(date -u +%Y%m%d_%H%M)" <<<"${partitions}"; do sleep 2; done
"${REPO_ROOT}/initdb.sh"
ops restore "${backup}"

users_after="$(sql 'SELECT count(*) FROM auth.users')"
audit_after="$(sql 'SELECT count(*) FROM cyanaudit.vw_audit_log')"
echo "users=${users_after} audit=${audit_after}"
[[ "${users_after}" == "${users_before}" ]] || fail "user count ${users_after} != ${users_before}"
[[ "${audit_after}" -ge "${audit_before}" ]] || fail "audit log shrank: ${audit_after} < ${audit_before}"
for u in ops.lead@example.com ops.member@example.com; do
    [[ "$(sql "SELECT count(*) FROM pg_roles WHERE rolname = '$u'")" == 1 ]] || fail "role $u not recreated"
done
ops power-user "${POSTGRES_USER_APP_POWER}"

echo "--> ops rotate-keys into a keys volume"
# A real tenant (Microsoft's own; its signing keys are public). The shared
# "common" endpoint answers with different key sets from different servers.
tenant=72f988bf-86f1-41af-91ab-2d7cd011db47
keys_volume="${COMPOSE_PROJECT_NAME}-keys"
docker volume rm -f "${keys_volume}" >/dev/null
docker compose run --rm -T -e AZURE_TENANT_ID="${tenant}" -v "${keys_volume}:/keys" ops rotate-keys
docker compose run --rm -T -e AZURE_TENANT_ID="${tenant}" -v "${keys_volume}:/keys" ops rotate-keys | grep -q unchanged ||
    fail "second rotate-keys should report unchanged keys"
perms="$(docker run --rm -v "${keys_volume}:/keys" --entrypoint stat dtrack-ops:local -c '%a %u' /keys/jwt-secret)"
[[ "${perms}" == "600 1000" ]] || fail "keys file is '${perms}', expected '600 1000'"
docker volume rm -f "${keys_volume}" >/dev/null

echo "ops suite: all checks passed"
