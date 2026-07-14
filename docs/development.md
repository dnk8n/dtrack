# Local development

Everything runs in Docker Compose. The only host prerequisites are Docker with
the compose plugin and (optionally, for UI work outside containers) Node 18+
with yarn.

On macOS without Docker Desktop:

```sh
brew install colima docker docker-compose
colima start --cpu 4 --memory 8
# one-time: let the docker CLI find brew's compose plugin
# add to ~/.docker/config.json:  "cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]
```

## One-time setup

```sh
cp .env.tpl .env
mkdir -p keys && printf 'Dummy5ecr3t4D3bug0n1yN0T4Pr0D123' > keys/jwt-secret
```

The `.env` template's dummy values work as-is for local debug mode. The
`keys/jwt-secret` file must exist **as a file** before the first
`docker compose up` — if compose creates the bind-mount path for you, it will
be a directory and PostgREST will fail to read it (delete it and recreate as a
file). In debug mode its content is unused (the debug compose override injects
the shared HS256 secret), but the mount must still resolve.

## Two modes

| | `make dev` | `make debug` |
| --- | --- | --- |
| Login | Real Azure AD via MSAL | Local form; browser signs an HS256 JWT itself |
| Requires | Azure tenant + app registration, real `AZURE_*` values in `.env`, JWKS in `keys/jwt-secret` | Nothing external |
| Onboarding (`/rpc/onboard`) | Works (validates Azure id tokens in-database) | **Does not work** — create users via the Employees screen instead |
| Use for | Verifying the real auth path | Day-to-day development and automated tests |

Both modes use the `dev` compose override (published ports, verbose PostgREST).
Switching between them: rebuild (`make dev` / `make debug` handle this) **and
clear the browser's storage for localhost** — MSAL and the debug provider
cache different state and will confuse each other.

## Start, bootstrap, use

```sh
./initdb.sh    # first time, or after `make clean`
make debug     # or: make dev
```

`initdb.sh` builds and starts postgres if needed, waits for readiness, then
executes all of `dtrack/db/sql/` in order (see
[architecture.md](architecture.md#database-bootstrap-initdbsh)). Run it once
per fresh data volume. It is not idempotent — on an already-initialized
database many statements will error; for a clean slate use `make clean` first
(this **deletes the local database volume**).

Bootstrap before `make debug`, or re-run `make debug` afterwards: `initdb.sh`
invokes plain `docker compose`, which recreates the postgres container
*without* the dev override (no published 5432 port) — running `make debug`
last leaves everything in the intended dev configuration.

| URL | What |
| --- | --- |
| <http://localhost:5174> | UI (log in as `Dummy.User@example.com` in debug mode) |
| <http://localhost:3000> | PostgREST API |
| <http://localhost:8080> | Swagger UI |
| `localhost:5432` | Postgres (`psql -h localhost -U admin -d dtrack`, password from `.env`) |

The initial power user is `$POSTGRES_USER_APP_POWER` from `.env`
(`Dummy.User@example.com` by default). Create further users through the
Employees screen while logged in as the power user, then log in as them —
debug mode can impersonate any *existing* user.

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

### Calling the API directly

Any HS256 JWT signed with the debug secret works against PostgREST in debug
mode. For example, with [jwt-cli](https://github.com/mike-engel/jwt-cli) or any
JWT tool:

```sh
TOKEN=$(jwt encode --secret 'Dummy5ecr3t4D3bug0n1yN0T4Pr0D123' '{"preferred_username":"Dummy.User@example.com"}')
curl -H "Authorization: Bearer $TOKEN" http://localhost:3000/current_employee
```

## UI development with hot reload

The containerized UI is a static build; for iterative UI work run Vite on the
host against the containerized API:

```sh
cd dtrack/ui
yarn install
VITE_API_BASE_URI=http://localhost:3000 VITE_APP_BASE_URI=http://localhost:5173 yarn debug
```

`yarn debug` starts the debug-mode stack (if not already up) and then runs
Vite locally on <http://localhost:5173> with the debug login. `yarn lint`
formats + lints (this repo pins prettier/eslint via the UI package; a
pre-commit hook runs lint on commit inside `dtrack/ui`).

## Troubleshooting

- **PostgREST restarts / "Password authentication failed"** — database not
  initialized yet; run `./initdb.sh`.
- **UI login succeeds but everything 401s** — stale browser storage after
  switching dev/debug modes; clear site data for localhost.
- **`role "…" does not exist` from PostgREST** — you logged in (debug mode) as
  a user that was never created. Log in as the power user and create the
  employee first.
- **`keys/jwt-secret` is a directory** — see one-time setup above.
- **initdb.sh errors mid-way** — it assumes a fresh volume. `make clean`, then
  `make debug`, then re-run.
