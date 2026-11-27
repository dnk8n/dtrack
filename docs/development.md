# Local development

Everything runs in Docker Compose. The host prerequisites are Docker with
the compose plugin, `envsubst` (GNU gettext; `initdb.sh` uses it to fill
`.env` values into the SQL), and optionally, for UI work outside containers,
Node 24 (the version the UI image and CI use) with yarn.

On macOS without Docker Desktop:

```sh
brew install colima docker docker-compose gettext
colima start --cpu 4 --memory 8
# one-time: let the docker CLI find brew's compose plugin
# add to ~/.docker/config.json:  "cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]
```

## One-time setup

```sh
make env    # .env from .env.tpl, keys/jwt-secret with the demo secret
```

`make env` never overwrites existing files. The `.env` template's dummy
values work as-is for local demo mode. The `keys/jwt-secret` file must exist
**as a file** before the first `docker compose up` — if compose creates the
bind-mount path for you, it will be a directory and PostgREST will fail to
read it (delete it and recreate as a file). In demo mode its content is
unused (the demo compose override injects the shared HS256 secret), but the
mount must still resolve.

## Two modes

| | `make dev` | `make demo` |
| --- | --- | --- |
| Login | Real Azure AD via MSAL | Local form; browser signs an HS256 JWT itself |
| Requires | Azure tenant + app registration, real `AZURE_*` values in `.env`, JWKS in `keys/jwt-secret` | Nothing external |
| Onboarding (`/rpc/onboard`) | Works (validates Azure id tokens in-database) | **Does not work** — create users via the Employees screen instead |
| Use for | Verifying the real auth path | Day-to-day development, presenting features, automated tests |

Demo mode is never for a live server: its signing secret is public, so anyone
could sign in as anyone. The only acceptable hosted use is a throwaway public
demo with no real data (e.g. rebuilt from scratch daily).

To use `make dev`, follow [runbooks/new-tenant.md](runbooks/new-tenant.md)
(app registration with redirect URI `http://localhost:5174/auth-callback`,
the three `AZURE_*`/power-user values in `.env`, `./rotate-keys.sh`, then a
fresh `make initdb`).

Both modes use the `dev` compose override (published ports, verbose PostgREST).
Switching between them: rebuild (`make dev` / `make demo` handle this) **and
clear the browser's storage for localhost** — MSAL and the demo provider
cache different state and will confuse each other.

## Start, bootstrap, use

```sh
make setup     # = make env + make initdb + make demo
```

Or step by step: `make initdb` then `make demo` (or `make dev`).

`make initdb` builds and starts postgres if needed, waits for readiness, then
executes all of `dtrack/db/sql/` in order (see
[architecture.md](architecture.md#database-bootstrap-initdbsh)), stopping on
the first SQL error. It is idempotent: if the application database already
exists it is a no-op. `./initdb.sh --force` recreates everything from scratch
(this **deletes the local database volume**), as does `make clean` followed by
`make setup`.

Use `make initdb` rather than calling `./initdb.sh` directly: the make target
exports the dev/demo compose file set, so postgres keeps its published port
and dev mounts, and passes `--dev-logging`, which turns on verbose statement
logging (`log_statement = 'all'`). Called bare (as on deployed servers) the
script falls back to default compose file resolution and leaves logging at
Postgres defaults — statement logging writes sensitive data to the server log
and is strictly a development convenience.

| URL | What |
| --- | --- |
| <http://localhost:5174> | UI (log in as `Dummy.User@example.com` in demo mode) |
| <http://localhost:3000> | PostgREST API |
| <http://localhost:8080> | Swagger UI |
| `localhost:5432` | Postgres (`psql -h localhost -U admin -d dtrack`, password from `.env`) |

The initial power user is `$POSTGRES_USER_APP_POWER` from `.env`
(`Dummy.User@example.com` by default). Create further users through the
Employees screen while logged in as the power user, then log in as them —
demo mode can impersonate any *existing* user.

## Demo data

[dtrack/dev/fixtures/simulated](../dtrack/dev/fixtures/simulated/README.md)
loads three months of realistic data for one lead and one member into a fresh
local database whose users already exist (in `make dev` mode: they signed in
once). It acts as each real user and uses the power user only where the
schema requires it. See [runbooks/first-run.md](runbooks/first-run.md) for
who may do what.

## Everyday commands

```sh
make down                                  # stop (keeps data)
make clean                                 # stop + delete data volume
docker compose logs -f postgrest           # follow a service's logs
docker compose exec postgres psql -U admin -d dtrack   # SQL shell as app admin
docker compose up -d --build react-admin   # rebuild just the UI image
```

Handy inspection queries (activity, audit log, durations) live in
[dtrack/dev/queries/useful.sql](../dtrack/dev/queries/useful.sql).

`make test` runs the full test pyramid — all three suites in parallel, each
in its own compose project with its own postgres/PostgREST/UI ports,
recreated from scratch per run and stopped (state kept) afterwards;
`make test-inspect-<suite>` revives one for post-mortem/debugging without
rerunning anything. The dev stack is untouched and doesn't even need to be
running. See [testing.md](testing.md).

### Calling the API directly

Any HS256 JWT signed with the demo secret works against PostgREST in demo
mode. For example, with [jwt-cli](https://github.com/mike-engel/jwt-cli) or any
JWT tool:

```sh
TOKEN=$(jwt encode --secret 'Dummy5ecr3t4D3m00n1yN0T4Pr0D1234' '{"preferred_username":"Dummy.User@example.com"}')
curl -H "Authorization: Bearer $TOKEN" http://localhost:3000/current_employee
```

## UI development with hot reload

The containerized UI is a static build; for iterative UI work run Vite on the
host against the containerized API:

```sh
cd dtrack/ui
yarn install
VITE_API_BASE_URI=http://localhost:3000 VITE_APP_BASE_URI=http://localhost:5173 yarn demo
```

`yarn demo` starts the demo-mode stack (if not already up) and then runs
Vite locally on <http://localhost:5173> with the demo login. `yarn lint`
formats + lints (this repo pins prettier/eslint via the UI package; a
pre-commit hook runs lint on commit inside `dtrack/ui`).

## Troubleshooting

- **PostgREST restarts / "Password authentication failed"** — database not
  initialized yet; run `make initdb`.
- **UI login succeeds but everything 401s** — stale browser storage after
  switching dev/demo modes; clear site data for localhost.
- **`role "…" does not exist` from PostgREST** — you logged in (demo mode) as
  a user that was never created. Log in as the power user and create the
  employee first.
- **`keys/jwt-secret` is a directory** — see one-time setup above.
- **`make initdb` errors mid-way** — it assumes a fresh volume. Fix the cause,
  then `make clean` and `make setup` to start again from an empty volume.
