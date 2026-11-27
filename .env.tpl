# Variables for docker-compose.override.yaml
TRAEFIK_BASICAUTH=  # htpasswd -bnBC 10 "" xyz | tr -d ':\n'
HOST=dtrack.example.com
# Let's Encrypt contact for the TLS-ALPN challenge (prod, staging-demo overrides)
ACME_EMAIL=an@example.com
# DNS challenge via Cloudflare (staging override only)
ACME_PROVIDER=cloudflare
CF_API_EMAIL=an@example.com
CF_API_KEY=dummy
# Initial privileged Postgres DB and superuser credentials
POSTGRES_DB=postgres
POSTGRES_USER=postgres
POSTGRES_PASSWORD=dummy
# Passwords of the app's two login roles: authenticator (PostgREST) and
# admin (owns the schema, runs migrations). The role and database names
# (authenticator, admin, dtrack) are fixed.
POSTGRES_PASSWORD_APP=dummy
POSTGRES_PASSWORD_APP_ADMIN=dummy
# Local power user: `make initdb` and the test suites pass it to power-user.sh
POSTGRES_USER_APP_POWER=Dummy.User@example.com
# Azure Creds
AZURE_TENANT_ID=dummy
AZURE_CLIENT_ID=dummy
# PostgREST settings
PGRST_DB_ANON_ROLE=anon
PGRST_JWT_ROLE_CLAIM_KEY=.preferred_username
# React Admin settings
PALETTE_PRIMARY=#330808
PALETTE_SECONDARY=#A32122
