# Backup & restore runbook

Operational procedure for backing up production, testing the restore locally,
and restoring onto a live server (used for schema-change deploys, since schema
is recreated rather than migrated). The automated equivalent runs bi-hourly via
[backup.yml](../../.github/workflows/backup.yml).

# 1. Backup
## Dev machine
- `ssh ubuntu@dtrack.rethinkcode.org -i keys/prod/instance/id`
- `screen -S dtrack-backup`
## Production server
- `cd /home/ubuntu/dtrack`
- Use `dtrack/dev/queries/useful.sql` to inspect current/latest activity
- Only if proceding to a prod deploy (worth testing restore without this step): `docker compose kill --signal=SIGTERM postgrest react-admin`
- `docker compose exec postgres bash`
- `rm -rf /tmp/dtrack.dump /tmp/cyanaudit`
- `pg_dump -U admin -Fc --exclude-schema cyanaudit --data-only -f /tmp/dtrack.dump dtrack`
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
## Dev machine
- `TODAY="$(date --iso)"`
- `BACKUP_DIR=~/Documents/dtrack/backups/"${TODAY}"`
- `rm -rf "${BACKUP_DIR}"`
- `scp -i keys/prod/instance/id -r ubuntu@dtrack.rethinkcode.org:/home/ubuntu/backups/"${TODAY}" "${BACKUP_DIR}"`
- `cd ~/src/dtrack`
- `git checkout main`
- `git pull`
- `docker compose down -v`
- `docker compose build --pull`
- `./initdb.sh`
- `docker compose up -d postgres`
- `docker compose cp "${BACKUP_DIR}"/dtrack.dump postgres:/tmp/`
- `docker compose cp "${BACKUP_DIR}"/cyanaudit postgres:/tmp/`
- `docker compose exec postgres bash`
- `pg_restore -U postgres --disable-triggers --no-owner --data-only -d dtrack /tmp/dtrack.dump`
- `/opt/cyanaudit/tools/cyanaudit_restore.pl -h localhost -U postgres -d dtrack /tmp/cyanaudit/*.csv.gz`
- `psql -U admin -d dtrack`
- Enter SQL commands, same as in live restore instructions below
- `exit`
- `exit`
- `docker compose up -d`
- `exit`
- Test at http://localhost:5174

# 3. Live Restore
## Dev machine
- `TODAY="$(date --iso)"`
- `BACKUP_DIR=~/Documents/dtrack/backups/"${TODAY}"`
- `scp -i keys/staging/instance/id -r "${BACKUP_DIR}" ubuntu@dtrack-staging.rethinkcode.org:/home/ubuntu/backups/"${TODAY}"` (prod already has the backup)
- SSH to live server:
  - Test: `ssh ubuntu@dtrack-staging.rethinkcode.org`
  - Prod: `ssh ubuntu@dtrack.rethinkcode.org`
- `screen -S dtrack-restore`
## Live server
- `cd /home/ubuntu/dtrack`
- `git checkout main`
- `git pull`
- `docker compose build --pull`
- `TODAY="$(date --iso)"`
- `BACKUP_DIR=/home/ubuntu/backups/"${TODAY}"`
- Make sure that the expected backup files are present `ls -lah "${BACKUP_DIR}"*/**`
- `docker compose down -v`
- Can use this opportunity to upgrade system packages
- `./initdb.sh`
- `docker compose up -d postgres`
- `docker compose cp "${BACKUP_DIR}"/dtrack.dump postgres:/tmp/`
- `docker compose cp "${BACKUP_DIR}"/cyanaudit postgres:/tmp/`
- `docker compose exec postgres bash`
- `pg_restore -U postgres --disable-triggers --no-owner --data-only -d dtrack /tmp/dtrack.dump`
- `/opt/cyanaudit/tools/cyanaudit_restore.pl -h localhost -U postgres -d dtrack /tmp/cyanaudit/*.csv.gz`
- `psql -U admin -d dtrack`
```
--- Fast forward new server transaction ids to after the historic ones
DO $$
DECLARE
    current_value BIGINT := 0;
    target_value BIGINT;
BEGIN
    SELECT max(txid) INTO target_value FROM cyanaudit.vw_audit_log;
    WHILE current_value < target_value LOOP
    current_value := txid_current();
    COMMIT;
    RAISE NOTICE 'Current value: %', current_value;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
--- Recreate users
SELECT auth.create_user(email)
FROM unnest(
    (SELECT array_agg(email) FROM api.employees WHERE roles IS NULL AND email LIKE '%@hellodnk8n.onmicrosoft.com')
) AS t(email);
--- Reassign PM role if applicable
DO $$
DECLARE
  lead_email text;
BEGIN
  FOR lead_email IN
    SELECT distinct email
    FROM internal.user_project_roles AS upr
    JOIN api.employees AS employees ON employees.id = upr.user_id
    WHERE is_lead = TRUE
    AND NOT (roles @> '["pm"]'::jsonb)
  LOOP
    PERFORM auth.grant_priv(lead_email, 'pm');
  END LOOP;
END;
$$ LANGUAGE plpgsql;
--- Reassign lead role if applicable
DO $$
DECLARE
  lead_email text;
BEGIN
  FOR lead_email IN
    SELECT distinct e.email
    FROM internal.aoe_hierarchies AS aoeh
    JOIN api.employees AS e ON aoeh.lead_id = e.id
    WHERE auth.is_supervisor(e.id)
    AND NOT (e.roles @> '["lead"]'::jsonb)
  LOOP
    PERFORM auth.grant_priv(lead_email, 'lead');
  END LOOP;
END;
$$ LANGUAGE plpgsql;
--- TODO: Elevate power users by making a record in the database so that their permissions can be recreated
```
- `exit`
- `exit`
- `docker compose up -d`
- `exit`
- `exit`
- Perform sanity check at:
  - Staging: https://dtrack-staging.rethinkcode.org
  - Prod: https://dtrack.rethinkcode.org
