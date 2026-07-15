# Architecture

DTrack is a SQL-first application. All business logic, data validation and
authorization live in PostgreSQL; PostgREST turns the database's `api` schema
into a REST API; a react-admin SPA consumes it. There is no hand-written
application server.

```
                    Azure AD (production)          ┌──────────────┐
                          │ OIDC / MSAL            │  swagger-ui  │ :8080
                          ▼                        └──────┬───────┘
┌─────────────┐  Bearer JWT   ┌───────────┐  SQL   ┌──────▼───────┐
│ react-admin ├──────────────►│ PostgREST ├───────►│  PostgreSQL  │
│  (nginx)    │ :5174 → :3000 │           │        │ + cyanaudit  │
└─────────────┘               └───────────┘        └──────────────┘
     SPA                    serves schema `api`    schema, logic, RLS
```

## Components

| Service | Image | Pinned | Latest (July 2026) | Notes |
| --- | --- | --- | --- | --- |
| `postgres` | custom, from `postgres:15` | PG 15 | PG 18 (15 supported until Nov 2027) | Adds cyanaudit (compiled from source), plpython3u + `guardpost` (JWT validation), perl deps for cyanaudit tools. [Dockerfile](../config/dockerfiles/postgres/Dockerfile) |
| `postgrest` | `postgrest/postgrest` | v10.1.2 | v14 (v11–v14 released since) | Serves schema `api`, anon role `anon`, pre-request `pre.request` |
| `react-admin` | custom, node 18 build → nginx | react-admin 4.9, Vite 4, TS 4.6 | react-admin 5.15, Vite 7, TS 5.x | Built with `VITE_*` build args; served as static SPA. [Dockerfile](../config/dockerfiles/react-admin/Dockerfile) |
| `swagger` | `swaggerapi/swagger-ui` | v5.32.8 | current (July 2026) | Reads PostgREST's OpenAPI output |

Version pins are part of the `mvp-baseline` line in the sand; upgrades are
deliberate future work, not drive-by changes.

## Database layout

The database (default name `dtrack`) is organized by schema, with privileges
increasing from left to right in the pipeline:

| Schema | Purpose |
| --- | --- |
| `internal` | Base tables — the source of truth. Never exposed directly. |
| `auth` | `users` table plus SECURITY DEFINER functions for user/role management |
| `api` | Views + `INSTEAD OF` triggers — the only schema PostgREST serves |
| `pre` | `pre.request()`, PostgREST's pre-request hook (sets `cyanaudit.uid`) |
| `admin` | Cyanaudit inspection helpers (transactions, slowest, details) |
| `cyanaudit` | Column-level audit log of all data changes |

### Tables (`internal` + `auth`)

```
auth.users ─────────────┬────────────────────────────────┐
                        │                                │
internal.projects ──┬─ internal.user_project_roles       │  (is_lead flags PMs)
                    ├─ internal.project_activities ── internal.activities
                    ├─ internal.project_areas_of_work ── internal.areas_of_work
                    │                                    │
internal.time_trackings ── (user, project, activity, aow)│
                                                         │
internal.areas_of_expertise ── internal.aoe_hierarchies ─┘  (aoe, lead, member)
internal.faqs
```

Key constraints:
- `time_trackings.duration` must be a multiple of 15 minutes (CHECK constraint).
- A member may belong to only one team (lead) per area of expertise (trigger
  `check_unique_member_per_aoe`).
- All FKs are `ON DELETE RESTRICT ON UPDATE CASCADE`; deletes cascade manually
  inside the `INSTEAD OF DELETE` trigger functions.

### The api view pattern

Every resource the UI sees is an `api` view with `security_invoker = on`
(so RLS applies to the calling user), plus `INSTEAD OF` triggers translating
INSERT/UPDATE/DELETE on the view into writes against `internal` tables:

