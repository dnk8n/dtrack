# Single-server install, step by step

How to install DTrack by hand on one Linux server, from a bare machine to a
working, backed-up installation. Every stage ends with a **Check** you run
before moving on, so a problem shows up in the stage that caused it.

The server needs no git and no copy of the repository. Each release
publishes three images and a small **release bundle**:

| What | Where | Holds |
| --- | --- | --- |
| `dtrack-postgres` | `ghcr.io/<owner>/dtrack-postgres:X.Y.Z` | The database |
| `dtrack-ui` | `ghcr.io/<owner>/dtrack-ui:X.Y.Z` | The web app (reads its settings at start) |
| `dtrack-ops` | `ghcr.io/<owner>/dtrack-ops:X.Y.Z` | Every database task: create, migrate, backup, restore, signing keys, power user |
| `dtrack-server-X.Y.Z.tar.gz` + `.sha256` | The release's page on GitHub | `compose.yaml` with those images pinned, the `.env` template, the cron file and `install.sh` |

`install.sh` only places files. You run every command that starts, changes
or migrates anything yourself. CI never connects to the server: you decide
when a release goes on it.

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
                                      ▲
                                   ops (one-shot: docker compose run --rm ops …)
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
- On disk, the install directory (`APP_DIR`) holds only `compose.yaml`,
  `VERSION`, `.env` (600) and `acme/acme.json` (600). Microsoft's signing keys
  and the database live in Docker volumes. Backups go to `BACKUP_DIR`; the
  only other file is `/etc/cron.d/dtrack`.

## Requirements

