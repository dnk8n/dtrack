# Testing

The current codebase is the MVP and a deliberate stability baseline (git tag
`mvp-baseline`). The test suite's job is to **pin the behavior of that
baseline** so consolidation work (docs, CI, tooling, later upgrades) can
proceed without silent regressions. Tests assert behavior contracts — who can
see and do what, what the API promises the UI — not incidental details, so
there is room to grow without rewriting tests.

## Policies

1. **Additions are cheap, changes are not.** Any *edit or deletion* of an
   existing test must be called out and explained in the PR. A test change is
   only acceptable when it legitimately improves the system, and is normally
   accompanied by new tests for the adapted behavior.
2. **Genuine bugs become expected failures, not fixes.** When a test exposes a
   real defect in the application, the application is *not* changed (yet); the
   test is committed and marked expected-fail with the reason:
   pgTAP `todo()`, vitest `test.fails`. When the defect is later fixed, the
   harness reports the test as "unexpectedly passing", which forces removing
   the marker — the test then guards the fix.
3. **Every automated test cites a `TC-…` id** from
   [test-cases.md](test-cases.md), the natural-language catalog. CI fails if a
   test references an undocumented id ([tests/check-test-case-ids.sh](../tests/check-test-case-ids.sh)).

## The layers

Business logic lives in PostgreSQL, so the "unit" level for most of this
system is the database itself.

