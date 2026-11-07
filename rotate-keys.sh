#!/usr/bin/env bash
# Refresh the Azure AD JWKS that PostgREST uses as its JWT secret, and HUP
# PostgREST if it changed. Fails hard on download errors so a transient
# outage can never install an empty or partial key file.
set -euo pipefail
cd "$(dirname "$0")"

set -a
# shellcheck source=/dev/null
source .env
set +a

mkdir -p keys

URL="https://login.microsoftonline.com/${AZURE_TENANT_ID}/discovery/v2.0/keys"
curl --silent --show-error --fail "${URL}" >keys/jwt-secret.new

# A JWKS is a JSON object with a non-empty "keys" array; refuse anything else.
if ! grep -q '"keys"' keys/jwt-secret.new; then
    echo "Downloaded file does not look like a JWKS; keeping the existing secret." >&2
    rm -f keys/jwt-secret.new
    exit 1
fi

touch keys/jwt-secret
if diff_output="$(diff -u keys/jwt-secret keys/jwt-secret.new)"; then
    rm -f keys/jwt-secret.new
else
    echo "${diff_output}"
    mv keys/jwt-secret.new keys/jwt-secret
    docker compose kill -s SIGUSR2 postgrest
fi
