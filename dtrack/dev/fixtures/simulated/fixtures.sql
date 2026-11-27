-- Simulated fixture data: a small consultancy/NGO with one lead and one
-- member logging time for ~3 months. Run through load.sh, which supplies the
-- psql variables :admin, :lead, :member (emails) and connects as the
-- PostgREST authenticator with PostgREST's search_path (api, public).
--
-- Every step acts as a real application user the way a PostgREST request
-- does: set the role and JWT claims, then run pre.request() so cyanaudit
-- attributes the change to that user. The power user (:admin) is used only
-- where the schema requires power; each such step says why.
--
-- Deterministic: setseed() fixes the random choices. Not idempotent: load
-- into a freshly initialised database (make clean && make initdb).
\set ON_ERROR_STOP on
SET search_path = api, public;

-------------------------------------------------------------------------------
-- 1. Power user: reference data and project shells (power required)
-------------------------------------------------------------------------------
BEGIN;
SELECT set_config('role', :'admin', true),
       set_config('request.jwt.claims',
                  json_build_object('role', :'admin', 'preferred_username', :'admin')::text, true);
SELECT pre.request();

-- POWER: insert_areas_of_work_policy CHECKs pg_has_role('power').
INSERT INTO api.areas_of_work (name) VALUES
    ('Johannesburg office'),
    ('Eastern Cape field sites'),
    ('Remote');

-- POWER: insert_activities_policy CHECKs pg_has_role('power').
INSERT INTO api.activities (name, description) VALUES
    ('Field research', 'Site visits, interviews and household surveys'),
    ('Data analysis', 'Cleaning, analysing and visualising collected data'),
    ('Software development', 'Building and maintaining internal tools'),
    ('Stakeholder meetings', 'Partner, donor and community meetings'),
    ('Reporting & writing', 'Reports, proposals and donor updates'),
    ('Admin & planning', 'Planning, timesheets, email and coordination'),
    ('Training', 'Courses, workshops and mentoring');

-- POWER: a new project can only be inserted by its lead
-- (insert_leads_projects_policy), which is impossible before it exists, so
-- only a BYPASSRLS power user can create one. Naming the lead also grants
-- them pm via auth.grant_priv, which only power may execute. Everything
-- else about the projects is left to the lead (step 2).
INSERT INTO api.projects (name, start_date, end_date, lead_ids, member_ids, aow_ids, activity_ids)
SELECT p.name, p.start_date, p.end_date,
       jsonb_build_array(u.user_id), '[]', '[]', '[]'
FROM (VALUES
        ('Water Access Survey', DATE '2026-08-17', DATE '2027-02-26'),
        ('Donor Reporting Platform', DATE '2026-09-01', DATE '2026-12-11'),
        ('Internal Operations', DATE '2026-01-01', NULL::date)
     ) AS p (name, start_date, end_date)
CROSS JOIN auth.users u
WHERE u.email = :'lead';

-- POWER: areas of expertise have no INSERT policy, and choosing a team's
-- lead (line manager) is reserved for power (internal.upsert_aoe_teams).
-- Placing the member in the team is also done here: select_users_policy
-- only lets a lead see people already in their teams or projects, so the
-- lead cannot pick a newcomer until power has placed them once. After this
-- the lead sees the member and can staff projects (step 2).
INSERT INTO api.areas_of_expertise (name, description)
VALUES ('Monitoring & Evaluation', 'Survey design, impact measurement and reporting');

INSERT INTO api.aoe_teams (aoe, lead, member_ids)
SELECT jsonb_build_object('id', aoe.id), jsonb_build_object('id', l.user_id), jsonb_build_array(m.user_id)
FROM api.areas_of_expertise aoe, auth.users l, auth.users m
WHERE aoe.name = 'Monitoring & Evaluation' AND l.email = :'lead' AND m.email = :'member';
COMMIT;

-------------------------------------------------------------------------------
-- 2. Lead: describe and staff their projects
-------------------------------------------------------------------------------
BEGIN;
SELECT set_config('role', :'lead', true),
       set_config('request.jwt.claims',
                  json_build_object('role', :'lead', 'preferred_username', :'lead')::text, true);