| api view | write triggers | backing data |
| --- | --- | --- |
| `employees`, `current_employee`, `all_employees` | upsert + delete | `auth.users`, project/team memberships |
| `projects` | upsert + delete (also grants/revokes `pm`) | `internal.projects` + join tables |
| `activities`, `areas_of_work` | upsert + delete | respective tables + project links |
| `areas_of_expertise` | upsert + delete | `internal.areas_of_expertise` |
| `aoe_teams` | upsert + delete (also grants/revokes `lead`) | `internal.aoe_hierarchies` |
| `time_trackings` | insert + update + delete | `internal.time_trackings` |
| `faqs` | none (plain view, RLS on table) | `internal.faqs` |
| `timetracking_summary(...)`, `duration_calendar` | read-only | dynamic aggregation for dashboard plots |

Views aggregate related entities as JSONB (`{id, name}` pairs and `*_ids`
arrays) so react-admin can render and edit relationships without extra
round-trips. `aoe_teams` has a synthetic text ID: `lpad(aoe_id)||lpad(lead_id)`
(4+4 digits), since a team is identified by (area of expertise, lead).

## Identity, roles and authorization

**Each user is a PostgreSQL role**, named by their email address. Group roles
define capability tiers, granted cumulatively:

```
anon < basic < pm ─┐
        basic < lead ─┴─< power  ( power BYPASSRLS; admin is member of power )
```

- `authenticator` (`$POSTGRES_USER_APP`) is the only login role PostgREST
  uses; it can `SET ROLE` to any user role.
- PostgREST maps JWT claim `preferred_username` (an email) to the role —
  `PGRST_JWT_ROLE_CLAIM_KEY=.preferred_username`.
