-- Row-level security: who can see and write what.
-- Runs as superuser and impersonates personas with SET ROLE, exactly as
-- PostgREST does after validating a JWT. Test case ids: docs/test-cases.md
BEGIN;

SELECT plan(19);

-- Fixture personas: a team lead, their team member, an unrelated outsider,
-- and a power user. Everything rolls back at the end.
SELECT auth.create_user('rls.lead@hellodnk8n.onmicrosoft.com');
SELECT auth.create_user('rls.member@hellodnk8n.onmicrosoft.com');
SELECT auth.create_user('rls.outsider@hellodnk8n.onmicrosoft.com');
SELECT auth.create_user('rls.power@hellodnk8n.onmicrosoft.com');
SELECT auth.grant_power('rls.power@hellodnk8n.onmicrosoft.com');

INSERT INTO internal.areas_of_expertise (name) VALUES ('rls aoe');
INSERT INTO internal.aoe_hierarchies (aoe_id, lead_id, member_id)
SELECT aoe_id,
       (SELECT user_id FROM auth.users WHERE username = 'rls.lead'),
       (SELECT user_id FROM auth.users WHERE username = 'rls.member')
FROM internal.areas_of_expertise WHERE name = 'rls aoe';

INSERT INTO internal.projects (name) VALUES ('rls project');
INSERT INTO internal.user_project_roles (user_id, project_id, is_lead)
VALUES
    ((SELECT user_id FROM auth.users WHERE username = 'rls.lead'),
     (SELECT project_id FROM internal.projects WHERE name = 'rls project'), TRUE),
    ((SELECT user_id FROM auth.users WHERE username = 'rls.member'),
     (SELECT project_id FROM internal.projects WHERE name = 'rls project'), FALSE);

INSERT INTO internal.activities (name) VALUES ('rls activity');
INSERT INTO internal.areas_of_work (name) VALUES ('rls aow');

INSERT INTO internal.time_trackings (description, date, duration, user_id, project_id, activity_id, aow_id)
SELECT descr, CURRENT_DATE, '30 minutes',
       (SELECT user_id FROM auth.users WHERE username = uname),
       (SELECT project_id FROM internal.projects WHERE name = 'rls project'),
       (SELECT activity_id FROM internal.activities WHERE name = 'rls activity'),
       (SELECT aow_id FROM internal.areas_of_work WHERE name = 'rls aow')
FROM (VALUES ('rls entry member', 'rls.member'), ('rls entry lead', 'rls.lead')) AS f(descr, uname);

INSERT INTO internal.faqs (question, answer, is_published)
VALUES ('rls published?', 'yes', TRUE), ('rls draft?', 'no', FALSE);

---------------------------------------------------------------
-- Time trackings
---------------------------------------------------------------
SET ROLE "rls.member@hellodnk8n.onmicrosoft.com";

-- TC-RLS-001: members see only their own time trackings
SELECT results_eq(
    $$SELECT description FROM internal.time_trackings WHERE description LIKE 'rls entry%'$$,
    $$VALUES ('rls entry member'::text)$$,
    'TC-RLS-001: member sees only own time trackings');

-- TC-RLS-002: members cannot log time for someone else
SELECT throws_ok($$
    INSERT INTO internal.time_trackings (date, duration, user_id, project_id, activity_id, aow_id)
    SELECT CURRENT_DATE, '15 minutes',
        (SELECT user_id FROM auth.users WHERE email = 'rls.lead@hellodnk8n.onmicrosoft.com'),
        (SELECT project_id FROM internal.projects WHERE name = 'rls project'),
        (SELECT activity_id FROM internal.activities WHERE name = 'rls activity'),
        (SELECT aow_id FROM internal.areas_of_work WHERE name = 'rls aow')
    $$, '42501', NULL,
    'TC-RLS-002: member cannot insert a time tracking for their lead');

-- TC-RLS-003: writes through the api view respect RLS and parse the UI duration format
SELECT lives_ok($$
    INSERT INTO api.time_trackings (description, date, duration, "user", project, activity, aow)
    SELECT 'rls entry via api', CURRENT_DATE, '0.25 hrs',
        jsonb_build_object('id', (SELECT user_id FROM auth.users WHERE username = 'rls.member')),
        jsonb_build_object('id', (SELECT project_id FROM internal.projects WHERE name = 'rls project')),
        jsonb_build_object('id', (SELECT activity_id FROM internal.activities WHERE name = 'rls activity')),
        jsonb_build_object('id', (SELECT aow_id FROM internal.areas_of_work WHERE name = 'rls aow'))
    $$,
    'TC-RLS-003: member can log own time through api view');
SELECT results_eq(
    $$SELECT duration FROM internal.time_trackings WHERE description = 'rls entry via api'$$,
    $$VALUES ('15 minutes'::interval)$$,
    'TC-RLS-003: "0.25 hrs" stored as 15 minutes');

RESET ROLE;
SET ROLE "rls.lead@hellodnk8n.onmicrosoft.com";

-- TC-RLS-004: team leads see their members' time trackings
SELECT results_eq(
    $$SELECT count(*)::int FROM internal.time_trackings WHERE description LIKE 'rls entry%'$$,
    $$VALUES (3)$$,
    'TC-RLS-004: lead sees own and member entries');

