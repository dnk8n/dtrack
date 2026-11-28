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
| `staging-demo` | Demo login (shared secret, anyone can sign in as anyone) | Terraform `staging` |
| `staging` | Azure (MSAL); TLS via Cloudflare DNS challenge (`ACME_PROVIDER`, `CF_API_*`) | not used by default |

A demo-login environment trusts anyone holding the shared demo secret,
which is in this repository, to act as any user. Keep real data off it, and
note that the backup workflow restores production data onto `RESTORE_HOST`:
check which override that host runs. The template points it at a
`staging-demo` host, which is exactly this risk (BUG-002, #6; fix tracked in
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

Schema changes are applied by `./initdb.sh`, which runs pending migrations
on every run (see "Updating to a new release" in
[runbooks/server-install.md](runbooks/server-install.md#updating-to-a-new-release)).

## Single-server deploy (pull-based)

The recommended path for one server you manage by hand:
**[runbooks/server-install.md](runbooks/server-install.md)**, a step-by-step
walkthrough with a check after every stage. It covers installing with a test
Entra ID tenant, switching to the real one, restoring a backup, and updating
to a new release.

In short: CI publishes the images
([images.yml](../.github/workflows/images.yml)) to GitHub Container Registry,
and the server only pulls them, so CI never needs access to the server. The
stack is [compose.server.yaml](../compose.server.yaml): Traefik is the only
container with published ports (80, 443), one Let's Encrypt certificate for
`HOST` comes through the HTTP-01 challenge, every service logs to json-file
with rotation, and cron on the server runs nightly backups
([deploy/backup-db.sh](../deploy/backup-db.sh)) and key rotation
([deploy/cron.d-dtrack](../deploy/cron.d-dtrack)). Everything lives in one
directory, a checkout of the release tag whose images `IMAGE_TAG` in `.env`
names.

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
