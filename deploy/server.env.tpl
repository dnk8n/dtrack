# Server .env for the pull-based single-server stack (compose.server.yaml).
# Copy to the checkout root as .env, fill in every value, then: chmod 600 .env
# Setup steps: docs/deployment.md.

# Makes plain `docker compose ...` (and initdb.sh, rotate-keys.sh) use the
# server stack.
COMPOSE_FILE=compose.server.yaml

# Images published by .github/workflows/images.yml. Pin a commit tag
# (sha-<7 chars>) that matches the checked-out commit; see "Updating".
IMAGE_OWNER=dnk8n
IMAGE_TAG=sha-0000000

# Public hostname (DNS A/AAAA record pointing at this server) and the
# Let's Encrypt account contact.
HOST=dtrack.example.com
ACME_EMAIL=ops@example.com

# Microsoft Entra ID (docs/runbooks/new-tenant.md). Tenant ID is the GUID.
AZURE_TENANT_ID=
AZURE_CLIENT_ID=
# First power user, exactly as their UPN (applied by initdb.sh only).
POSTGRES_USER_APP_POWER=

# Postgres. Generate each password with: openssl rand -hex 24
POSTGRES_DB=postgres
POSTGRES_USER=postgres
POSTGRES_PASSWORD=
POSTGRES_DB_APP=dtrack
POSTGRES_USER_APP=authenticator
POSTGRES_PASSWORD_APP=
POSTGRES_USER_APP_ADMIN=admin
POSTGRES_PASSWORD_APP_ADMIN=

# PostgREST (leave as is)
PGRST_DB_ANON_ROLE=anon
PGRST_JWT_ROLE_CLAIM_KEY=.preferred_username

# Optional UI colours
PALETTE_PRIMARY=#330808
PALETTE_SECONDARY=#A32122
