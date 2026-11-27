# Provisioning & deployment

Staging and production each run the same compose stack on a single AWS EC2
instance behind Cloudflare, with Traefik (from the `staging`/`prod` compose
overrides) terminating TLS.

## The server

For the overall order of work from nothing (local → Azure → server → first
use), see [the README](../README.md#setting-up-a-new-system-from-scratch).
There are two ways to deploy: by hand on one server with images published by
CI ([single-server deploy](#single-server-deploy-pull-based), recommended), or
Terraform + Ansible on AWS (below).

The server's address is `HOST` in `.env`. With Terraform it is
`<subdomain>.<domain>` from `terraform.tfvars`. The UI is served at
`https://HOST`, the API at `https://HOST/api`, Swagger UI at
`https://HOST/swagger`. The Terraform/Ansible stack also serves the Traefik
dashboard at `https://traefik.HOST` (basic auth from `TRAEFIK_BASICAUTH`), so
DNS for both names must point at it; the single-server stack has no dashboard
and needs only `HOST`.

Which login each environment uses depends on its compose override:

| Override | Login | Used by |
| --- | --- | --- |
| `prod` | Azure (MSAL) | Terraform `prod` |
| `staging-debug` | Debug login (shared secret, anyone can sign in as anyone) | Terraform `staging` |
| `staging` | Azure (MSAL); TLS via Cloudflare DNS challenge (`ACME_PROVIDER`, `CF_API_*`) | not used by default |

A debug-login environment trusts anyone holding the shared debug secret,
which is in this repository, to act as any user. Keep real data off it, and
note that the backup workflow restores production data onto `RESTORE_HOST`:
check which override that host runs. The template points it at a
`staging-debug` host, which is exactly this risk (BUG-002, #6; fix tracked in
#21 and #36).

## Prerequisites

- AWS account + IAM user (EC2 access) configured via AWS CLI
- Terraform, Ansible, GitHub CLI (or a GitHub API token)
- Cloudflare account with the target domain as a zone (API token)
- Azure AD app registration (tenant + client id) for MSAL login

## First-time setup

```sh
# Key pairs per environment (or obtain existing ones securely). These paths
# match the defaults in terraform.tfvars.tpl; keys/ is gitignored.
for e in staging prod; do
  mkdir -p keys/$e/instance keys/$e/deploy
  ssh-keygen -t ed25519 -C "you@example.com" -f keys/$e/instance/id
  ssh-keygen -t ed25519 -C "you@example.com" -f keys/$e/deploy/id
done

cp terraform.tfvars.tpl terraform.tfvars   # fill in Cloudflare/GitHub tokens, env config
cp backend.tfconf.tpl backend.tfconf       # S3 state backend
make infra-init
```

## Provision infrastructure

```sh
make infra                 # staging (default Terraform workspace)
make infra env=prod        # production (separate workspace)
```

Terraform creates the VPC/EC2/DNS records and registers deploy keys with
GitHub; it renders the Ansible inventory from
[config/ansible/templates/hosts.ini.tpl](../config/ansible/templates/hosts.ini.tpl).

## Configure & deploy with Ansible

```sh
make play                  # all environments
make play env=staging      # or one of staging | prod
```

The [base playbook](../config/ansible/base.playbook.yml) updates the system,
installs Docker, clones the repo with the deploy key, renders `.env` and
`docker-compose.override.yaml` for the environment, and starts the stack.
Deploys of new code are the same playbook re-run (tag `deploy`).

> **Warning:** the `deploy` play currently runs `docker compose down -v` and
> `./initdb.sh`, so every run **deletes the database volume** and bootstraps an
> empty database (BUG-001, fix tracked as T-OPS-01). Don't re-run it against an
> environment whose data you need until that's fixed.

Schema changes require a dump → recreate → restore cycle — see the
[backup & restore runbook](runbooks/backup-restore.md).

## Single-server deploy (pull-based)

The recommended path for one server you manage by hand. CI publishes the
images ([images.yml](../.github/workflows/images.yml)) to GitHub Container
Registry; the server only pulls them and never builds or needs CI access.
The stack is [compose.server.yaml](../compose.server.yaml):

- Traefik is the only container with published ports (80, 443). Docker
  bypasses ufw for published ports, so Postgres and the API have none.
- One Let's Encrypt certificate for `HOST` via the HTTP-01 challenge on port
  80. No DNS provider, wildcard or second hostname (no Traefik dashboard).
- Every service uses json-file logging with rotation (10 MB × 5).
- Nightly database backups and key rotation run from cron on the server.

Everything lives in one directory, the repository checkout (this guide uses
`/opt/dtrack`): compose file, `.env`, `keys/`, `acme/` and scripts. The
checkout supplies `initdb.sh` and the SQL it runs, `rotate-keys.sh` and the
backup script; the images supply everything that runs.

### What the server needs

- Ubuntu (or similar) with a public address, DNS A/AAAA record for `HOST`.
- Inbound 80 and 443. Outbound DNS, HTTP/HTTPS (ghcr.io, Docker Hub,
  login.microsoftonline.com, Let's Encrypt, github.com) and NTP.
- An Entra ID app registration with `https://HOST/auth-callback` as an SPA
  redirect URI ([runbooks/new-tenant.md](runbooks/new-tenant.md)).
- Published images: after the first successful `images` workflow run, make
  the `dtrack-postgres` and `dtrack-ui` packages public once (GitHub →
  your profile → Packages → package → Package settings → Change visibility),
  or `docker login ghcr.io` on the server with a read-only token.

### 1. Docker, with log rotation

Install Docker Engine and the compose plugin from Docker's apt repository
([docs.docker.com/engine/install/ubuntu](https://docs.docker.com/engine/install/ubuntu/)),
then set default log rotation for any container and restart Docker:

```sh
sudo install -m 644 /dev/stdin /etc/docker/daemon.json <<'JSON'
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "5" } }
JSON
sudo systemctl restart docker
sudo apt-get install -y git gettext-base   # gettext-base provides envsubst
```

Keep ufw and fail2ban as they are. Optionally stop containers reaching
private networks (DNS stays allowed) with rules in the `DOCKER-USER` chain,
for example `iptables -I DOCKER-USER -d 10.0.0.0/8 -j DROP` for each private
range your organisation uses, persisted however your hosts persist iptables.
Containers still need the outbound internet access listed above.

### 2. Checkout, configuration and secrets

```sh
sudo git clone https://github.com/<owner>/dtrack.git /opt/dtrack
cd /opt/dtrack
sudo git checkout <commit>            # the commit whose images you deploy

sudo install -m 600 deploy/server.env.tpl .env
sudo $EDITOR .env                     # every value; IMAGE_TAG=sha-<first 7 of <commit>>

# Let's Encrypt account and certificate store (Traefik requires mode 600).
sudo install -d -m 700 acme
sudo install -m 600 /dev/null acme/acme.json

# Signing-key file, readable only by the PostgREST container's user.
sudo install -d -m 700 keys
uid=$(sudo docker image inspect -f '{{.Config.User}}' postgrest/postgrest:v14.15 2>/dev/null \
      || { sudo docker pull -q postgrest/postgrest:v14.15 >/dev/null; \
           sudo docker image inspect -f '{{.Config.User}}' postgrest/postgrest:v14.15; })
sudo install -m 600 -o "${uid:-0}" /dev/null keys/jwt-secret
sudo chmod 711 keys
sudo ./rotate-keys.sh                 # downloads the tenant's keys into keys/jwt-secret
```

`keys/jwt-secret` holds Microsoft's public signing keys (anyone can download
them), but it is kept at 600 with the rest. `rotate-keys.sh` overwrites it in
place, so owner and mode survive rotation.

### 3. Start

```sh
sudo docker compose pull
sudo ./initdb.sh                      # creates and bootstraps the database (once)
sudo docker compose up -d
sudo docker compose ps                # all services running
```

Traefik requests the certificate on first start; watch
`sudo docker compose logs -f traefik` if `https://HOST` doesn't come up within
a minute (usually DNS not yet pointing at the server, or port 80 blocked).
Then continue with [runbooks/first-run.md](runbooks/first-run.md).

`./initdb.sh` only acts on a new database: on an existing one it does
nothing, and `--force` deletes it.

### 4. Backups and key rotation (cron)

```sh
sudo groupadd --system dtrack-backup            # the backup pull account joins this group
sudo usermod -aG dtrack-backup <backup-account>
sudo install -m 644 deploy/cron.d-dtrack /etc/cron.d/dtrack
sudo $EDITOR /etc/cron.d/dtrack                 # fix paths if not /opt/dtrack
sudo deploy/backup-db.sh                        # first backup now, to check it works
```

[backup-db.sh](../deploy/backup-db.sh) writes `dtrack-<UTC time>.tar` (mode
640, group `dtrack-backup`) into `/var/backups/dtrack` every night and keeps 7
days. Override with `BACKUP_DIR`, `BACKUP_GROUP` and `RETAIN_DAYS` on the cron
line. Each tarball holds `dtrack.dump` and `cyanaudit/`, the layout the
[restore runbook](runbooks/backup-restore.md) expects. `rotate-keys.sh` runs
every 6 hours and reloads PostgREST when Microsoft's keys change. Both log to
the journal (`journalctl -t dtrack-backup`, `-t dtrack-keys`).

### Updating

```sh
cd /opt/dtrack
sudo git fetch && sudo git checkout <new commit>
sudo $EDITOR .env                     # IMAGE_TAG=sha-<new commit, 7 chars>
sudo docker compose pull && sudo docker compose up -d
```

A release that changes the database schema needs the dump → recreate →
restore cycle in the [backup & restore runbook](runbooks/backup-restore.md),
not just a pull.

## Scheduled operations (GitHub Actions)

| Workflow | Schedule | What |
| --- | --- | --- |
| [backup.yml](../.github/workflows/backup.yml) | every 2 h | pg_dump + cyanaudit dump from prod, uploaded as artifacts with tiered retention (bi-hourly/daily/weekly/monthly), then restored onto staging as a continuous restore test |
| [rotate-keys.yml](../.github/workflows/rotate-keys.yml) | daily, 00:00 UTC | refreshes the Azure JWKS file PostgREST uses as `PGRST_JWT_SECRET` and HUPs PostgREST |

Both use the playbooks in [.github/ansible/](../.github/ansible/), with an
inventory rendered at run time by
[render-inventory.sh](../.github/ansible/render-inventory.sh) from these
repository **variables** (Settings → Secrets and variables → Actions):

| Variable | Used for |
| --- | --- |
| `PROD_HOST` | backup source, key rotation |
| `RESTORE_HOST` | continuous restore target, key rotation |

A job whose host variable is unset is skipped, so the schedules stay quiet
until an environment exists. They also need the repo secrets `PRIVATE_KEY`,
`HOST_KEY` (prod) and `HOST_KEY_TEST` (restore target).