SELECT pre.request();

UPDATE api.projects p
SET description = d.description,
    member_ids = (SELECT jsonb_build_array(user_id) FROM auth.users WHERE email = :'member'),
    aow_ids = (SELECT jsonb_agg(id ORDER BY id) FROM api.areas_of_work WHERE name = ANY (d.aows)),
    activity_ids = (SELECT jsonb_agg(id ORDER BY id) FROM api.activities WHERE name = ANY (d.activities))
FROM (VALUES
        ('Water Access Survey',
         'Household survey of water access across rural Eastern Cape districts',
         ARRAY['Eastern Cape field sites', 'Johannesburg office', 'Remote'],
         ARRAY['Field research', 'Data analysis', 'Stakeholder meetings', 'Reporting & writing']),
        ('Donor Reporting Platform',
         'Web platform that turns programme data into donor-ready reports',
         ARRAY['Johannesburg office', 'Remote'],
         ARRAY['Software development', 'Data analysis', 'Stakeholder meetings']),
        ('Internal Operations',
         'Non-project time: planning, admin and training',
         ARRAY['Johannesburg office', 'Remote'],
         ARRAY['Admin & planning', 'Training', 'Stakeholder meetings'])
     ) AS d (name, description, aows, activities)
WHERE p.name = d.name;

-- Fail loudly if the lead could not see the member (member_ids would be null).
SELECT count(*) = 3 AS staffed
FROM api.projects WHERE jsonb_array_length(member_ids) = 1 \gset
\if :staffed
\else
    \echo 'The lead could not staff the projects (member not visible to the lead?)'
    \quit 1
\endif
COMMIT;

-------------------------------------------------------------------------------
-- 3. Time entries, each user logging their own (2026-09-01 .. 2026-11-27)
-------------------------------------------------------------------------------
-- Weekdays only, skipping Heritage Day (24 Sep) and a few leave days per
-- person. Each day is 6h-8.5h in 15-minute steps, split into 1-3 entries
-- drawn from a per-person mix of (project, activity, area of work).
SELECT setseed(0.42);

CREATE TEMP TABLE fixture_mix (
    who text, project text, activity text, aow text, weight int, note text
);
GRANT SELECT ON fixture_mix TO PUBLIC;
INSERT INTO fixture_mix VALUES
    ('lead',   'Water Access Survey',      'Field research',       'Eastern Cape field sites', 3, 'Household interviews, %s district'),
    ('lead',   'Water Access Survey',      'Stakeholder meetings', 'Eastern Cape field sites', 2, 'Meeting with ward councillors'),
    ('lead',   'Water Access Survey',      'Reporting & writing',  'Johannesburg office',      3, 'Drafting survey findings'),
    ('lead',   'Donor Reporting Platform', 'Stakeholder meetings', 'Remote',                   2, 'Donor check-in call'),
    ('lead',   'Internal Operations',      'Admin & planning',     'Johannesburg office',      3, 'Weekly planning and timesheet review'),
    ('lead',   'Internal Operations',      'Training',             'Remote',                   1, 'Mentoring session'),
    ('member', 'Water Access Survey',      'Field research',       'Eastern Cape field sites', 2, 'Survey data collection, %s district'),
    ('member', 'Water Access Survey',      'Data analysis',        'Remote',                   3, 'Cleaning survey responses'),
    ('member', 'Donor Reporting Platform', 'Software development', 'Johannesburg office',      4, 'Report builder feature work'),
    ('member', 'Donor Reporting Platform', 'Software development', 'Remote',                   3, 'Bug fixes and code review'),
    ('member', 'Donor Reporting Platform', 'Data analysis',        'Remote',                   2, 'Indicator dashboard queries'),
    ('member', 'Internal Operations',      'Admin & planning',     'Johannesburg office',      1, 'Stand-ups and planning'),
    ('member', 'Internal Operations',      'Training',             'Remote',                   1, 'Online course');