- `basic` is every user's default. `pm` and `lead` are granted/revoked
  *automatically* by triggers: becoming a project lead grants `pm`; becoming
  an AoE team supervisor grants `lead`. `power` is granted manually via
  `auth.grant_power` (or the employees UI's `is_power` flag).
- Role management uses SECURITY DEFINER functions in `auth`
  (`create_user`, `del_user`, `grant_priv`, `revoke_priv`, `grant_power`,
  `revoke_power`) — executable only by `power` (except `create_user`-via-
  `api.onboard`, see below).

**Row-level security** (see [014.schema.policies.sql](../dtrack/db/sql/002.postgres_user_app_admin.postgres_db_app/014.schema.policies.sql))
enforces, roughly:

- `time_trackings`: you see/write your own rows, plus rows of members you lead.
- `projects`: visible to members, their leads, and lead-of-member chains;
  writable by project leads (PMs); deletable only by `power`.
- `users`: you see yourself plus people you lead/PM (and inverses); you update
  only yourself.
- `activities` / `areas_of_work`: readable by all; only `power` creates/deletes;
  per-project links managed by that project's leads.
- `areas_of_expertise` / `aoe_hierarchies`: visible to their leads and members;
  leads manage their own team rows.
- `faqs`: everyone reads published rows; only `power` writes/deletes.
- `power` has `BYPASSRLS` — sees and can do everything.

## Request lifecycle

1. SPA sends a request with `Authorization: Bearer <JWT>`.
2. PostgREST validates the JWT (`PGRST_JWT_SECRET`; in production a JWKS file
   fetched from Azure by `rotate-keys.sh`, in debug mode a shared HS256 secret).
3. PostgREST executes `SET LOCAL ROLE <preferred_username>` and calls
   `pre.request()`, which stores the user's id in `cyanaudit.uid` so audit rows
   are attributed.
4. The query runs against `api.*` as that role; RLS and grants apply; INSTEAD
   OF triggers translate writes; cyanaudit records column-level changes.

### Onboarding

A first-time user has a valid Azure JWT but no matching database role, so
PostgREST returns a "role does not exist" error. The SPA then calls
`POST /rpc/onboard` (executable by `anon`) with the **id token**;
`api.onboard` validates the token *inside the database* — plpython3u +
`guardpost` against the Azure tenant's JWKS — and calls `auth.create_user`,
which creates the role, grants `basic`, and inserts into `auth.users`.
The SPA retries and proceeds. Note: onboarding therefore requires real Azure
tokens and does not work in debug mode; debug users must already exist
(the initial power user, or users created via the Employees screen).

## Audit — cyanaudit

[Cyanaudit](https://bitbucket.org/neadwerx/cyanaudit) records every column
change (who/what/when/old/new) in the `cyanaudit` schema. It is compiled into
the postgres image, installed by `001.../000.install.cyanaudit.sh`, and
activated for all schemas by `098.activate.cyanaudit.sql`. `admin.*` functions
expose transaction history. Backups dump cyanaudit separately
(`cyanaudit_dump.pl` / `cyanaudit_restore.pl`).

## Database bootstrap (initdb.sh)

There are no migrations. [initdb.sh](../initdb.sh) executes every `.sql`/`.sh`
file under `dtrack/db/sql/` in lexicographic order, inside the running
`postgres` container. Directory names encode the executing identity:

```
dtrack/db/sql/<NNN>.<user-env-var>.<db-env-var>/
  000.postgres_user.postgres_db/         # as superuser on the default DB: create role + DB
  001.postgres_user.postgres_db_app/     # as superuser on dtrack: extensions, roles, cyanaudit
  002.postgres_user_app_admin.postgres_db_app/  # as app admin on dtrack: everything else
```

Files are piped through `envsubst`, so `$POSTGRES_USER_APP`-style variables in
SQL resolve from `.env`. Schema changes are deployed by dump → recreate →
restore (see [runbooks/backup-restore.md](runbooks/backup-restore.md)).

## Front end

`dtrack/ui` is a Vite + TypeScript react-admin app. One `<Resource>` per api
view ([App.tsx](../dtrack/ui/src/App.tsx)); CRUD screens live in
`src/sections/`; the dashboard renders D3 sunburst and calendar charts from
`api.timetracking_summary` / `api.duration_calendar`.

Two wiring modes, switched at build time by `VITE_ENVIRONMENT`:

- **Production/dev**: MSAL (`ra-auth-msal`) against Azure AD; data provider
  `@raphiniert/ra-data-postgrest` attaches the MSAL id token.
- **Debug**: a local login form signs an HS256 JWT in the browser
  (`jsrsasign`) with `VITE_JWT_SECRET` — the same secret PostgREST is given in
  [debug.yaml](../config/docker-compose.overrides/debug.yaml). Any existing
  user's email can be impersonated. Never deploy this mode.

The UI's permission checks (e.g. hiding the Employee column for non-leads)
are cosmetic; real enforcement is RLS in the database.

## Infrastructure

- **Terraform** ([main.tf](../main.tf)): AWS VPC + EC2 per workspace
  (default = staging, `prod`), Cloudflare DNS, GitHub deploy keys. State in S3
  (`backend.tfconf`).
- **Ansible** ([config/ansible/base.playbook.yml](../config/ansible/base.playbook.yml)):
  system updates, Docker, clone repo, render `.env` and
  `docker-compose.override.yaml` (Traefik + TLS via the `staging`/`prod`
  overrides), start stack.
- **GitHub Actions** (deployed-instance operations, not CI):
  [backup.yml](../.github/workflows/backup.yml) — bi-hourly backup with tiered
  retention + automatic test-restore; [rotate-keys.yml](../.github/workflows/rotate-keys.yml)
  — refreshes the Azure JWKS used as PostgREST's JWT secret.

## Trust boundaries worth knowing about

These flow from the design and are useful context when writing tests
(they are *not* an invitation to change application code right now):

- `auth.del_user` only accepts emails matching the hardcoded
  `@hellodnk8n.onmicrosoft.com` domain; `internal.employees_upsert` likewise
  defaults new emails to that domain.
- `internal.aoe_teams_grant_or_revoke_privs` is SECURITY DEFINER and executable
  by `basic` (flagged `TODO: potentially insecure` in the source).
- The FAQ RLS policy hides unpublished rows from everyone, including their
  authors (`power` bypasses RLS, so in practice only `power` manages FAQs).
- Debug mode trusts any bearer of the shared secret; it exists for local
  development and tests only.
