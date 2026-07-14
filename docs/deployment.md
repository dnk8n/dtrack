# Provisioning & deployment

Staging and production each run the same compose stack on a single AWS EC2
instance behind Cloudflare, with Traefik (from the `staging`/`prod` compose
overrides) terminating TLS.

## Prerequisites

- AWS account + IAM user (EC2 access) configured via AWS CLI
- Terraform, Ansible, GitHub CLI (or a GitHub API token)
- Cloudflare account with the target domain as a zone (API token)
- Azure AD app registration (tenant + client id) for MSAL login

## First-time setup

```sh
# Key pairs (or obtain existing ones securely)
mkdir -p private/keys/instance private/keys/deploy
ssh-keygen -t ed25519 -C "you@example.com" -f private/keys/instance/id
ssh-keygen -t ed25519 -C "you@example.com" -f private/keys/deploy/id

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

Schema changes require a dump → recreate → restore cycle — see the
[backup & restore runbook](runbooks/backup-restore.md).

## Scheduled operations (GitHub Actions)

| Workflow | Schedule | What |
| --- | --- | --- |
| [backup.yml](../.github/workflows/backup.yml) | every 2 h | pg_dump + cyanaudit dump from prod, uploaded as artifacts with tiered retention (bi-hourly/daily/weekly/monthly), then restored onto staging as a continuous restore test |
| [rotate-keys.yml](../.github/workflows/rotate-keys.yml) | (see workflow) | refreshes the Azure JWKS file PostgREST uses as `PGRST_JWT_SECRET` and HUPs PostgREST |

Both need repo secrets (`PRIVATE_KEY`, `HOST_KEY`, `HOST_KEY_TEST`) and use
the playbooks in [.github/ansible/](../.github/ansible/).
