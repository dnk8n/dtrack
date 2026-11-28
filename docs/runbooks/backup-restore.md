# Backup & restore runbook

Backing up production, testing the restore on your own machine, and
restoring onto a live server (moving to a new server, or recovering from data
loss). Schema changes don't need it: `ops init` (locally `./initdb.sh`)
applies migrations in place.

Backups are data-only. The schema comes from the release: `ops init`
bootstraps the empty database and applies every migration, then
`ops restore` loads the data into it, restores the audit log and recreates
every user's role ([dtrack/db/restore-fixups.sql](../../dtrack/db/restore-fixups.sql)).
Restore with the same release (or a later one, if no migration in between
changes the shape of existing tables) as the server the backup came from. The
`dbmate` schema (migration history) is left out of backups because the
restore target already has its own. Power isn't part of a backup: grant it
again with `ops power-user` after the restore, never before (`ops restore`
refuses a database that already has users).

A backup is one `dtrack-<UTC time>.tar` holding `dtrack.dump` and
`cyanaudit/`. Older backups made by hand are a directory with the same two
entries: pack it with `tar -C <dir> -cf dtrack-legacy.tar dtrack.dump cyanaudit`.

# 1. Backup
## Single-server stack
Nightly by cron, or now: `docker compose run --rm ops backup` in the install
directory. The tarball lands in `BACKUP_DIR` (see
[server-install.md](server-install.md#stage-11-backups-and-key-rotation)).

## Older servers (checkout in /home/ubuntu/dtrack, Terraform/Ansible)
### From your machine
- `ssh ubuntu@<PROD_HOST> -i keys/prod/instance/id`
- `screen -S dtrack-backup`
### On the server
- `cd /home/ubuntu/dtrack`
- Use `dtrack/dev/queries/useful.sql` to inspect current/latest activity
- Only if proceding to a prod deploy (worth testing restore without this step): `docker compose kill --signal=SIGTERM postgrest react-admin`
- `docker compose exec postgres bash`
- `rm -rf /tmp/dtrack.dump /tmp/cyanaudit`
- `pg_dump -U admin -Fc --exclude-schema cyanaudit --exclude-schema dbmate --data-only -f /tmp/dtrack.dump dtrack`
- `mkdir -p /tmp/cyanaudit && /opt/cyanaudit/tools/cyanaudit_dump.pl -h localhost -U postgres -d dtrack /tmp/cyanaudit/`
- `exit`
- `TODAY="$(date --iso)"`
- `BACKUP_DIR=/home/ubuntu/backups/"${TODAY}"`
- `rm -rf "${BACKUP_DIR}"`
- `mkdir -p "${BACKUP_DIR}"`
- `docker compose cp postgres:/tmp/dtrack.dump "${BACKUP_DIR}"/`
- `docker compose cp postgres:/tmp/cyanaudit "${BACKUP_DIR}"/`
- `exit`
- `exit`
- If proceding to a prod deploy, to minimize downtime, procede with Live restore
  (be sure to frequently test the restore functionality)

# 2. Test Restore
On your own machine, with a checkout at the release the backup should go
onto:

- Copy the backup tarball into `./backup/` in the checkout (gitignored), e.g.
  `scp <server>:/var/backups/dtrack/dtrack-<stamp>.tar backup/`
- `./initdb.sh --force` (deletes the local database, then bootstraps and migrates)
- `docker compose run --rm --build ops restore dtrack-<stamp>.tar`
- `./power-user.sh <your UPN>` if you want to sign in as an administrator
- `make demo` (or `make dev` with the backup's tenant), then test at
  http://localhost:5174

# 3. Live Restore
## Single-server stack
[server-install.md stage 14](server-install.md#stage-14-restore-a-backup):
back up, replace the database volume, `ops init`, `ops restore`,
`ops power-user`.

## Older servers (checkout, Terraform/Ansible)
- Copy the backup directory to the server (`/home/ubuntu/backups/<date>`),
  then on the server, in `screen`:
- `cd /home/ubuntu/dtrack && git pull`
- `BACKUP_DIR=/home/ubuntu/backups/<date>` and check it holds `dtrack.dump` and `cyanaudit/`
- `mkdir -p backup && tar -C "${BACKUP_DIR}" -cf backup/restore.tar dtrack.dump cyanaudit`
- `./initdb.sh --force` (deletes the database)
- `docker compose run --rm --build ops restore restore.tar`
- `./power-user.sh <admin UPN>`
- `docker compose up -d`, then sanity-check `https://<HOST>`
