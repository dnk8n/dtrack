# Provisioning & deployment

Staging and production each run the same compose stack on a single AWS EC2
instance behind Cloudflare, with Traefik (from the `staging`/`prod` compose
overrides) terminating TLS.

## The server

For the overall order of work from nothing (local → Azure → server → first
use), see [the README](../README.md#setting-up-a-new-system-from-scratch).
There are two ways to deploy: Terraform + Ansible (below), or by hand on an
existing server ([manual single-server deploy](#manual-single-server-deploy)).

The server's address is `HOST` in `.env`. With Terraform it is
`<subdomain>.<domain>` from `terraform.tfvars`. The UI is served at
`https://HOST`, the API at `https://HOST/api`, Swagger UI at
`https://HOST/swagger` and the Traefik dashboard at `https://traefik.HOST`
(basic auth from `TRAEFIK_BASICAUTH`). DNS for both `HOST` and
`traefik.HOST` must point at the server.

Which login each environment uses depends on its compose override:

| Override | Login | Used by |
| --- | --- | --- |
| `prod` | Azure (MSAL) | Terraform `prod` |
| `staging-debug` | Debug login (shared secret, anyone can sign in as anyone) | Terraform `staging` |
| `staging` | Azure (MSAL); TLS via Cloudflare DNS challenge (`ACME_PROVIDER`, `CF_API_*`) | not used by default |

A debug-login environment trusts anyone holding the shared debug secret,
which is in this repository, to act as any user. Keep real data off it, and
note that the backup workflow restores production data onto `RESTORE_HOST`:
check which override that host runs.

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

## Manual single-server deploy

For a server that already exists (any Linux host with a public address and
DNS for `HOST` and `traefik.HOST` pointing at it, ports 80 and 443 open).
This is what the Ansible playbook does, without the database wipe:

```sh
# On the server: Docker with the compose plugin, git, and envsubst
# (Ubuntu: package gettext-base, usually preinstalled)
git clone <repository URL> dtrack && cd dtrack

cp .env.tpl .env
$EDITOR .env
#   HOST                     the server's address, e.g. dtrack.example.org
#   ACME_EMAIL               Let's Encrypt contact
#   TRAEFIK_BASICAUTH        htpasswd -bnBC 10 "" <password> | tr -d ':\n'
#   POSTGRES_PASSWORD, POSTGRES_PASSWORD_APP, POSTGRES_PASSWORD_APP_ADMIN
#                            strong, distinct passwords
#   AZURE_TENANT_ID, AZURE_CLIENT_ID, POSTGRES_USER_APP_POWER
#                            see runbooks/new-tenant.md
#   PALETTE_PRIMARY/SECONDARY  optional UI colours

ln -s config/docker-compose.overrides/prod.yaml docker-compose.override.yaml
./rotate-keys.sh             # tenant signing keys into keys/jwt-secret (#69)
docker compose build --pull
./initdb.sh                  # creates and bootstraps the database (once)
docker compose up -d
```

Then open `https://HOST` and continue with
[runbooks/first-run.md](runbooks/first-run.md). Run `./initdb.sh` only on
a new database: on an existing one it does nothing, and `--force` deletes
it. Schedule `./rotate-keys.sh` (daily) on the server, or use the GitHub
workflow below.

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