-- Generate the plan as the connecting user (deterministic), then insert it
-- as each user.
CREATE TEMP TABLE fixture_plan AS
WITH days AS (
    SELECT d::date AS day
    FROM generate_series(DATE '2026-09-01', DATE '2026-11-27', INTERVAL '1 day') d
    WHERE extract(isodow FROM d) < 6
      AND d::date <> DATE '2026-09-24'   -- Heritage Day
),
people AS (
    SELECT 'lead' AS who, ARRAY[DATE '2026-10-05', DATE '2026-10-06', DATE '2026-10-07', DATE '2026-11-13'] AS leave
    UNION ALL
    SELECT 'member', ARRAY[DATE '2026-09-25', DATE '2026-10-26', DATE '2026-10-27', DATE '2026-10-28', DATE '2026-10-29', DATE '2026-10-30']
),
workdays AS (
    SELECT p.who, d.day,
           24 + floor(random() * 11)::int AS quarters,      -- 6h .. 8.5h
           1 + floor(random() * 3)::int AS parts
    FROM people p CROSS JOIN days d
    WHERE d.day <> ALL (p.leave)
    ORDER BY p.who, d.day
),
slots AS (
    SELECT w.who, w.day, w.quarters, w.parts, s.n, random() AS pick
    FROM workdays w CROSS JOIN LATERAL generate_series(1, w.parts) s (n)
    ORDER BY w.who, w.day, s.n
),
weighted AS (
    SELECT m.*,
           sum(weight) OVER (PARTITION BY who ORDER BY project, activity, aow) AS cum,
           sum(weight) OVER (PARTITION BY who) AS total
    FROM fixture_mix m
)
SELECT s.who, s.day,
       -- split the day's quarters: equal shares, remainder on the first entry
       (s.quarters / s.parts + CASE WHEN s.n = 1 THEN s.quarters % s.parts ELSE 0 END) * INTERVAL '15 minutes' AS duration,
       w.project, w.activity, w.aow,
       format(w.note, (ARRAY['Amathole', 'OR Tambo', 'Chris Hani', 'Joe Gqabi'])[1 + (extract(doy FROM s.day)::int % 4)]) AS description
FROM slots s
JOIN LATERAL (
    SELECT * FROM weighted w
    WHERE w.who = s.who AND w.cum > floor(s.pick * w.total)
    ORDER BY w.cum
    LIMIT 1
) w ON true;
GRANT SELECT ON fixture_plan TO PUBLIC;

BEGIN;
SELECT set_config('role', :'lead', true),
       set_config('request.jwt.claims',
                  json_build_object('role', :'lead', 'preferred_username', :'lead')::text, true);
SELECT pre.request();
INSERT INTO api.time_trackings (date, duration, description, "user", project, activity, aow)
SELECT f.day, f.duration::text, f.description,
       jsonb_build_object('id', auth.get_current_user_id()),
       jsonb_build_object('id', p.id), jsonb_build_object('id', a.id), jsonb_build_object('id', w.id)
FROM fixture_plan f
JOIN api.projects p ON p.name = f.project
JOIN api.activities a ON a.name = f.activity
JOIN api.areas_of_work w ON w.name = f.aow
WHERE f.who = 'lead'
ORDER BY f.day;
COMMIT;

BEGIN;
SELECT set_config('role', :'member', true),
       set_config('request.jwt.claims',
                  json_build_object('role', :'member', 'preferred_username', :'member')::text, true);
SELECT pre.request();
INSERT INTO api.time_trackings (date, duration, description, "user", project, activity, aow)
SELECT f.day, f.duration::text, f.description,
       jsonb_build_object('id', auth.get_current_user_id()),
       jsonb_build_object('id', p.id), jsonb_build_object('id', a.id), jsonb_build_object('id', w.id)
FROM fixture_plan f
JOIN api.projects p ON p.name = f.project
JOIN api.activities a ON a.name = f.activity
JOIN api.areas_of_work w ON w.name = f.aow
WHERE f.who = 'member'
ORDER BY f.day;
COMMIT;