| Layer | Tool | Where | What it covers |
| --- | --- | --- | --- |
| Database (unit + RLS) | [pgTAP](https://pgtap.org) via `pg_prove` | [tests/db/](../tests/db/) | Schema/role invariants, constraints and triggers, `auth.*` functions, row-level security per persona (`SET ROLE`, exactly what PostgREST does), automatic pm/lead grant/revoke |
| API (functional) | [Vitest](https://vitest.dev) + [jose](https://github.com/panva/jose) | [tests/api/](../tests/api/) | The PostgREST surface with per-persona HS256 JWTs (debug secret): authentication, CRUD through the `api` views, RLS at HTTP level, error codes, the UI↔API contract (PostgREST query features the react-admin data provider depends on) |
| End-to-end | [Playwright](https://playwright.dev) | [tests/e2e/](../tests/e2e/) | Real browser against the debug-mode UI: login/logout, the core create-AoW→activity→project→log-time journey through the cascading selects, dashboard render |

### Running locally

```sh
make env     # once: .env and keys from templates
make test    # all three suites in parallel; or test-db / test-api / test-e2e
```

Notes:

- **Each suite runs in its own completely isolated environment** — one
  compose project per suite with its own postgres cluster, PostgREST and UI
  on its own host ports, built from the same compose files as dev/debug plus
  [test.yaml](../config/docker-compose.overrides/test.yaml):

  | suite | project | postgres | API | UI |
  | --- | --- | --- | --- | --- |
  | db | `dtrack-test-db` | 5433 | — | — |
  | api | `dtrack-test-api` | 5434 | 3002 | — |
  | e2e | `dtrack-test-e2e` | 5435 | 3001 | 5175 |

  That's why `make test` ([tests/run-all.sh](../tests/run-all.sh)) can run
  them in parallel, with per-suite output grouped at the end (and captured
  under `tests/logs/`). The dev/debug stack is never touched and doesn't
  need to be running.
- **Every runner recreates its environment from the ground up** — tear down
  the suite's previous environment (containers + volume), bootstrap the
  fresh cluster with the real `initdb.sh`, start the services that suite
  needs ([tests/lib.sh](../tests/lib.sh)). When the run ends the containers
  are **stopped, not removed**: `make test-inspect-<suite>` brings the
  environment back for post-mortem or debugging — it never reruns tests,
  the run's data is still in its volume — until the suite's next run
  clobbers and replaces it.
- **DB tests** run pg_prove inside the test cluster. pgTAP and pg_prove come
  from the postgres image's `test` build target, which the dev compose
  override selects; production builds use the `production` target and carry
  no test tooling.
- The test UI is its own image (`react-admin:test`) because the API base URI
  is baked in at Vite build time — hence the e2e suite owning port 3001,
  which the baked URI and the nginx CSP reference. It rebuilds from cache in
  seconds after the first build.
- A full parallel run costs about a minute once images are cached
  (environment recreation ~20–30 s per suite, overlapped).

## CI

[.github/workflows/ci.yml](../.github/workflows/ci.yml) runs on every PR and
push to main:

- **lint** — UI type-check, eslint and prettier in check mode (no fixes),
  pre-commit hooks (whitespace, shellcheck, terraform), test-case-id check.
- **stack-tests** — `tests/run-all.sh`, exactly as locally: all three suites
  in parallel, each recreating its isolated environment; the dev stack is
  not started in CI at all. On failure it uploads the per-suite logs, the
  Playwright report/traces, and each test environment's container logs as
  artifacts.

## Known defects pinned by expected-fail tests

These were found while writing the baseline suite. They are real application
issues, deliberately **not fixed yet** (the application is frozen); each has an
expected-fail test that will flip when it is fixed.

| Test case | Defect | Root cause |
| --- | --- | --- |
| TC-RLS-012 / TC-PROJ-105 | Any project member can update the project (name, dates, description) | `select_projects_policy` on `internal.projects` was created without `FOR SELECT`, making it a permissive `FOR ALL` policy whose USING clause also authorizes UPDATE/DELETE ([014.schema.policies.sql](../dtrack/db/sql/002.postgres_user_app_admin.postgres_db_app/014.schema.policies.sql)) |
| TC-EMP-106 | Employees cannot edit their own profile (403) although `update_users_policy` intends self-updates | `internal.employees_upsert` writes via `INSERT … ON CONFLICT DO UPDATE`, and only `power` has INSERT on `auth.users` ([015.schema.employees.sql](../dtrack/db/sql/002.postgres_user_app_admin.postgres_db_app/015.schema.employees.sql)) |
| TC-SEC-001 | `basic` can execute `internal.aoe_teams_grant_or_revoke_privs`, a SECURITY DEFINER function that grants/revokes the `lead` role | Explicit `GRANT EXECUTE … TO basic`, flagged `TODO: This is potentially insecure, fix` in [013.project_aoe_functions.sql](../dtrack/db/sql/002.postgres_user_app_admin.postgres_db_app/013.project_aoe_functions.sql) |

Worth knowing, but pinned as current behavior rather than xfail: `Prefer:
return=representation` returns null generated ids because the INSTEAD OF
triggers return `NEW` as-is (TC-API-205), and debug-mode onboarding is
impossible by design — `api.onboard` validates real Azure tokens in-database
(TC-ONB-101/TC-ONB-001).

## Design decisions & self-review

Decisions made building this, with the trade-offs considered:

1. **pgTAP baked into a `test` image stage** (revised 2026-07-15; originally
   apt-installed into the running container while image changes were out of
   scope). The Dockerfile's final `test` stage layers pgTAP/pg_prove on top
   of `production`; the base compose file pins `target: production` so
   deploys are byte-identical to before, and the dev override selects
   `target: test`. Test runs are now offline-capable and deterministic, and
   the container is fully ephemeral — nothing is installed at runtime.
2. **Markdown catalog over a test-management system.** Kiwi TCMS/TestLink
   style tools add a server, accounts and drift risk for a one-team repo;
   markdown + a CI grep gives ids, review-in-PR and zero infrastructure.
   *Revisit* if non-engineers need to author cases or the catalog outgrows a
   single file.
3. **TypeScript everywhere above SQL.** Vitest for API tests instead of
   pytest/Hurl keeps one language across UI, API tests and E2E, one lockfile,
   one `npm ci` in CI. The `tests/` package is fully separate from
   `dtrack/ui` so the app's frozen `package.json`/`yarn.lock` (which feed the
   production image build) are never touched.
4. **E2E authenticates via debug mode, not MSAL.** The debug login signs the
   same JWT shape PostgREST validates in production; only the signature
   scheme (HS256 shared secret vs Azure JWKS) differs, and that half is
   pinned by TC-AUTH-102/103. Real-MSAL login and onboarding remain a manual
   staging check (TC-ONB-001). Testing MSAL itself would mean automating a
   third-party login page — brittle and out of scope.
5. **UI unit tests deferred** (TC-UI-001/002 planned). Almost all logic lives
   in SQL; the UI's own pure logic is small, and adding a test runner to the
   frozen UI package risks changing `yarn.lock` and therefore the production
   image. The E2E journey covers the highest-risk UI behavior (the cascading
   selects and data provider wiring). *Revisit* when the UI toolchain is
   unfrozen — then add Vitest + Testing Library inside `dtrack/ui`.
6. **CI boots the real compose stack** rather than service containers or
   mocks: the exact images production runs, bootstrapped by the real
   `initdb.sh`. Slower (image build dominates; ~10 min uncached) but it tests
   reality, including the bootstrap scripts themselves. *Revisit*: add Docker
   layer caching (`docker/build-push-action` with GHA cache) when the cycle
   time starts to hurt.
7. **Assertions are deliberately loose where the contract is fuzzy** — e.g.
   "status ≥ 400" where PostgREST's exact code may change across upgrades,
   exact codes (`42501`, `23514`) where they are the contract. List/count
   assertions filter by run-scoped names so suites tolerate existing data.
8. **Parallel across suites, sequential within a suite.** Each suite owns an
   environment, so `make test` runs the three suites concurrently; *inside*
   a suite, tests still run sequentially (vitest `fileParallelism: false`,
   Playwright `workers: 1`) because they share that suite's database.
   Finer-grained parallelism would need per-worker environments — not worth
   it at this size.
9. **Fully isolated per-suite test environments, recreated per runner
   invocation and stopped afterwards** (Dean's design, 2026-07-16; two
   earlier iterations — prefix-based data cleanup, then template-cloned
   databases inside the shared dev cluster — were superseded). A compose
   project per suite gives each its own cluster, PostgREST and UI on its own
   ports, so the bootstrap runs verbatim (no cluster-wide role collisions,
   no PostgREST rebinding, no grant leakage), suites parallelize trivially,
   and teardown is `docker compose down --volumes`. Ending a run with `stop`
   keeps every run's final state retrievable (`make test-inspect-<suite>`)
   at zero idle cost. Trade-off: ~20–30 s recreate per suite and extra
   images on disk; accepted for the simpler mental model — dev and test
   share nothing, suites share nothing.

Known gaps, on purpose: no load/performance tests, no visual regression, no
mutation testing, no property-based RLS fuzzing (a future TC-SEC series),
UI unit level empty. The catalog marks these `planned` where concrete.
