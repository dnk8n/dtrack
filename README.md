# DTrack

Time tracking for teams, built SQL-first: the database **is** the application.

- **PostgreSQL 15** holds the schema, business logic (functions + triggers) and authorization (roles + row-level security). There is no application server.
- **[PostgREST](https://postgrest.org)** exposes the `api` schema as a REST API.
- **[react-admin](https://marmelab.com/react-admin/)** provides the single-page UI.
- **Azure AD (MSAL)** authenticates users in production; a self-contained **debug login** makes local development possible without Azure.
- **Terraform + Ansible** provision and deploy staging/production to AWS behind Cloudflare.

## Quickstart (local, no Azure required)

Prerequisites: Docker with the compose plugin (on macOS e.g. `colima start`), and this repo cloned.

```sh
cp .env.tpl .env                       # dummy credentials are fine locally
mkdir -p keys && printf 'Dummy5ecr3t4D3bug0n1yN0T4Pr0D123' > keys/jwt-secret
./initdb.sh                            # build + start postgres, bootstrap the database
make debug                             # start the full stack in debug mode
```

Then log in at <http://localhost:5174> as `Dummy.User@example.com` (any password field shown is ignored — debug mode signs a local JWT). The API is at <http://localhost:3000>, Swagger UI at <http://localhost:8080>.

See [docs/development.md](docs/development.md) for the full guide, including dev-vs-debug modes and troubleshooting.

## Documentation

| Doc | What it covers |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | System design: schemas, roles, RLS, request lifecycle, audit |
| [docs/development.md](docs/development.md) | Running and working on DTrack locally |
| [docs/deployment.md](docs/deployment.md) | Provisioning infrastructure and deploying |
| [docs/runbooks/backup-restore.md](docs/runbooks/backup-restore.md) | Backup, test-restore and live-restore procedures |

## Repository layout

```
dtrack/db/sql/       Database bootstrap SQL, executed in order by initdb.sh
dtrack/ui/           react-admin single-page app (Vite + TypeScript)
dtrack/dev/queries/  Helper SQL for operations (also used by restore automation)
config/              Docker images, compose overrides, Ansible playbooks
.github/             CI/CD workflows and their Ansible playbooks
main.tf              Terraform: AWS EC2 + Cloudflare DNS + GitHub deploy keys
```

## Project status

The current codebase is a deliberate stability baseline (tag: `mvp-baseline`). The
focus is consolidation — documentation, developer experience, CI and test
coverage — not new features. Application code (SQL and UI) is intentionally
frozen while the safety net is built around it.