| What | Minimum / value |
| --- | --- |
| OS | Ubuntu 24.04 or 26.04 LTS (any recent Linux with Docker works, commands here are Ubuntu's) |
| Size | 2 vCPU, 4 GB RAM, 20 GB free disk (more for backups and audit history) |
| DNS | An A (and AAAA, if the server has IPv6) record for `HOST` pointing at the server, **before** stage 8 |
| Inbound | TCP 80 and 443 from the internet (80 is needed for the certificate and redirects to 443) |
| Outbound | DNS, NTP, HTTP and HTTPS. The hosts used: `github.com` and `objects.githubusercontent.com` (release bundle), `ghcr.io` and `pkg-containers.githubusercontent.com` (DTrack images), `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` (Traefik, PostgREST, Swagger images), `download.docker.com` (Docker packages), `acme-v02.api.letsencrypt.org` (certificate), `login.microsoftonline.com` (signing keys, and onboarding from inside the Postgres container) |
| Access | A shell on the server with `sudo` |

Nothing here needs ufw, fail2ban or automatic security updates turned off.
Leave them as they are.

## Values you need before you start

Collect these first. Examples are placeholders; use your own.

| Name | Example | Where it comes from |
| --- | --- | --- |
| `RELEASE` | `v0.2.0` | The release to install: `https://github.com/<owner>/dtrack/releases` (it must list a `dtrack-server-*.tar.gz`) |
| `OWNER` | `dnk8n` | The GitHub owner of the repository that publishes the releases |
| `APP_DIR` | `/opt/dtrack` | Where the installation lives (any fixed path) |
| `HOST` | `dtrack.example.org` | The public hostname |
| `ACME_EMAIL` | `ops@example.org` | Let's Encrypt account contact (expiry warnings) |
| `AZURE_TENANT_ID` | `00000000-0000-0000-0000-000000000000` | Test tenant's **Directory (tenant) ID**, the GUID, never the domain |
| `AZURE_CLIENT_ID` | `11111111-1111-1111-1111-111111111111` | Test app registration's **Application (client) ID** |
| `ADMIN_UPN` | `app.admin@example.onmicrosoft.com` | The test tenant's first administrator, exactly as their user principal name |
| `BACKUP_DIR` | `/var/backups/dtrack` | Where nightly backups go |
| `BACKUP_GROUP` | `dtrack-backup` | Group that may read backups (created if missing) |
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

Then paste your values (this block is the only one you edit). They are
exported because `install.sh` reads them:

```sh
export RELEASE=v0.2.0
export OWNER=dnk8n
export APP_DIR=/opt/dtrack
export HOST=dtrack.example.org
export ACME_EMAIL=ops@example.org
export AZURE_TENANT_ID=00000000-0000-0000-0000-000000000000
export AZURE_CLIENT_ID=11111111-1111-1111-1111-111111111111
export ADMIN_UPN=app.admin@example.onmicrosoft.com
export BACKUP_DIR=/var/backups/dtrack
export BACKUP_GROUP=dtrack-backup
export BACKUP_ACCOUNT=backup-pull
```

If you lose the shell part-way, `sudo -i`, paste the block again and carry on
from the stage you were in. Every `docker compose` command runs in
`APP_DIR`, where it finds `compose.yaml` and `.env` by itself.

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
      can continue to stage 7 and must fix it before stage 8.

## Stage 1: install Docker, with log rotation

Install Docker Engine and the compose plugin from Docker's apt repository
([docs.docker.com/engine/install/ubuntu](https://docs.docker.com/engine/install/ubuntu/)):

```sh
apt-get update
apt-get install -y ca-certificates curl openssl
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

## Stage 3: download and check the release bundle

```sh
V=${RELEASE#v}
mkdir -p /root/dtrack-releases && cd /root/dtrack-releases
curl -fLO "https://github.com/$OWNER/dtrack/releases/download/$RELEASE/dtrack-server-$V.tar.gz"
curl -fLO "https://github.com/$OWNER/dtrack/releases/download/$RELEASE/dtrack-server-$V.tar.gz.sha256"
sha256sum -c "dtrack-server-$V.tar.gz.sha256"
tar -xzf "dtrack-server-$V.tar.gz"
ls -l "dtrack-server-$V"
```

Read what you are about to install; it is short:

```sh
less "dtrack-server-$V/install.sh" "dtrack-server-$V/compose.yaml"
```

**Check:**

```sh
grep 'image:' "dtrack-server-$V/compose.yaml"
for i in dtrack-postgres dtrack-ops dtrack-ui; do
  docker manifest inspect "ghcr.io/$OWNER/$i:$V" >/dev/null && echo "$i:$V found"
done
```

- [ ] `sha256sum` prints `OK`. For extra assurance, compare the checksum with
      the one on the release page.
- [ ] Every DTrack image in `compose.yaml` is pinned to `X.Y.Z`, and all three
      are found without `docker login` (they are public and hold no secrets).
      If not, see [Publishing images](#publishing-images).

## Stage 4: install the files

```sh
"/root/dtrack-releases/dtrack-server-${RELEASE#v}/install.sh" --dir "$APP_DIR"
```

On a first install it creates `APP_DIR` (750), writes `.env` (600) from the
template with your values and three generated database passwords, creates
`acme/acme.json` (600), creates `BACKUP_GROUP` if missing and `BACKUP_DIR`
(750, that group), installs `compose.yaml` and `VERSION`, and writes
`/etc/cron.d/dtrack` with your `APP_DIR`. Any value not exported above is
asked for. It refuses a tenant ID that isn't a GUID. It starts nothing.

**Check:**

```sh
cd "$APP_DIR"
ls -la
grep -E '^[A-Z_]+=$' .env || echo "no empty values"
grep -E '^(HOST|ACME_EMAIL|AZURE_|BACKUP_)' .env
stat -c '%a %U:%G %n' .env acme acme/acme.json "$BACKUP_DIR"
cat /etc/cron.d/dtrack
docker compose config --quiet && echo "compose config OK"
```

- [ ] `APP_DIR` holds `compose.yaml`, `VERSION`, `.env` and `acme/`, nothing
      else.
- [ ] `no empty values`, and the printed lines show your values
      (`BACKUP_GID` is the backup group's numeric ID).
- [ ] Modes: `.env` 600, `acme` 700, `acme/acme.json` 600, `BACKUP_DIR` 750
      owned by `root:BACKUP_GROUP`.
- [ ] The cron file runs `docker compose run --rm -T ops backup` and
      `ops rotate-keys` from your `APP_DIR`.
- [ ] `compose config OK`.

Keep a copy of `.env` somewhere safe off the server (a password manager).

## Stage 5: let the backup account read backups

```sh
usermod -aG "$BACKUP_GROUP" "$BACKUP_ACCOUNT"
```

**Check:**

```sh
id "$BACKUP_ACCOUNT"
```

- [ ] `BACKUP_GROUP` is among its groups. The account picks it up on its next
      login.

## Stage 6: create the database

```sh
cd "$APP_DIR"
docker compose --profile tools pull
docker compose up -d postgres
docker compose run --rm ops init
```

`ops init` waits for Postgres, bootstraps the new cluster (roles, database,
Cyan Audit), sets the two application passwords from `.env`, applies every
migration and, because the keys volume is empty, downloads the tenant's
signing keys. It never creates users. It is safe to re-run at any time.
`docker compose run --rm ops help` lists every command.

**Check:**

```sh
docker compose run --rm ops status
docker run --rm -v dtrack_keys:/keys busybox sh -c 'ls -ln /keys; grep -o "\"kid\":\"[^\"]*\"" /keys/jwt-secret | head -3'
docker compose exec -T postgres python3 -c \
  "import urllib.request; print(urllib.request.urlopen('https://login.microsoftonline.com/$AZURE_TENANT_ID/v2.0/.well-known/openid-configuration', timeout=10).status)"
```

- [ ] `status` lists every migration as applied (`[X]`) and `Pending: 0`.
- [ ] `jwt-secret` is mode `-rw-------` owned by uid 1000 (the PostgREST
      user), with some `kid` entries.
- [ ] `200` from inside the Postgres container. Onboarding validates each new
      user's token from there, so if this fails, stage 2's rules or the
      outbound firewall are blocking it.

## Stage 7: create the first administrator

Make exactly one person a power user, the test tenant's administrator, using
their UPN exactly (case included):

```sh
cd "$APP_DIR"
docker compose run --rm ops power-user "$ADMIN_UPN"
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

`install.sh` already installed `/etc/cron.d/dtrack`: a backup every night at
01:15 server time and a key refresh every 6 hours, both through the `ops`
image. Each backup is `dtrack-<UTC time>.tar` (mode 640, group
`BACKUP_GROUP`) holding `dtrack.dump` (data) and `cyanaudit/` (audit log).
Backups older than `RETAIN_DAYS` days (7, in `.env`) are deleted, but only
after a successful backup. Key rotation reloads PostgREST only when
Microsoft's keys changed.

Take the first backup now, and run a key refresh by hand:

```sh
cd "$APP_DIR"
docker compose run --rm ops backup
docker compose run --rm ops rotate-keys
```

**Check:**

```sh
ls -l "$BACKUP_DIR"
f=$(ls -1t "$BACKUP_DIR"/dtrack-*.tar | head -1)
tar -tf "$f" | head
sudo -u "$BACKUP_ACCOUNT" -g "$BACKUP_GROUP" head -c0 "$f" && echo "backup account can read"
```

- [ ] One `dtrack-*.tar`, `-rw-r----- root BACKUP_GROUP`.
- [ ] The tarball lists `dtrack.dump` and `cyanaudit/…csv.gz` files.
- [ ] `backup account can read`.
- [ ] `rotate-keys` printed `Signing keys unchanged.`
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
   docker compose run --rm ops rotate-keys
   docker compose up -d postgrest react-admin
   ```

3. The test tenant's users stay in the database as roles named after their
   UPNs. If you restore production data next (Part C), the restore replaces
   them. Otherwise create the real administrator with
   `docker compose run --rm ops power-user <real admin UPN>`, and remove the
   test users from the Employees screen.

**Check:**

```sh
set -a; . ./.env; set +a
grep -E '^AZURE_' .env
curl -sS --resolve "$HOST:443:127.0.0.1" "https://$HOST/config.js"
```

- [ ] `.env` and `config.js` show the real tenant GUID and client ID, and
      `rotate-keys` printed `Signing keys updated`.
- [ ] In a private window, a real user signs in. Delete the test app
      registration, or the whole test tenant, once you no longer need it.

---

# Part C: restore production data

## Stage 14: restore a backup

Restoring **replaces the database on this server** with the backup. Backups
are data-only: the schema comes from the installed release (`ops init`), and
`ops restore` loads the data into it, restores the audit log and recreates
every user's role. A backup restores cleanly only into the same release it
was taken from, or a later one whose migrations don't change the shape of
existing tables.

If the backup comes from an older installation (for example one that
predates this release's migrations), restore it on your own machine first
with [backup-restore.md section 2](backup-restore.md#2-test-restore), at this
release. Only continue here once that works.

Put the backup in `BACKUP_DIR`: either a `dtrack-*.tar` from `ops backup`, or
pack a directory holding `dtrack.dump` and `cyanaudit/` into one:

```sh
cp /path/to/dtrack-YYYYMMDDTHHMMSSZ.tar "$BACKUP_DIR"/
# or: tar -C /path/to/backup-dir -cf "$BACKUP_DIR/legacy.tar" dtrack.dump cyanaudit
ls -l "$BACKUP_DIR"
```

Keep a copy of what's there now, then replace the database with an empty one:

```sh
cd "$APP_DIR"
docker compose run --rm ops backup              # the current (test) data, just in case
docker compose down                             # stops everything; volumes stay
docker volume rm dtrack_postgres_data           # deletes the database
docker compose up -d postgres
docker compose run --rm ops init
```

Restore, give the real administrator power again (power isn't part of a
backup), and start everything:

```sh
docker compose run --rm ops restore dtrack-YYYYMMDDTHHMMSSZ.tar   # a file name in BACKUP_DIR
docker compose run --rm ops power-user <real admin UPN>
docker compose up -d
```

`ops restore` refuses a database that already has users, so it can't mix a
backup into live data. It fast-forwards transaction IDs past the audit
history first, which can take a few minutes for a long history.

**Check:**

```sh
docker compose exec -T postgres psql -U postgres -d dtrack -c 'SELECT * FROM auth.get_user_roles();' | head -20
docker compose exec -T postgres psql -U postgres -d dtrack -Atc 'SELECT count(*) FROM auth.users'
docker compose run --rm ops backup              # the first backup of the restored data
```

- [ ] The expected users are listed with their roles, and the user count
      matches the old installation.
- [ ] Users sign in and see their history; spot-check a few people's time
      entries against the old system.
- [ ] A fresh backup is written.

---

# Updating to a new release

Read the release notes first. Then download and check the new bundle (stage
3 with the new `RELEASE`), and:

```sh
sudo -i
export RELEASE=vX.Y.Z APP_DIR=/opt/dtrack        # the new release, your APP_DIR
"/root/dtrack-releases/dtrack-server-${RELEASE#v}/install.sh" --dir "$APP_DIR"
cd "$APP_DIR"
diff compose.yaml.previous compose.yaml          # what changed
docker compose --profile tools pull
docker compose run --rm ops backup               # a fresh backup before migrating
docker compose run --rm ops init                 # applies pending migrations (no-op if none)
docker compose up -d
docker image prune -f                            # remove the previous images
```

`install.sh` replaces `compose.yaml` (keeping the old one as
`compose.yaml.previous`), `VERSION` and the cron file, and never changes
existing `.env` values. If the release adds settings, it appends them with
their defaults and lists them: review those before continuing.

Migrations run while the old API keeps serving, and each runs in a
transaction, so a failed migration changes nothing: put
`compose.yaml.previous` back, `docker compose up -d`, and investigate. For a
migration that rewrites large tables, `docker compose stop postgrest
react-admin` before `ops init`.

**Check:** `cat VERSION` shows the new release, `ops status` shows
`Pending: 0`, and stage 9's checks pass.

# Day-to-day operations

Everything is run as root from `APP_DIR`.

| Task | Command |
| --- | --- |
| Status | `docker compose ps` |
| Logs | `docker compose logs --tail 100 -f <service>` |
| Restart one service | `docker compose restart <service>` |
| Every ops command | `docker compose run --rm ops help` |
| Migration status | `docker compose run --rm ops status` |
| Database shell (admin) | `docker compose run --rm ops psql` |
| Backup now | `docker compose run --rm ops backup` |
| Refresh signing keys | `docker compose run --rm ops rotate-keys` |
| Backup and key job logs | `journalctl -t dtrack-backup`, `journalctl -t dtrack-keys` |
| Installed release | `cat VERSION` |
| Disk | `df -h /`, `docker system df`, `du -sh "$BACKUP_DIR"` |
| Certificate expiry | `echo \| openssl s_client -connect 127.0.0.1:443 -servername HOST 2>/dev/null \| openssl x509 -noout -enddate` (Traefik renews 30 days before) |

What's on the server:

| Path | What | Mode |
| --- | --- | --- |
| `APP_DIR/compose.yaml` | The stack, images pinned to the installed release | 644 |
| `APP_DIR/.env` | All settings and database passwords | 600 |
| `APP_DIR/acme/acme.json` | Let's Encrypt account key and certificate | 600 |
| `APP_DIR/VERSION` | Installed release | 644 |
| `/etc/cron.d/dtrack` | Backup and key rotation schedule | 644 |
| `BACKUP_DIR` | Nightly backups, 7 days | 750 / 640 |
| Docker volume `dtrack_postgres_data` | The database | |
| Docker volume `dtrack_keys` | Microsoft's public signing keys (refreshed by cron) | 600 |
| `/usr/local/sbin/docker-egress-block` | Container egress rules (stage 2) | 755 |

Leave the repository's GitHub Actions `backup.yml` and `rotate-keys.yml`
unconfigured for this server (no `PROD_HOST` variable): they push from CI over
SSH, which this setup replaces with cron.

## Publishing images

Releases are published by CI. Pushing a `vX.Y.Z` tag makes the
[images workflow](../../.github/workflows/images.yml) publish
`dtrack-postgres`, `dtrack-ui` and `dtrack-ops` as `X.Y.Z`, `X.Y` and
`sha-<7 chars>`; publishing the GitHub release for that tag makes the
[bundle workflow](../../.github/workflows/bundle.yml) attach
`dtrack-server-X.Y.Z.tar.gz` and its `.sha256`. The images hold no secrets or
settings. A newly created package on GitHub Container Registry is private:
make each one public once after its first publish
(`https://github.com/users/<owner>/packages/container/<package>/settings` →
*Change visibility* → *Public*), or `docker login ghcr.io` on the server with
a read-only token.

# Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Browser shows `TRAEFIK DEFAULT CERT` / certificate warning | Let's Encrypt couldn't validate. `docker compose logs traefik \| grep -i acme`. Usually `HOST` doesn't resolve to this server yet, port 80 isn't reachable from the internet, or `acme/acme.json` isn't mode 600. Fix it, then `docker compose restart traefik`. After 5 failures in an hour Let's Encrypt pauses that hostname for an hour. |
| `404 page not found` (plain text) | Traefik has no route for the name you used: you browsed to an IP or another name, or `HOST` in `.env` is wrong. |
| `502 Bad Gateway` on `/api` | PostgREST is down or can't reach Postgres: `docker compose logs postgrest`. A wrong `POSTGRES_PASSWORD_APP` is fixed by re-running `ops init`, which resets it from `.env`. |
| PostgREST restarting, log mentions the JWT secret or `/keys/jwt-secret` | The keys volume is empty: `docker compose run --rm ops rotate-keys`. |
| UI container restarting, log says `missing required environment` | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` or `HOST` is empty in `.env`. |
| `manifest unknown` or `denied` on pull | That release's images aren't published yet, or a package is still private (see [Publishing images](#publishing-images)). |
| `ops` says `postgres did not become ready` | Start it first: `docker compose up -d postgres`, then `docker compose logs postgres`. |
| Sign-in errors starting `AADSTS` | See [new-tenant.md troubleshooting](new-tenant.md#troubleshooting). `AADSTS50011` means `https://HOST/auth-callback` isn't on the app registration. |
| Sign-in works but the user is never created | Onboarding couldn't reach Microsoft from inside Postgres (stage 6's check), often stage 2's rules or the outbound firewall. `docker compose logs postgres \| grep -i onboard`. |
| API answers `JWSError` / `JWT invalid` | The keys volume doesn't hold the current tenant's keys: `docker compose run --rm ops rotate-keys`. |
| Disk filling | `docker system df` (old images: `docker image prune -f`), `du -sh "$BACKUP_DIR"`, `journalctl --disk-usage`. Container logs are capped at 50 MB each. |
