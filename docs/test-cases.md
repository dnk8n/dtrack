# Test case catalog

Every automated test references a test case id from this catalog (enforced in
CI by [tests/check-test-case-ids.sh](../tests/check-test-case-ids.sh)). The
catalog is the natural-language source of truth for *what the system promises*;
the automated suites are its executable expression. It intentionally lives
in-repo as markdown — reviewable in PRs, greppable, zero extra infrastructure —
rather than in an external test-management system (see
[testing.md](testing.md) for that trade-off).

**Id scheme**: `TC-<AREA>-<NNN>`. Within an area, `0xx` are database-level
cases (pgTAP), `1xx`+ are HTTP/API-level cases, and `TC-E2E-*` are browser
journeys. A journey may be implemented as several serial specs
(`TC-E2E-010a…e`).

**Status values**
- `automated` — implemented and expected to pass
- `xfail` — implemented and expected to **fail**: it documents a genuine bug
  in the application, kept per the testing policy until the bug is fixed
- `manual` — a documented procedure, not automatable in local/CI environments
- `planned` — worth automating, not yet implemented

## Schema & roles (database)

| Id | Test case | Status |
| --- | --- | --- |
| TC-SCH-001 | All base tables exist in `auth`/`internal` | automated |
| TC-SCH-002 | All `api` views that PostgREST serves exist | automated |
| TC-SCH-003 | API entry-point functions exist (`api.onboard`, `pre.request`, `api.timetracking_summary`) | automated |
| TC-SCH-004 | Row-level security is enabled on `auth.users` and every `internal` table | automated |
| TC-SCH-005 | Access roles `anon`, `basic`, `pm`, `lead`, `power` exist | automated |
| TC-SCH-006 | Privilege tiers are cumulative: pm/lead inherit basic, power inherits pm and lead | automated |
| TC-SCH-007 | `power` bypasses row-level security | automated |
| TC-SCH-008 | `anon` has no SELECT on data views — API access is opt-in per role | automated |

## Authentication & onboarding

| Id | Test case | Status |
| --- | --- | --- |
| TC-AUTH-001 | Membership predicates (`is_project_member`, `is_pm_of`) answer correctly for members and leads | automated |
| TC-AUTH-101 | Anonymous requests to data endpoints are refused | automated |
| TC-AUTH-102 | A JWT with an invalid signature is rejected with 401 | automated |
| TC-AUTH-103 | A valid JWT naming a non-existent user is rejected (role does not exist) | automated |
| TC-AUTH-104 | An authenticated user retrieves themself via `current_employee`, including roles and `is_power` | automated |
| TC-AUTH-105 | The OpenAPI description is served at the API root | automated |
| TC-ONB-101 | `POST /rpc/onboard` is callable anonymously and rejects invalid id tokens | automated |
| TC-ONB-001 | First login of an unknown Azure user onboards them (role + `auth.users` row) and the SPA proceeds | manual — needs a real Azure id token; verified in staging |

## Employees & user management

| Id | Test case | Status |
| --- | --- | --- |
| TC-EMP-001 | `auth.create_user` creates a NOLOGIN role, grants `basic`, inserts the users row, derives the username from the email | automated |
| TC-EMP-002 | `auth.create_user` upserts: re-creating an existing username updates profile fields without duplicating rows | automated |
| TC-EMP-003 | First/last name default from the dotted email local part | automated |
| TC-EMP-004 | `auth.del_user` rejects emails outside the allowed domain | automated |
| TC-EMP-005 | `auth.del_user` drops the role and deletes the users row for the allowed domain | automated |
| TC-EMP-101 | A power user can create an employee through `POST /employees` | automated |
| TC-EMP-102 | A newly created employee can authenticate and see themself | automated |
| TC-EMP-103 | A basic user cannot create employees | automated |
| TC-EMP-104 | An unrelated user sees only themself in the employees list | automated |
| TC-EMP-105 | A power user can update another employee's profile | automated |
| TC-EMP-106 | An employee can update their own profile fields | **xfail** — `internal.employees_upsert` writes via `INSERT … ON CONFLICT`, and only `power` has INSERT on `auth.users`, so self-updates 403 despite `update_users_policy` intending them |

## Projects

| Id | Test case | Status |
| --- | --- | --- |
| TC-PROJ-001 | Creating a project through `api.projects` with a lead creates membership rows and grants the lead `pm` | automated |
| TC-PROJ-002 | Removing a project's lead revokes `pm` when they lead no other project | automated |
| TC-PROJ-101 | A project created with lead, member, AoW and activity links reads back with all of them | automated |
| TC-PROJ-102 | Being made project lead is visible as the `pm` role on `current_employee` | automated |
| TC-PROJ-103 | The project lead can update their project | automated |
| TC-PROJ-104 | Unrelated users cannot see the project | automated |
| TC-PROJ-105 | A non-lead member cannot update the project | **xfail** — `select_projects_policy` lacks `FOR SELECT`, so as a permissive FOR ALL policy it authorizes member updates too (same bug as TC-RLS-012) |
| TC-PROJ-106 | Members see their project in the list | automated |

## Teams / areas of expertise

| Id | Test case | Status |
| --- | --- | --- |
| TC-TEAM-001 | A member cannot belong to two teams within one area of expertise | automated |
| TC-TEAM-002 | The same member may join teams in different areas of expertise | automated |
| TC-TEAM-010 | Upserting a team through `api.aoe_teams` creates hierarchy rows and grants its supervisor `lead` | automated |
| TC-TEAM-011 | Deleting a team as power removes its rows and revokes `lead` | automated |

## Reference data (areas of work, activities)

