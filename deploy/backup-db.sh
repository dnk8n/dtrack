#!/usr/bin/env bash
# Nightly database backup for the single-server stack (run from cron as root;
# see deploy/cron.d-dtrack). Writes one tarball per run into BACKUP_DIR:
#
#   dtrack-<UTC timestamp>.tar   mode 640, group BACKUP_GROUP
#     dtrack.dump   pg_dump -Fc --data-only of the app DB, without cyanaudit
#                   and without the dbmate migration history (the restore
#                   target already has its own)
#     cyanaudit/    cyanaudit's own dump of the audit log
#
# The same two parts the restore runbook (docs/runbooks/backup-restore.md)
# expects: extract the tarball and use its directory as BACKUP_DIR there.
# Backups older than RETAIN_DAYS are deleted, but only after a good backup.
# BACKUP_DIR, BACKUP_GROUP and RETAIN_DAYS come from .env (defaults below).
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
# shellcheck source=/dev/null
source .env
set +a

# Settings from .env (deploy/server.env.tpl), else these defaults.
BACKUP_DIR="${BACKUP_DIR:-/var/backups/dtrack}"
BACKUP_GROUP="${BACKUP_GROUP:-dtrack-backup}"
RETAIN_DAYS="${RETAIN_DAYS:-7}"

umask 027
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
work="$(mktemp -d)"
trap 'rm -rf "$work"; docker compose exec -T postgres rm -rf /tmp/backup || true' EXIT

docker compose exec -T postgres rm -rf /tmp/backup
docker compose exec -T postgres mkdir -p /tmp/backup/cyanaudit
docker compose exec -T postgres pg_dump -U admin -Fc \
    --exclude-schema cyanaudit --exclude-schema dbmate --data-only \
    -f /tmp/backup/dtrack.dump dtrack
docker compose exec -T postgres /opt/cyanaudit/tools/cyanaudit_dump.pl \
    -h localhost -U "${POSTGRES_USER}" -d dtrack /tmp/backup/cyanaudit/
docker compose cp postgres:/tmp/backup/. "$work/"

mkdir -p "$BACKUP_DIR"
chgrp "$BACKUP_GROUP" "$BACKUP_DIR"
chmod 750 "$BACKUP_DIR"

tmp="$BACKUP_DIR/.dtrack-$stamp.tar.partial"
tar -C "$work" -cf "$tmp" dtrack.dump cyanaudit
chgrp "$BACKUP_GROUP" "$tmp"
chmod 640 "$tmp"
mv "$tmp" "$BACKUP_DIR/dtrack-$stamp.tar"
echo "backup written: $BACKUP_DIR/dtrack-$stamp.tar ($(du -h "$BACKUP_DIR/dtrack-$stamp.tar" | cut -f1))"

find "$BACKUP_DIR" -maxdepth 1 -name 'dtrack-*.tar' -mtime +"$((RETAIN_DAYS - 1))" -print -delete
