# DTrack server settings, read by compose.yaml in the same directory.
# install.sh creates this file (mode 600) from the release bundle's copy of
# this template and fills it in; it never overwrites an existing .env.
# Setup steps: docs/runbooks/server-install.md.

# Public hostname (DNS A/AAAA record pointing at this server) and the
# Let's Encrypt account contact.
HOST=dtrack.example.com
ACME_EMAIL=ops@example.com

# Microsoft Entra ID (docs/runbooks/new-tenant.md). Tenant ID is the GUID.
AZURE_TENANT_ID=
AZURE_CLIENT_ID=

# Postgres. install.sh generates each password (openssl rand -hex 24).
# POSTGRES_PASSWORD is the superuser's; POSTGRES_PASSWORD_APP is the
# authenticator role's (PostgREST); POSTGRES_PASSWORD_APP_ADMIN is the admin
# role's (owns the schema, runs migrations). `ops init` applies the last two
# on every run.
POSTGRES_DB=postgres
POSTGRES_USER=postgres
POSTGRES_PASSWORD=
POSTGRES_PASSWORD_APP=
POSTGRES_PASSWORD_APP_ADMIN=

# Nightly backups (`ops backup`, from the cron file): the host directory they
# go to, the numeric ID of the group that may read them (the backup pull
# account's group; install.sh looks it up), and how many days are kept.
BACKUP_DIR=/var/backups/dtrack
BACKUP_GID=
RETAIN_DAYS=7

# PostgREST (leave as is)
PGRST_DB_ANON_ROLE=anon
PGRST_JWT_ROLE_CLAIM_KEY=.preferred_username

# Optional UI colours
PALETTE_PRIMARY=#330808
PALETTE_SECONDARY=#A32122