| Id | Test case | Status |
| --- | --- | --- |
| TC-AOW-101 | Power can create an area of work | automated |
| TC-AOW-102 | Basic users cannot create areas of work | automated |
| TC-AOW-103 | Areas of work are readable by all authenticated users | automated |
| TC-ACT-101 | Power can create an activity | automated |
| TC-ACT-102 | Basic users cannot create activities | automated |

## Time tracking

| Id | Test case | Status |
| --- | --- | --- |
| TC-TT-001 | Durations that are multiples of 15 minutes are accepted (including zero) | automated |
| TC-TT-002 | Durations that are not multiples of 15 minutes are rejected | automated |
| TC-TT-003 | The UI's `"N.NN hrs"` duration format parses to the intended interval | automated |
| TC-TT-101 | A member can log their own time through the API in UI duration format | automated |
| TC-TT-102 | A member cannot log time for someone else | automated |
| TC-TT-103 | A team lead sees and can log their members' entries | automated |
| TC-TT-104 | Outsiders see none of these entries | automated |
| TC-TT-105 | The API rejects durations that are not multiples of 15 minutes | automated |

## Row-level security (cross-cutting)

| Id | Test case | Status |
| --- | --- | --- |
| TC-RLS-001 | Members see only their own time trackings | automated |
| TC-RLS-002 | Members cannot insert time trackings for others | automated |
| TC-RLS-003 | Writes through `api.time_trackings` respect RLS and parse the UI duration format | automated |
| TC-RLS-004 | Team leads see their members' time trackings | automated |
| TC-RLS-005 | Team leads can log time for their members | automated |
| TC-RLS-006 | Outsiders see no time trackings of others | automated |
| TC-RLS-010 | Outsiders cannot see a project they don't belong to | automated |
| TC-RLS-011 | Members see their own project | automated |
| TC-RLS-012 | Non-lead members cannot update the project | **xfail** — see TC-PROJ-105 |
| TC-RLS-013 | Project leads can update their project | automated |
| TC-RLS-014 | Non-power users cannot create brand-new projects | automated |
| TC-RLS-020 | Basic users cannot create reference data | automated |
| TC-RLS-021 | Power users can create reference data | automated |
| TC-RLS-030 | Unrelated users see only themselves in `auth.users` | automated |
| TC-RLS-031 | Members also see their team lead | automated |

## FAQs

| Id | Test case | Status |
| --- | --- | --- |
| TC-FAQ-001 | Only published FAQs are visible to regular users (database level) | automated |
| TC-FAQ-002 | Regular users cannot create FAQs (database level) | automated |
| TC-FAQ-101 | Power can create published and draft FAQs | automated |
| TC-FAQ-102 | Basic users see only published FAQs | automated |
| TC-FAQ-103 | Basic users cannot create FAQs | automated |
| TC-FAQ-104 | Power sees drafts too | automated |

## Dashboard plots

| Id | Test case | Status |
| --- | --- | --- |
| TC-PLOT-101 | `duration_calendar` aggregates a user's entries | automated |
| TC-PLOT-102 | The `timetracking_summary` RPC responds for the calling user | automated |
| TC-PLOT-001 | `timetracking_summary` totals equal the sum of the underlying entries across zoom levels | planned — pgTAP |

## UI ↔ API contract

The PostgREST features `@raphiniert/ra-data-postgrest` and the UI's queries
rely on; they must keep working across PostgREST upgrades.

| Id | Test case | Status |
| --- | --- | --- |
| TC-API-201 | Column aliasing via `select=id,name:username` | automated |
| TC-API-202 | JSONB containment filters on embedded relations (`areas_of_work=cs.[{"id":N}]`) | automated |
| TC-API-203 | Exact counts via `Prefer: count=exact` (Content-Range) | automated |
| TC-API-204 | Ordering by nested JSONB fields (`order=user->name.asc`) | automated |
| TC-API-205 | `Prefer: return=representation` returns the created row (note: generated ids are currently null in the representation — a quirk of the INSTEAD OF triggers) | automated |
| TC-API-206 | JSONB arrow filters used by list filters (`user->>id=eq.N`) | automated |

## Security posture

| Id | Test case | Status |
| --- | --- | --- |
| TC-SEC-001 | `internal.aoe_teams_grant_or_revoke_privs` is not executable by `basic` | **xfail** — it currently is (SECURITY DEFINER; flagged `TODO: potentially insecure` in the source) |

## End-to-end journeys (browser)

| Id | Test case | Status |
| --- | --- | --- |
| TC-E2E-001 | The power user logs in via the debug login, sees the navigation, and can log out | automated |
| TC-E2E-002 | An unknown user cannot reach the workspace | automated |
| TC-E2E-010 | Core journey (serial specs a–e): create AoW → activity → project (linked, with manager) → log time through the cascading selects → entry appears in the list | automated |
| TC-E2E-020 | The dashboard renders for a user with data | automated |
| TC-E2E-030 | Role-based UI: a plain member does not see other employees' entries or admin-only actions | planned — needs multi-user browser personas |
| TC-E2E-040 | FAQ lifecycle through the UI: create draft, publish, verify member visibility | planned |

## UI unit level

| Id | Test case | Status |
| --- | --- | --- |
| TC-UI-001 | CSV export mapping and id generation in `dtrack/ui/src/utils/utils.tsx` behave as specified | planned — deferred while the UI toolchain (package.json/yarn.lock feeding the production image build) is frozen; see testing.md |
| TC-UI-002 | Date-range helpers in `utils/Dropdowns.tsx` compute correct default ranges per granularity | planned — same constraint |

## Operational procedures

| Id | Test case | Status |
| --- | --- | --- |
| TC-OPS-001 | A production backup restores onto a fresh instance and the app works against it | manual — [runbook](runbooks/backup-restore.md); exercised continuously by the backup workflow's test-restore job |
