# Simulated fixture data

Realistic-looking local data for trying the app with real logins: a small
consultancy/NGO with one lead and one member, logging time on weekdays from
2026-09-01 to 2026-11-27. It is not part of `initdb` and is never loaded on
servers.

## Load

All three users must already exist: they signed in once (onboarding), or the
power user created them on the Employees screen. Start from a fresh database
that has nothing in it but those users:

```sh
FIXTURE_LEAD=lena.lead@example.com \
FIXTURE_MEMBER=bob.basic@example.com \
  dtrack/dev/fixtures/simulated/load.sh
```

`FIXTURE_ADMIN` defaults to `POSTGRES_USER_APP_POWER` from `.env`. The script
is deterministic (seeded) but not idempotent. To load it again, run
`make clean && make initdb`, sign the users in again, then rerun it.

## What it creates

| Who acts | What | Why this user |
| --- | --- | --- |
| power | 3 areas of work, 7 activities | only power may insert them (RLS) |
| power | 3 projects, each with the lead as its lead | a new project can only be inserted by its lead (impossible before it exists) or by BYPASSRLS power, and naming a lead grants `pm` via `auth.grant_priv` (power only) |
| power | AoE "Monitoring & Evaluation", team led by the lead with the member in it | AoEs have no INSERT policy, choosing a team lead is power-only, and a lead can only see people already in their teams or projects, so power has to place the member once |
| lead | project descriptions, the member, areas of work and activities on each project | leads manage their own projects |
| lead, member | ~120 time entries each, 6–8.5 h per worked day | each user logs their own time |

Each step runs as that user the way a PostgREST request does (role, JWT
claims, `pre.request()`), so the audit log attributes changes to the right
person. Weekends, Heritage Day (24 Sep) and a few leave days per person are
skipped.
