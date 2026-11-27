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
umask 077

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
    # Overwrite in place rather than mv: PostgREST bind-mounts this single
    # file, which pins its inode, so a replaced file would never reach the
    # running container (#69). Writing in place also keeps the file's owner
    # and mode (e.g. 600 owned by the PostgREST container user).
    cat keys/jwt-secret.new >keys/jwt-secret
    rm -f keys/jwt-secret.new
    docker compose kill -s SIGUSR2 postgrest
fi
