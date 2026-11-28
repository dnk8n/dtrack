# Single-server install, step by step

How to install DTrack by hand on one Linux server, from a bare machine to a
working, backed-up installation. Every stage ends with a **Check** you run
before moving on, so a problem shows up in the stage that caused it.

The server pulls published images and never builds anything. CI never
connects to the server: you decide when a release goes on it. The stack is
[compose.server.yaml](../../compose.server.yaml).

The guide has three parts, done in this order:

- **Part A, install with a test tenant (stages 0–12).** Prove the whole
  stack, sign-in included, against a throwaway Entra ID tenant with test
  users, so nothing real is at stake while you shake out DNS, TLS, firewalls
  and backups.
- **Part B, switch to the real tenant (stage 13).** Swap two values in `.env`.
- **Part C, restore production data (stage 14),** if you are moving an
  existing installation.

[Updating to a new release](#updating-to-a-new-release),
[day-to-day operations](#day-to-day-operations) and
[troubleshooting](#troubleshooting) follow at the end.

## What you end up with

```
Internet ──80/443──▶ Traefik ──▶ react-admin (UI)        https://HOST/
                    (only        ├▶ postgrest (API)       https://HOST/api
                    published    └▶ swagger               https://HOST/swagger
                    ports)            │
                                      ▼  backend network, no published ports
                                   postgres ──HTTPS──▶ login.microsoftonline.com
```

- Traefik is the only container with published ports (80 and 443). Docker
  publishes ports past ufw, so nothing else has a `ports:` entry. Postgres and
  the API are reachable only on Docker's internal networks.
- One Let's Encrypt certificate for `HOST`, through the HTTP-01 challenge on
  port 80. No wildcard, no DNS provider, no second hostname, no Traefik
  dashboard.
- Every container logs to `json-file` with rotation (10 MB × 5 files), so logs
  can't fill the disk.
- Cron on the server takes a nightly database backup (kept 7 days, readable
  by a backup group) and refreshes Microsoft's signing keys every 6 hours.
- Everything lives in one directory (`APP_DIR`, a checkout of the release
  tag): compose file, `.env`, `keys/`, `acme/` and the scripts. Secrets are
  mode 600.

## Requirements

| What | Minimum / value |
| --- | --- |
| OS | Ubuntu 24.04 or 26.04 LTS (any recent Linux with Docker works, commands here are Ubuntu's) |
| Size | 2 vCPU, 4 GB RAM, 20 GB free disk (more for backups and audit history) |
| DNS | An A (and AAAA, if the server has IPv6) record for `HOST` pointing at the server, **before** stage 9 |
| Inbound | TCP 80 and 443 from the internet (80 is needed for the certificate and redirects to 443) |
| Outbound | DNS, NTP, HTTP and HTTPS. The hosts used: `github.com` (the checkout), `ghcr.io` and `pkg-containers.githubusercontent.com` (DTrack images), `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` (Traefik, PostgREST, Swagger, dbmate images), `download.docker.com` (Docker packages), `acme-v02.api.letsencrypt.org` (certificate), `login.microsoftonline.com` (sign-in keys, and onboarding from inside the Postgres container) |
| Access | A shell on the server with `sudo` |

Nothing here needs ufw, fail2ban or automatic security updates turned off.
Leave them as they are.

## Values you need before you start

Collect these first. Examples are placeholders; use your own.

| Name | Example | Where it comes from |
| --- | --- | --- |
| `RELEASE` | `v0.1.0` | The release to install: `https://github.com/<owner>/dtrack/releases` |
| `REPO` | `https://github.com/dnk8n/dtrack.git` | The repository whose CI publishes the images |
| `IMAGE_OWNER` | `dnk8n` | The GitHub owner in `ghcr.io/<owner>/dtrack-postgres` |
| `APP_DIR` | `/opt/dtrack` | Where the installation lives (any fixed path) |
| `HOST` | `dtrack.example.org` | The public hostname |
| `ACME_EMAIL` | `ops@example.org` | Let's Encrypt account contact (expiry warnings) |
| `AZURE_TENANT_ID` | `00000000-0000-0000-0000-000000000000` | Test tenant's **Directory (tenant) ID**, the GUID, never the domain |
| `AZURE_CLIENT_ID` | `11111111-1111-1111-1111-111111111111` | Test app registration's **Application (client) ID** |
| `ADMIN_UPN` | `app.admin@example.onmicrosoft.com` | The test tenant's first administrator, exactly as their user principal name |
| `BACKUP_DIR` | `/var/backups/dtrack` | Where nightly backups go |
| `BACKUP_GROUP` | `dtrack-backup` | Group that may read backups |
| `BACKUP_ACCOUNT` | `backup-pull` | The existing account that copies backups off the server |

The test tenant, app registration and users come from
[new-tenant.md](new-tenant.md) sections 1–3. Add
`https://<HOST>/auth-callback` as a **Single-page application** redirect URI
on the app registration now; Entra rejects sign-in from any URI not listed.

## How to run the commands

Do the whole install in one root shell, so the variables below stay set and
no command needs `sudo` in front of it:

```sh
sudo -i
```

Then paste your values (this block is the only one you edit):

```sh
RELEASE=v0.1.0
REPO=https://github.com/dnk8n/dtrack.git
IMAGE_OWNER=dnk8n
APP_DIR=/opt/dtrack
HOST=dtrack.example.org
ACME_EMAIL=ops@example.org
AZURE_TENANT_ID=00000000-0000-0000-0000-000000000000
AZURE_CLIENT_ID=11111111-1111-1111-1111-111111111111
ADMIN_UPN=app.admin@example.onmicrosoft.com
BACKUP_DIR=/var/backups/dtrack
BACKUP_GROUP=dtrack-backup
BACKUP_ACCOUNT=backup-pull
```

If you lose the shell part-way, `sudo -i`, paste the block again and carry on
from the stage you were in. From stage 4 on, `.env` holds most of these:
`cd "$APP_DIR" && set -a && . ./.env && set +a` loads them.

---

# Part A: install with a test tenant

## Stage 0: check the server

Confirm the baseline before changing anything, so you know what "normal" looks
like.

```sh
. /etc/os-release && echo "$PRETTY_NAME"
nproc; free -h; df -h /
ufw status verbose | head -5
systemctl is-active fail2ban unattended-upgrades
timedatectl | grep -E 'synchronized|NTP'
```

Outbound reachability of every host the install uses:

```sh
for h in github.com ghcr.io pkg-containers.githubusercontent.com registry-1.docker.io download.docker.com \
         acme-v02.api.letsencrypt.org login.microsoftonline.com; do
  printf '%-32s ' "$h"; curl -sS -o /dev/null -m 10 -w '%{http_code}\n' "https://$h/" || true
done
```

The tenant and DNS:

```sh
curl -s "https://login.microsoftonline.com/$AZURE_TENANT_ID/v2.0/.well-known/openid-configuration" \
  | grep -o '"issuer":"[^"]*"'
getent ahosts "$HOST" | head -2
curl -s -4 https://ifconfig.co || ip -4 addr show scope global
```

**Check:**

- [ ] ufw is `active`, fail2ban and unattended-upgrades are `active`, and the
      clock is `synchronized: yes`. Note the ufw rules; they must be the same
      at the end.
- [ ] Every host prints an HTTP code (any code, 200, 301, 404 and 405 all
      mean the connection worked). A timeout or `Could not resolve` means the
      outbound firewall or DNS needs fixing first.
- [ ] The issuer is `https://login.microsoftonline.com/<AZURE_TENANT_ID>/v2.0`.
- [ ] `HOST` resolves to this server's public address. If it doesn't yet, you
      can continue to stage 8 and must fix it before stage 9.

## Stage 1: install Docker, with log rotation

Install Docker Engine and the compose plugin from Docker's apt repository
([docs.docker.com/engine/install/ubuntu](https://docs.docker.com/engine/install/ubuntu/)):

```sh
apt-get update
apt-get install -y ca-certificates curl git openssl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-cache policy docker-ce | head -3
```

If `Candidate:` is `(none)`, Docker hasn't published packages for this Ubuntu
release yet. Use Ubuntu's own packages instead, which automatic security
updates then also cover:

```sh
rm /etc/apt/sources.list.d/docker.sources && apt-get update
apt-get install -y docker.io docker-compose-v2
```

Otherwise install Docker's packages:

```sh
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Then set default log rotation for every container (the compose file also sets
it per service) and restart Docker:

```sh
cat >/etc/docker/daemon.json <<'JSON'
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "5" } }
JSON
systemctl restart docker
systemctl enable docker
```

**Check:**

```sh
docker version --format 'engine {{.Server.Version}}'
docker compose version
docker info --format '{{.LoggingDriver}} {{.Driver}}'
docker run --rm hello-world | grep -m1 Hello
ufw status | head -1; systemctl is-active fail2ban
```

- [ ] Engine and compose versions print; logging driver is `json-file`.
- [ ] `Hello from Docker!` (Docker Hub pulls work).
- [ ] ufw is still `active` and fail2ban `active`. `ufw status` won't list 80
      and 443: Docker opens published ports in its own chains, which is
      exactly why only Traefik publishes any.

## Stage 2: stop containers reaching internal networks

Containers need the internet (Microsoft sign-in, Let's Encrypt) but should
never reach your organisation's internal network. Docker sends container
traffic through the `DOCKER-USER` iptables chain before its own rules, so
the block goes there. If your organisation supplies its own rule, use that
and skip to the check.

One way to do it, applied every time Docker starts. Set `UPLINK` to the
interface the server reaches the internet through (`ip route get 1.1.1.1`
prints it after `dev`), `BLOCK` to your internal ranges, and `ALLOW_DNS` to
internal DNS resolvers containers may use (leave it empty if the server uses
public resolvers):

```sh
ip route get 1.1.1.1 | grep -o 'dev [^ ]*'
cat /run/systemd/resolve/resolv.conf 2>/dev/null | grep ^nameserver || grep ^nameserver /etc/resolv.conf

install -m 755 /dev/stdin /usr/local/sbin/docker-egress-block <<'SH'
#!/bin/sh
# Stop containers opening connections to internal networks (DNS excepted).
# Applied by docker-egress-block.service whenever Docker starts.
set -eu
UPLINK=eth0                                       # internet-facing interface
BLOCK="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"   # internal ranges to block
ALLOW_DNS=""                                      # internal DNS resolvers, space-separated

iptables -N DOCKER-USER 2>/dev/null || true
iptables -F DOCKER-USER
for dns in $ALLOW_DNS; do
    iptables -A DOCKER-USER -o "$UPLINK" -d "$dns" -p udp --dport 53 -j RETURN
    iptables -A DOCKER-USER -o "$UPLINK" -d "$dns" -p tcp --dport 53 -j RETURN
done
for net in $BLOCK; do
    iptables -A DOCKER-USER -o "$UPLINK" -d "$net" -j DROP
done
SH
editor /usr/local/sbin/docker-egress-block      # set UPLINK, BLOCK, ALLOW_DNS

cat >/etc/systemd/system/docker-egress-block.service <<'UNIT'
[Unit]
Description=Stop containers reaching internal networks
After=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/docker-egress-block

[Install]
WantedBy=docker.service
UNIT
systemctl daemon-reload
systemctl enable --now docker-egress-block
```

Matching on `-o UPLINK` blocks only traffic leaving the server, so Docker's
own networks (also in 172.16.0.0/12) keep working. This assumes Docker's
default iptables firewall backend.

**Check** (replace `10.1.2.3` with an internal address that normally answers):

```sh
iptables -S DOCKER-USER
docker run --rm busybox nslookup login.microsoftonline.com | tail -2
docker run --rm curlimages/curl:8.11.1 -sS -m 10 -o /dev/null -w '%{http_code}\n' https://login.microsoftonline.com/
docker run --rm curlimages/curl:8.11.1 -sS -m 5 http://10.1.2.3/ ; echo "exit $?"
```

- [ ] The chain lists your `DROP` rules (and DNS `RETURN` rules if any).
- [ ] The name resolves and Microsoft answers with an HTTP code.
- [ ] The internal address times out (`exit 28`).

## Stage 3: fetch the release

```sh
git clone "$REPO" "$APP_DIR"
cd "$APP_DIR"
git checkout "$RELEASE"
```

The checkout supplies the compose file, `initdb.sh`, the bootstrap SQL and
migrations, `power-user.sh`, `rotate-keys.sh` and the backup script. The
images supply everything that runs. Always check out the same tag the images
come from.

**Check:**

```sh
git describe --tags
docker manifest inspect "ghcr.io/$IMAGE_OWNER/dtrack-postgres:${RELEASE#v}" >/dev/null && echo postgres image OK
docker manifest inspect "ghcr.io/$IMAGE_OWNER/dtrack-ui:${RELEASE#v}" >/dev/null && echo ui image OK
```

- [ ] `git describe` prints the release tag exactly.
- [ ] Both images are found without `docker login` (they are public and hold
      no secrets). If not, the release's `images` workflow hasn't finished,
      or the packages aren't public yet (see [Publishing images](#publishing-images)).

## Stage 4: configuration and secrets

`.env` is created from [deploy/server.env.tpl](../../deploy/server.env.tpl),
your values are filled in and the three database passwords are generated:

```sh
cd "$APP_DIR"
install -m 600 deploy/server.env.tpl .env
# Templates up to v0.1.0 lack the backup settings; add them if missing.
grep -q '^BACKUP_DIR=' .env || printf '\nBACKUP_DIR=\nBACKUP_GROUP=\nRETAIN_DAYS=7\n' >>.env
sed -i \
  -e "s|^IMAGE_OWNER=.*|IMAGE_OWNER=$IMAGE_OWNER|" \
  -e "s|^IMAGE_TAG=.*|IMAGE_TAG=${RELEASE#v}|" \
  -e "s|^HOST=.*|HOST=$HOST|" \
  -e "s|^ACME_EMAIL=.*|ACME_EMAIL=$ACME_EMAIL|" \
  -e "s|^AZURE_TENANT_ID=.*|AZURE_TENANT_ID=$AZURE_TENANT_ID|" \
  -e "s|^AZURE_CLIENT_ID=.*|AZURE_CLIENT_ID=$AZURE_CLIENT_ID|" \
  -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(openssl rand -hex 24)|" \
  -e "s|^POSTGRES_PASSWORD_APP=.*|POSTGRES_PASSWORD_APP=$(openssl rand -hex 24)|" \
  -e "s|^POSTGRES_PASSWORD_APP_ADMIN=.*|POSTGRES_PASSWORD_APP_ADMIN=$(openssl rand -hex 24)|" \
  -e "s|^BACKUP_DIR=.*|BACKUP_DIR=$BACKUP_DIR|" \
  -e "s|^BACKUP_GROUP=.*|BACKUP_GROUP=$BACKUP_GROUP|" \
  .env
```

The certificate store (Traefik refuses an `acme.json` that isn't mode 600):

```sh
install -d -m 700 acme
install -m 600 /dev/null acme/acme.json
```

The signing-key file PostgREST reads, owned by the user PostgREST runs as
inside its container so it can stay mode 600:

```sh
PGRST_IMAGE=$(docker compose config --images | grep postgrest)
docker pull -q "$PGRST_IMAGE" >/dev/null
uid=$(docker image inspect -f '{{.Config.User}}' "$PGRST_IMAGE"); echo "postgrest runs as: ${uid:-root}"
install -d -m 711 keys
install -m 600 -o "${uid:-0}" /dev/null keys/jwt-secret
```

**Check:**

```sh
grep -E '^[A-Z_]+=$' .env || echo "no empty values"
grep -E '^(COMPOSE_FILE|IMAGE_|HOST|ACME_EMAIL|AZURE_|BACKUP_)' .env
stat -c '%a %U %n' .env acme acme/acme.json keys keys/jwt-secret
docker compose config --quiet && echo "compose config OK"
```

- [ ] `no empty values`, and the printed lines show your values, with
      `IMAGE_TAG` lacking the leading `v`.
- [ ] Modes: `.env` 600, `acme` 700, `acme/acme.json` 600, `keys` 711,
      `keys/jwt-secret` 600 owned by the PostgREST user.
- [ ] `compose config OK`. Because `.env` sets
      `COMPOSE_FILE=compose.server.yaml`, a plain `docker compose` in
      `APP_DIR` always means the server stack.

Keep a copy of `.env` somewhere safe off the server (a password manager).
Without it you can't read a backup back into a rebuilt server with the same
passwords, though you can always generate new ones.

## Stage 5: download the tenant's signing keys

```sh
cd "$APP_DIR"
./rotate-keys.sh
```

It prints a diff (empty file → keys) the first time. It may also print
`No container to kill`, since PostgREST isn't running yet; that's fine.

**Check:**

```sh
stat -c '%a %U %s bytes' keys/jwt-secret
grep -o '"kid":"[^"]*"' keys/jwt-secret | head -3
```

- [ ] Still mode 600 with the same owner, a few kilobytes, and some `kid`
      entries listed.

## Stage 6: create the database

```sh
cd "$APP_DIR"
docker compose pull
./initdb.sh
```

`initdb.sh` starts Postgres, bootstraps the new cluster (roles, database,
Cyan Audit), sets the two application passwords from `.env` and applies every
migration with dbmate. It never creates users. It is safe to re-run; only
`--force` deletes data.

**Check:**

```sh
docker compose run --rm migrate status
docker compose exec -T postgres psql -U postgres -d dtrack -Atc \
  "SELECT count(*) || ' tables in api/internal' FROM information_schema.tables WHERE table_schema IN ('api','internal')"
docker compose exec -T postgres python3 -c \
  "import urllib.request; print(urllib.request.urlopen('https://login.microsoftonline.com/$AZURE_TENANT_ID/v2.0/.well-known/openid-configuration', timeout=10).status)"
```

- [ ] `migrate status` lists every migration as applied (`[X]`) and
      `Pending: 0`.
- [ ] A non-zero table count.
- [ ] `200` from inside the Postgres container. Onboarding validates each new
      user's token from there, so if this fails, stage 2's rules or the
      outbound firewall are blocking it.

## Stage 7: create the first administrator

Make exactly one person a power user, the test tenant's administrator, using
their UPN exactly (case included):

```sh
cd "$APP_DIR"
./power-user.sh "$ADMIN_UPN"
```

Power is "God mode": it bypasses row-level security. Use it only to configure
users and the few things only power can create
([first-run.md](first-run.md)). Everyone else signs in and is onboarded as an
ordinary user. Skip this stage if you are about to restore a backup (Part C).

**Check:**

```sh
docker compose exec -T postgres psql -U postgres -d dtrack -c 'SELECT * FROM auth.get_user_roles();'
```

- [ ] One row: your `ADMIN_UPN` with `power`.

## Stage 8: start the stack

Make sure `HOST` already resolves to this server (stage 0); Let's Encrypt
allows only a few failed validations per hour.

```sh
cd "$APP_DIR"
docker compose up -d
sleep 30
docker compose logs traefik | grep -iE 'acme|certificate|error' | tail -5
```

## Stage 9: check TLS, routing and exposure

From the server:

```sh
docker compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
ss -tlnp | grep -vE '127\.0\.0\.|\[::1\]'
echo | openssl s_client -connect 127.0.0.1:443 -servername "$HOST" 2>/dev/null \
  | openssl x509 -noout -subject -issuer -enddate
curl -sS -o /dev/null -w 'http  %{http_code} -> %{redirect_url}\n' --resolve "$HOST:80:127.0.0.1" "http://$HOST/"
curl -sS -o /dev/null -w 'ui    %{http_code}\n' --resolve "$HOST:443:127.0.0.1" "https://$HOST/"
curl -sS -o /dev/null -w 'api   %{http_code}\n' --resolve "$HOST:443:127.0.0.1" "https://$HOST/api/"
curl -sS -o /dev/null -w 'docs  %{http_code}\n' --resolve "$HOST:443:127.0.0.1" "https://$HOST/swagger/"
curl -sS --resolve "$HOST:443:127.0.0.1" "https://$HOST/config.js"
```

And from your own computer: open `https://HOST/` and check the padlock.

**Check:**

- [ ] All five services `Up` (postgres, postgrest, react-admin, swagger,
      traefik). Only traefik shows ports: `0.0.0.0:80->80/tcp` and
      `0.0.0.0:443->443/tcp` (plus `[::]` equivalents).
- [ ] `ss` shows listeners only on 80, 443 and your SSH port. Nothing on 5432
      or 3000.
- [ ] The certificate's subject is `CN = HOST`, issued by Let's Encrypt, valid
      for about 90 days. A `TRAEFIK DEFAULT CERT` means it wasn't issued yet
      (see [troubleshooting](#troubleshooting)).
- [ ] `http 301` or `308` redirecting to `https://HOST/`, and `ui`, `api`,
      `docs` all `200`.
- [ ] `config.js` shows your client ID, `https://login.microsoftonline.com/<tenant GUID>`
      and `https://HOST` URLs.

## Stage 10: sign in with the test users

In a private browser window (MSAL caches tenant state), go through the
checklist in [new-tenant.md section 4](new-tenant.md#4-verify-locally-make-dev),
using `https://HOST` instead of `http://localhost:5174`. In short:

- [ ] The administrator signs in and sees Employees, Areas of work and
      Activities.
- [ ] A member signs in for the first time and lands as `basic` (onboarding).
- [ ] As administrator, make the lead a project lead and team supervisor; they
      gain `pm` and `lead`.
- [ ] The member sees only their own time; the lead sees theirs and the
      member's.
- [ ] Someone outside the tenant is refused by Microsoft.

Roles, from the server:

```sh
docker compose exec -T postgres psql -U postgres -d dtrack -c 'SELECT * FROM auth.get_user_roles();'
```

## Stage 11: backups and key rotation

Create the backup group, let the backup pull account read through it, and
install the cron jobs with your paths:

```sh
cd "$APP_DIR"
groupadd --system -f "$BACKUP_GROUP"
usermod -aG "$BACKUP_GROUP" "$BACKUP_ACCOUNT"
sed "s|/opt/dtrack|$APP_DIR|g" deploy/cron.d-dtrack | install -m 644 /dev/stdin /etc/cron.d/dtrack
cat /etc/cron.d/dtrack
```

[deploy/cron.d-dtrack](../../deploy/cron.d-dtrack) runs
[deploy/backup-db.sh](../../deploy/backup-db.sh) nightly at 01:15 server
time, and `rotate-keys.sh` every 6 hours, which reloads PostgREST only when
Microsoft's keys changed. The backup script reads `BACKUP_DIR`,
`BACKUP_GROUP` and `RETAIN_DAYS` from `.env`. Each backup is `dtrack-<UTC time>.tar` (mode 640,
group `BACKUP_GROUP`) holding `dtrack.dump` and `cyanaudit/`, the layout the
[restore runbook](backup-restore.md) and Part C expect. Backups older than
`RETAIN_DAYS` days (7) are deleted, but only after a successful backup.

Take the first backup now:

```sh
deploy/backup-db.sh
```

**Check:**

```sh
ls -l "$BACKUP_DIR"
tar -tf "$(ls -1t "$BACKUP_DIR"/dtrack-*.tar | head -1)" | head
sudo -u "$BACKUP_ACCOUNT" -g "$BACKUP_GROUP" head -c0 "$(ls -1t "$BACKUP_DIR"/dtrack-*.tar | head -1)" && echo "backup account can read"
./rotate-keys.sh && echo "keys unchanged or refreshed"
```

- [ ] One `dtrack-*.tar`, `-rw-r----- root BACKUP_GROUP`, in a directory with
      mode 750.
- [ ] The tarball lists `dtrack.dump` and `cyanaudit/…csv.gz` files.
- [ ] `backup account can read`. The account picks up its new group on its
      next login.
- [ ] Tomorrow: `journalctl -t dtrack-backup --since yesterday` shows
      `backup written`, and `journalctl -t dtrack-keys` shows no errors.

Copy backups off the server regularly (that's the pull account's job): a
backup that only exists on the server it protects doesn't survive losing the
server. Test a restore from one now and then
([backup-restore.md](backup-restore.md) section 2).

## Stage 12: final checks

```sh
ufw status verbose | head -5; systemctl is-active fail2ban unattended-upgrades docker docker-egress-block
df -h /; docker system df
```

- [ ] ufw, fail2ban and automatic updates are exactly as in stage 0.
- [ ] Optional but worth it: `reboot`, then confirm `docker compose ps` in
      `APP_DIR` shows everything `Up` again and `iptables -S DOCKER-USER` still
      has your rules. Automatic updates may reboot the server, and the stack
      must come back by itself (`restart: unless-stopped`).

The test installation is complete. Bring it into use following
[first-run.md](first-run.md), or move on to the real tenant.

---

# Part B: switch to the real tenant

## Stage 13: real tenant credentials

1. Register the app in the real tenant exactly as in
   [new-tenant.md section 2](new-tenant.md#2-register-the-app), with
   `https://<HOST>/auth-callback` as an SPA redirect URI. Decide on
   *Assignment required* (who may sign in) deliberately.
2. On the server, put the new IDs in `.env`, fetch the new tenant's keys and
   recreate the UI and API:

   ```sh
   sudo -i
   cd /opt/dtrack                                # your APP_DIR
   AZURE_TENANT_ID=<real tenant GUID>
   AZURE_CLIENT_ID=<real client ID>
   sed -i -e "s|^AZURE_TENANT_ID=.*|AZURE_TENANT_ID=$AZURE_TENANT_ID|" \
          -e "s|^AZURE_CLIENT_ID=.*|AZURE_CLIENT_ID=$AZURE_CLIENT_ID|" .env
   set -a; . ./.env; set +a                      # HOST etc. for the checks below
   ./rotate-keys.sh
   docker compose up -d --force-recreate postgrest react-admin
   ```

3. The test tenant's users stay in the database as roles named after their
   UPNs. If you restore production data next (Part C), the restore replaces
   them. Otherwise create the real administrator with
   `./power-user.sh <real admin UPN>`, and remove the test users from the
   Employees screen.

**Check:**

```sh
grep -E '^AZURE_' .env
curl -sS --resolve "$HOST:443:127.0.0.1" "https://$HOST/config.js"
docker compose exec -T postgres python3 -c \
  "import urllib.request; print(urllib.request.urlopen('https://login.microsoftonline.com/$AZURE_TENANT_ID/v2.0/.well-known/openid-configuration', timeout=10).status)"
```

- [ ] `.env` and `config.js` show the real tenant GUID and client ID, and the
      container gets `200`.
- [ ] In a private window, a real user signs in. Delete the test app
      registration, or the whole test tenant, once you no longer need it.

---

# Part C: restore production data

## Stage 14: restore a backup

Restoring **deletes the database on this server** and replaces it with the
backup. Backups are data-only: the schema comes from the checked-out release
(`./initdb.sh`), and the data is loaded into it. A backup restores cleanly
only into the same release it was taken from, or a later one whose
migrations don't change the shape of existing tables.

If the backup comes from an older installation (for example one that
predates this release's migrations), restore it on your own machine first
with [backup-restore.md section 2](backup-restore.md#2-test-restore), checked
out at this release. Only continue here once that works.

Put the backup on the server, either a `dtrack-*.tar` from `backup-db.sh` or
a directory holding `dtrack.dump` and `cyanaudit/`:

```sh
sudo -i
cd /opt/dtrack                                       # your APP_DIR
RESTORE=/root/restore && mkdir -p "$RESTORE"
tar -C "$RESTORE" -xf /path/to/dtrack-YYYYMMDDTHHMMSSZ.tar   # or copy the directory's contents there
ls -l "$RESTORE" "$RESTORE/cyanaudit" | head
```

Keep a copy of what's there now, then stop the app and rebuild the database
from scratch:

```sh
deploy/backup-db.sh                    # the current (test) data, just in case
docker compose stop react-admin postgrest swagger
./initdb.sh --force                    # deletes the database volume, then bootstraps and migrates
```

Load the data and the audit history:

```sh
docker compose cp "$RESTORE/dtrack.dump" postgres:/tmp/
docker compose cp "$RESTORE/cyanaudit" postgres:/tmp/
docker compose exec -T postgres pg_restore -U postgres --disable-triggers --no-owner --data-only -d dtrack /tmp/dtrack.dump
docker compose exec -T postgres sh -c \
  '/opt/cyanaudit/tools/cyanaudit_restore.pl -h localhost -U postgres -d dtrack /tmp/cyanaudit/*.csv.gz'
```

Recreate the users' roles: open a database shell and paste the SQL block
from [backup-restore.md section 3](backup-restore.md#3-live-restore) (it
fast-forwards transaction IDs past the audit history, recreates a role per
employee and re-grants `pm` and `lead`):

```sh
docker compose exec postgres psql -U admin -d dtrack
```

Power isn't carried in a backup yet, so grant it again to the real
administrator, then start everything and clean up:

```sh
./power-user.sh <real admin UPN>
docker compose up -d
docker compose exec -T postgres rm -rf /tmp/dtrack.dump /tmp/cyanaudit
rm -rf "$RESTORE"
```

**Check:**

```sh
docker compose exec -T postgres psql -U postgres -d dtrack -c 'SELECT * FROM auth.get_user_roles();' | head -20
docker compose exec -T postgres psql -U postgres -d dtrack -Atc 'SELECT count(*) FROM api.employees'
deploy/backup-db.sh                    # the first backup of the restored data
```

- [ ] The expected users are listed with their roles, and the employee count
      matches the old installation.
- [ ] Users sign in and see their history; spot-check a few people's time
      entries against the old system.
- [ ] A fresh backup is written.

---

# Updating to a new release

```sh
sudo -i
cd /opt/dtrack                                       # your APP_DIR
RELEASE=vX.Y.Z
git fetch --tags && git checkout "$RELEASE"
sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${RELEASE#v}|" .env
diff <(grep -oE '^[A-Z_]+=' deploy/server.env.tpl) <(grep -oE '^[A-Z_]+=' .env)   # new settings?
docker compose pull
deploy/backup-db.sh                                  # a fresh backup before migrating
./initdb.sh                                          # applies pending migrations (no-op if none)
docker compose up -d
docker image prune -f                                # remove the previous images
```

Read the release notes first. If the `diff` lists a setting missing from your
`.env`, add it. Migrations run while the old API keeps serving, and each runs
in a transaction, so a failed migration changes nothing: go back to the
previous tag and `IMAGE_TAG` and investigate. For a migration that rewrites
large tables, stop `postgrest` and `react-admin` before `./initdb.sh`.

**Check:** stage 6's `migrate status` shows `Pending: 0`, stage 9's checks
pass, and `git describe --tags` matches `IMAGE_TAG`.

# Day-to-day operations

Everything is run from `APP_DIR` as root.

| Task | Command |
| --- | --- |
| Status | `docker compose ps` |
| Logs | `docker compose logs --tail 100 -f <service>` |
| Restart one service | `docker compose restart <service>` |
| Database shell | `docker compose exec postgres psql -U admin -d dtrack` |
| Backup now | `deploy/backup-db.sh` |
| Backup and key job logs | `journalctl -t dtrack-backup`, `journalctl -t dtrack-keys` |
| Disk | `df -h /`, `docker system df`, `du -sh "$BACKUP_DIR"` |
| Certificate expiry | `echo \| openssl s_client -connect 127.0.0.1:443 -servername HOST 2>/dev/null \| openssl x509 -noout -enddate` (Traefik renews 30 days before) |

Files that matter, all under `APP_DIR` unless noted:

| Path | What | Mode |
| --- | --- | --- |
| `.env` | All settings and database passwords | 600 |
| `keys/jwt-secret` | Microsoft's public signing keys (refreshed by cron) | 600 |
| `acme/acme.json` | Let's Encrypt account key and certificate | 600 |
| `/etc/cron.d/dtrack` | Backup and key rotation schedule | 644 |
| `BACKUP_DIR` | Nightly backups, 7 days | 750 / 640 |
| `/usr/local/sbin/docker-egress-block` | Container egress rules (stage 2) | 755 |

Leave the repository's GitHub Actions `backup.yml` and `rotate-keys.yml`
unconfigured for this server (no `PROD_HOST` variable): they push from CI over
SSH, which this setup replaces with cron.

## Publishing images

Releases are published by CI: pushing a `vX.Y.Z` tag makes the
[images workflow](../../.github/workflows/images.yml) publish
`ghcr.io/<owner>/dtrack-postgres` and `ghcr.io/<owner>/dtrack-ui` as
`X.Y.Z`, `X.Y` and `sha-<7 chars>`; each push to `main` publishes `main`,
`latest` and `sha-<7 chars>`. The images hold no secrets or settings. In a
new fork, make both packages public once after the first run
(`https://github.com/users/<owner>/packages/container/<package>/settings` →
*Change visibility* → *Public*), or `docker login ghcr.io` on the server with
a read-only token.

# Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Browser shows `TRAEFIK DEFAULT CERT` / certificate warning | Let's Encrypt couldn't validate. `docker compose logs traefik \| grep -i acme`. Usually `HOST` doesn't resolve to this server yet, port 80 isn't reachable from the internet, or `acme/acme.json` isn't mode 600. Fix it, then `docker compose restart traefik`. After 5 failures in an hour Let's Encrypt pauses that hostname for an hour. |
| `404 page not found` (plain text) | Traefik has no route for the name you used: you browsed to an IP or another name, or `HOST` in `.env` is wrong. |
| `502 Bad Gateway` on `/api` | PostgREST is down or can't reach Postgres: `docker compose logs postgrest`. A wrong `POSTGRES_PASSWORD_APP` is fixed by re-running `./initdb.sh`, which resets it from `.env`. |
| UI container restarting, log says `missing required environment` | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` or `HOST` is empty in `.env`. |
| `manifest unknown` on `docker compose pull` | `IMAGE_TAG` has a leading `v`, or that release's images aren't published yet. |
| Sign-in errors starting `AADSTS` | See [new-tenant.md troubleshooting](new-tenant.md#troubleshooting). `AADSTS50011` means `https://HOST/auth-callback` isn't on the app registration. |
| Sign-in works but the user is never created | Onboarding couldn't reach Microsoft from inside Postgres (stage 6's check), often stage 2's rules or the outbound firewall. `docker compose logs postgres \| grep -i onboard`. |
| API answers `JWSError` / `JWT invalid` | `keys/jwt-secret` doesn't hold the current tenant's keys: `./rotate-keys.sh`. |
| Disk filling | `docker system df` (old images: `docker image prune -f`), `du -sh "$BACKUP_DIR"`, `journalctl --disk-usage`. Container logs are capped at 50 MB each. |
