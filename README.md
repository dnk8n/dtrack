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
make setup    # .env + keys from templates, bootstrap the database, start the stack
```

Then log in at <http://localhost:5174> as `Dummy.User@example.com` (any password field shown is ignored — debug mode signs a local JWT). The API is at <http://localhost:3000>, Swagger UI at <http://localhost:8080>.

See [docs/development.md](docs/development.md) for the full guide, including dev-vs-debug modes and troubleshooting.

## Setting up a new system from scratch

If you are standing up DTrack for an organisation with nothing but this repo
and a server, work through these in order:

1. **Run it locally in debug mode:** [docs/development.md](docs/development.md)
   (`make setup`). Confirms your machine and the test suites work (`make test`).
2. **Create the Entra ID tenant, app registration and users, and prove real
   Microsoft sign-in locally:** [docs/runbooks/new-tenant.md](docs/runbooks/new-tenant.md)
   sections 1–4. Optionally load realistic sample data from
   [dtrack/dev/fixtures/simulated](dtrack/dev/fixtures/simulated/README.md).
3. **Deploy to the server:** [docs/deployment.md](docs/deployment.md), plus the
   server notes in [new-tenant.md section 5](docs/runbooks/new-tenant.md#5-repeat-on-a-server).
4. **Switch from a test tenant to the real one, and restore data if you have a
   backup:** [new-tenant.md section 6](docs/runbooks/new-tenant.md#6-switch-an-existing-deployment-to-another-tenant)
   and [docs/runbooks/backup-restore.md](docs/runbooks/backup-restore.md).

## Documentation

| Doc | What it covers |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | System design: schemas, roles, RLS, request lifecycle, audit |
| [docs/development.md](docs/development.md) | Running and working on DTrack locally |
| [docs/testing.md](docs/testing.md) | Test strategy, how to run the suites, testing policies |
| [docs/test-cases.md](docs/test-cases.md) | Natural-language test case catalog (`TC-…` ids) |
| [docs/deployment.md](docs/deployment.md) | Provisioning infrastructure and deploying |
| [docs/runbooks/backup-restore.md](docs/runbooks/backup-restore.md) | Backup, test-restore and live-restore procedures |
| [docs/runbooks/new-tenant.md](docs/runbooks/new-tenant.md) | Point DTrack at a new Azure (Entra ID) tenant, verify locally, repeat on a server |

## Repository layout

```
dtrack/db/sql/       Database bootstrap SQL, executed in order by initdb.sh
dtrack/ui/           react-admin single-page app (Vite + TypeScript)
dtrack/dev/queries/  Helper SQL for operations (also used by restore automation)
tests/               pgTAP, API (Vitest) and E2E (Playwright) suites
config/              Docker images, compose overrides, Ansible playbooks
.github/             CI and operations workflows, their Ansible playbooks
main.tf              Terraform: AWS EC2 + Cloudflare DNS + GitHub deploy keys
```

## Project status

The current codebase is a deliberate stability baseline (tag: `mvp-baseline`). The
focus is consolidation — documentation, developer experience, CI and test
coverage — not new features. Application code (SQL and UI) is intentionally
frozen while the safety net is built around it.