-- TC-RLS-005: team leads can log time for their members
SELECT lives_ok($$
    INSERT INTO internal.time_trackings (description, date, duration, user_id, project_id, activity_id, aow_id)
    SELECT 'rls entry by lead for member', CURRENT_DATE, '15 minutes',
        (SELECT user_id FROM auth.users WHERE email = 'rls.member@hellodnk8n.onmicrosoft.com'),
        (SELECT project_id FROM internal.projects WHERE name = 'rls project'),
        (SELECT activity_id FROM internal.activities WHERE name = 'rls activity'),
        (SELECT aow_id FROM internal.areas_of_work WHERE name = 'rls aow')
    $$,
    'TC-RLS-005: lead inserts entry for member');

RESET ROLE;
SET ROLE "rls.outsider@hellodnk8n.onmicrosoft.com";

-- TC-RLS-006: outsiders see nothing of others' data
SELECT is_empty(
    $$SELECT 1 FROM internal.time_trackings WHERE description LIKE 'rls entry%'$$,
    'TC-RLS-006: outsider sees no rls time trackings');

---------------------------------------------------------------
-- Projects
---------------------------------------------------------------
-- TC-RLS-010: outsiders cannot see the project
SELECT is_empty(
    $$SELECT 1 FROM internal.projects WHERE name = 'rls project'$$,
    'TC-RLS-010: outsider cannot see project');

RESET ROLE;
SET ROLE "rls.member@hellodnk8n.onmicrosoft.com";

-- TC-RLS-011: members see their project
SELECT isnt_empty(
    $$SELECT 1 FROM internal.projects WHERE name = 'rls project'$$,
    'TC-RLS-011: member sees own project');

RESET ROLE;
SET ROLE "rls.lead@hellodnk8n.onmicrosoft.com";

-- TC-RLS-013: project leads can update their project
UPDATE internal.projects SET description = 'updated by lead' WHERE name = 'rls project';
SELECT results_eq(
    $$SELECT description FROM internal.projects WHERE name = 'rls project'$$,
    $$VALUES ('updated by lead'::text)$$,
    'TC-RLS-013: lead update persisted');

-- TC-RLS-014: creating a brand-new project is denied to non-power users
SELECT throws_ok(
    $$INSERT INTO internal.projects (name) VALUES ('rls new project')$$,
    '42501', NULL,
    'TC-RLS-014: lead cannot create an unrelated new project');

RESET ROLE;
SET ROLE "rls.member@hellodnk8n.onmicrosoft.com";

-- TC-RLS-012: non-lead members should not be able to update the project.
-- KNOWN BUG (expected failure): select_projects_policy is created without
-- FOR SELECT, making it a permissive FOR ALL policy, so its USING clause
-- also authorizes UPDATE/DELETE for every project member. Fixing it means
-- adding FOR SELECT (and re-checking update_leads_projects_policy coverage).
UPDATE internal.projects SET name = 'rls hacked' WHERE name = 'rls project';
RESET ROLE;
SELECT * FROM todo('select_projects_policy lacks FOR SELECT, members can update projects', 1);
SELECT is_empty(
    $$SELECT 1 FROM internal.projects WHERE name = 'rls hacked'$$,
    'TC-RLS-012: member update affected no rows');

---------------------------------------------------------------
-- Reference data (activities / areas of work)
---------------------------------------------------------------
SET ROLE "rls.member@hellodnk8n.onmicrosoft.com";

-- TC-RLS-020: reference data is read-only for non-power users
SELECT throws_ok(
    $$INSERT INTO internal.areas_of_work (name) VALUES ('rls new aow')$$,
    '42501', NULL,
    'TC-RLS-020: basic cannot create areas of work');
SELECT throws_ok(
    $$INSERT INTO internal.activities (name) VALUES ('rls new activity')$$,
    '42501', NULL,
    'TC-RLS-020: basic cannot create activities');

RESET ROLE;
SET ROLE "rls.power@hellodnk8n.onmicrosoft.com";

-- TC-RLS-021: power users manage reference data
SELECT lives_ok(
    $$INSERT INTO internal.areas_of_work (name) VALUES ('rls power aow')$$,
    'TC-RLS-021: power creates area of work');

---------------------------------------------------------------
-- Users
---------------------------------------------------------------
RESET ROLE;
SET ROLE "rls.outsider@hellodnk8n.onmicrosoft.com";

-- TC-RLS-030: unrelated users see only themselves in auth.users
SELECT results_eq(
    $$SELECT email FROM auth.users WHERE email LIKE 'rls.%'$$,
    $$VALUES ('rls.outsider@hellodnk8n.onmicrosoft.com'::text)$$,
    'TC-RLS-030: outsider sees only self');

RESET ROLE;
SET ROLE "rls.member@hellodnk8n.onmicrosoft.com";

-- TC-RLS-031: members also see their team lead (and vice versa)
SELECT results_eq(
    $$SELECT count(*)::int FROM auth.users WHERE email IN
      ('rls.member@hellodnk8n.onmicrosoft.com', 'rls.lead@hellodnk8n.onmicrosoft.com')$$,
    $$VALUES (2)$$,
    'TC-RLS-031: member sees self and their lead');

---------------------------------------------------------------
-- FAQs
---------------------------------------------------------------
-- TC-FAQ-001: only published FAQs are visible to regular users
SELECT results_eq(
    $$SELECT question FROM internal.faqs WHERE question LIKE 'rls%'$$,
    $$VALUES ('rls published?'::text)$$,
    'TC-FAQ-001: draft FAQ hidden from basic user');

-- TC-FAQ-002: regular users cannot create FAQs
SELECT throws_ok(
    $$INSERT INTO internal.faqs (question, answer, is_published) VALUES ('x', 'y', TRUE)$$,
    '42501', NULL,
    'TC-FAQ-002: basic cannot insert FAQ');

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
