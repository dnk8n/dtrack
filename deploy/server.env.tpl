# Server .env for the pull-based single-server stack (compose.server.yaml).
# Copy to the checkout root as .env, fill in every value, then: chmod 600 .env
# Setup steps: docs/runbooks/server-install.md.

# Makes plain `docker compose ...` (and initdb.sh, power-user.sh,
# rotate-keys.sh) use the server stack.
COMPOSE_FILE=compose.server.yaml

# Images published by .github/workflows/images.yml. Pin the release version
# (X.Y.Z, without the "v") matching the checked-out vX.Y.Z tag; a commit tag
# (sha-<7 chars>) also works for unreleased builds. See "Updating to a new
# release" in the setup steps.
IMAGE_OWNER=dnk8n
IMAGE_TAG=0.0.0

# Public hostname (DNS A/AAAA record pointing at this server) and the
# Let's Encrypt account contact.
HOST=dtrack.example.com
ACME_EMAIL=ops@example.com

# Microsoft Entra ID (docs/runbooks/new-tenant.md). Tenant ID is the GUID.
AZURE_TENANT_ID=
AZURE_CLIENT_ID=

# Postgres. Generate each password with: openssl rand -hex 24
# POSTGRES_PASSWORD is the superuser's; POSTGRES_PASSWORD_APP is the
# authenticator role's (PostgREST); POSTGRES_PASSWORD_APP_ADMIN is the admin
# role's (owns the schema, runs migrations). initdb.sh applies the last two
# on every run.
POSTGRES_DB=postgres
POSTGRES_USER=postgres
POSTGRES_PASSWORD=
POSTGRES_PASSWORD_APP=
POSTGRES_PASSWORD_APP_ADMIN=

# Nightly backups (deploy/backup-db.sh, run from /etc/cron.d/dtrack): where
# they go, the group that may read them (the backup pull account joins it) and
# how many days are kept.
BACKUP_DIR=/var/backups/dtrack
BACKUP_GROUP=dtrack-backup
RETAIN_DAYS=7

# PostgREST (leave as is)
PGRST_DB_ANON_ROLE=anon
PGRST_JWT_ROLE_CLAIM_KEY=.preferred_username

# Optional UI colours
PALETTE_PRIMARY=#330808
PALETTE_SECONDARY=#A32122
