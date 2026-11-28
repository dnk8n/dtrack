#!/usr/bin/env bash
# Install or upgrade the DTrack server files from this release bundle.
#
#   sudo ./install.sh [--dir /opt/dtrack]
#
# Places only configuration; it never starts, stops or changes containers or
# data. Steps: docs/runbooks/server-install.md (in the repository, at the tag
# in ./VERSION).
#
# First install (no <dir>/.env yet):
#   - <dir>/.env (600) from env.tpl, with generated database passwords and
#     your values. Values come from the environment if set, else prompts:
#     HOST, ACME_EMAIL, AZURE_TENANT_ID, AZURE_CLIENT_ID, BACKUP_DIR,
#     BACKUP_GROUP (created as a system group if missing).
#   - <dir>/acme/acme.json (600), the backup directory (750, group BACKUP_GROUP).
# Every run (install and upgrade):
#   - <dir>/compose.yaml (the previous one is kept as compose.yaml.previous),
#     <dir>/VERSION, and /etc/cron.d/dtrack.
#   - An existing .env is never overwritten: settings new in this release are
#     appended with their template values, and listed so you can review them.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dir=/opt/dtrack

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            dir="${2:?--dir needs a path}"
            shift 2
            ;;
        -h | --help)
            sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1 (try --help)" >&2
            exit 2
            ;;
    esac
done

die() {
    echo "install.sh: $*" >&2
    exit 1
}

[[ "$(id -u)" == 0 ]] || die "run as root (sudo ./install.sh)"
[[ "$dir" == /* ]] || die "--dir must be an absolute path"
for f in compose.yaml env.tpl cron VERSION; do
    [[ -f "$here/$f" ]] || die "$here/$f missing: run install.sh from an extracted release bundle"
done
command -v docker >/dev/null || die "Docker is not installed (see the install guide, stage 1)"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is not installed"
command -v openssl >/dev/null || die "openssl is not installed"

version="$(cat "$here/VERSION")"
echo "--> Installing DTrack $version into $dir"

# Ask for a value unless it is already in the environment.
ask() {
    local var="$1" prompt="$2" default="${3:-}" value="${!1:-}"
    if [[ -z "$value" ]]; then
        [[ -t 0 ]] || die "$var is not set and there is no terminal to ask on"
        read -r -p "$prompt${default:+ [$default]}: " value
        value="${value:-$default}"
    fi
    [[ -n "$value" ]] || die "$var is required"
    [[ "$value" != *"|"* && "$value" != *$'\n'* ]] || die "$var contains an unsupported character"
    printf -v "$var" '%s' "$value"
}

set_env() { # set_env FILE KEY VALUE
    local v="${3//\\/\\\\}"
    v="${v//&/\\&}"
    sed -i "s|^$2=.*|$2=$v|" "$1"
}

install -d -m 750 "$dir"

if [[ -f "$dir/.env" ]]; then
    echo "--> Keeping existing $dir/.env"
    added=()
    while IFS= read -r line; do
        key="${line%%=*}"
        if ! grep -q "^$key=" "$dir/.env"; then
            printf '%s\n' "$line" >>"$dir/.env"
            added+=("$key")
        fi
    done < <(grep -E '^[A-Z_]+=' "$here/env.tpl")
    if [[ ${#added[@]} -gt 0 ]]; then
        echo "    Added settings new in $version (review them): ${added[*]}"
    fi
    chmod 600 "$dir/.env"
else
    ask HOST "Public hostname (DNS points at this server)"
    ask ACME_EMAIL "Let's Encrypt contact email"
    ask AZURE_TENANT_ID "Entra ID directory (tenant) ID, the GUID"
    ask AZURE_CLIENT_ID "Entra ID application (client) ID"
    ask BACKUP_DIR "Backup directory" /var/backups/dtrack
    ask BACKUP_GROUP "Group that may read backups" dtrack-backup
    [[ "$AZURE_TENANT_ID" =~ ^[0-9a-fA-F-]{36}$ ]] ||
        die "AZURE_TENANT_ID must be the tenant GUID, not a domain name"
    [[ "$BACKUP_DIR" == /* ]] || die "BACKUP_DIR must be an absolute path"

    getent group "$BACKUP_GROUP" >/dev/null || {
        echo "--> Creating system group $BACKUP_GROUP"
        groupadd --system "$BACKUP_GROUP"
    }
    backup_gid="$(getent group "$BACKUP_GROUP" | cut -d: -f3)"

    echo "--> Writing $dir/.env"
    tmp="$(mktemp "$dir/.env.XXXXXX")"
    chmod 600 "$tmp"
    cp "$here/env.tpl" "$tmp"
    set_env "$tmp" HOST "$HOST"
    set_env "$tmp" ACME_EMAIL "$ACME_EMAIL"
    set_env "$tmp" AZURE_TENANT_ID "$AZURE_TENANT_ID"
    set_env "$tmp" AZURE_CLIENT_ID "$AZURE_CLIENT_ID"
    set_env "$tmp" POSTGRES_PASSWORD "$(openssl rand -hex 24)"
    set_env "$tmp" POSTGRES_PASSWORD_APP "$(openssl rand -hex 24)"
    set_env "$tmp" POSTGRES_PASSWORD_APP_ADMIN "$(openssl rand -hex 24)"
    set_env "$tmp" BACKUP_DIR "$BACKUP_DIR"
    set_env "$tmp" BACKUP_GID "$backup_gid"
    mv "$tmp" "$dir/.env"

    echo "--> Creating $BACKUP_DIR (group $BACKUP_GROUP)"
    install -d -m 750 -o root -g "$backup_gid" "$BACKUP_DIR"
fi

# Let's Encrypt account and certificate store (Traefik requires mode 600).
install -d -m 700 "$dir/acme"
[[ -f "$dir/acme/acme.json" ]] || install -m 600 /dev/null "$dir/acme/acme.json"

if [[ -f "$dir/compose.yaml" ]] && ! cmp -s "$here/compose.yaml" "$dir/compose.yaml"; then
    cp -p "$dir/compose.yaml" "$dir/compose.yaml.previous"
    echo "--> Previous compose.yaml kept as compose.yaml.previous"
fi
install -m 644 "$here/compose.yaml" "$dir/compose.yaml"
install -m 644 "$here/VERSION" "$dir/VERSION"

echo "--> Installing /etc/cron.d/dtrack"
sed "s|@DIR@|$dir|g" "$here/cron" | install -m 644 /dev/stdin /etc/cron.d/dtrack

(cd "$dir" && docker compose config --quiet) || die "docker compose rejected $dir/compose.yaml with this .env"

cat <<EOF

DTrack $version files are in place. Nothing has been started or changed.
Next, as root in $dir (see the install guide):

  docker compose --profile tools pull         # this release's images
  docker compose run --rm ops backup          # upgrades only: a backup first
  docker compose run --rm ops init            # create or migrate the database
  docker compose up -d                        # start, or restart on new images
EOF
