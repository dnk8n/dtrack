# Bringing a new installation into use

What to do after a fresh installation, once sign-in works (see
[new-tenant.md](new-tenant.md)): who does what, in which order, and what
only the power user can do. The same steps apply locally in `make dev` mode.

## Roles in practice

Every user is a Postgres role, and what they can see and do is enforced by
the database (details in [architecture.md](../architecture.md#identity-roles-and-authorization)):

| Role | How someone gets it | What it is for |
| --- | --- | --- |
| `basic` | Automatically, the first time they sign in | Logging their own time; seeing the projects and teams they belong to |
| `pm` | Automatically, when they are made lead of a project | Managing their projects: members, areas of work, activities, details; seeing the people on their projects |
| `lead` | Automatically, when they lead an area-of-expertise team | Seeing and correcting their team members' time (time visibility follows teams, not projects) |
| `power` | `POSTGRES_USER_APP_POWER` at `initdb`, or granted by another power user (Employees screen, `is_power`) | Administration. Bypasses row-level security: sees and can change everything |

Treat `power` as an administrator account: use it for the configuration
below and nothing else. Day-to-day work (project staffing, time entry,
review) belongs to ordinary accounts, so the audit log shows who really did
what.

## What only the power user can do

The database reserves these for `power`:

1. **Areas of work** (where work happens, e.g. an office, field sites,
   remote) and **activities** (kinds of work, e.g. field research, software
   development). Only power may create or delete them.
2. **Creating a project and naming its lead.** A project can only be inserted
   by its own lead, which is impossible before it exists, and naming a lead
   grants them `pm`. After that the lead manages the project.
3. **Areas of expertise and their teams**: creating an area of expertise,
   choosing a team's lead (line manager), and placing people in the team.
4. **Placing a newcomer the first time.** A lead can only see people already
   in their teams or projects, so they cannot pick someone who has just
   joined. Power places each new person in a team or project once. From
   then on their lead can see them and staff projects with them.
5. User administration: granting or revoking `power`, deleting users.

See #74 for this split.

## Order of work

1. **Administrator signs in** as the power user (`POSTGRES_USER_APP_POWER`).
2. **Everyone else signs in once.** Onboarding creates each of them as
   `basic`. There is no invitation step; anyone in the tenant can sign in.
   (The power user can also create employees on the Employees screen.)
3. **Administrator configures:**
   - areas of work and activities;
   - areas of expertise, and a team for each with its lead and members;
   - projects, each with a lead (and, optionally, start/end dates).
4. **Leads manage their projects:** description, members, and which areas of
   work and activities apply. The time entry form only offers a project's
   linked areas of work and activities.
5. **Everyone logs time** (Time trackings; durations in 15-minute steps).
   Team leads see their members' entries; the dashboard and calendar
   summarise what each person may see.

## Demo data

For a local installation, [dtrack/dev/fixtures/simulated](../../dtrack/dev/fixtures/simulated/README.md)
loads a realistic three-month data set for one lead and one member, following
exactly the split above. It is for local use only, never on a server.

## Known issues

Check the repository's issues for the current list. Ones found while setting
up from scratch:

- The dashboard summary lists each month once per user (or project) for
  leads and power users, which may inflate chart totals. Members' own view
  is correct.
- Saving a team that has only its lead, with an empty member list, fails
  with a duplicate-key error.
- The deploy play wipes the database (BUG-001, see
  [deployment.md](../deployment.md)).
