-- Automatic privilege management: project leads gain/lose `pm`,
-- AoE team supervisors gain/lose `lead`. Test case ids: docs/test-cases.md
BEGIN;

SELECT plan(8);

SELECT auth.create_user('auto.lead@hellodnk8n.onmicrosoft.com');
SELECT auth.create_user('auto.member@hellodnk8n.onmicrosoft.com');
SELECT auth.create_user('auto.power@hellodnk8n.onmicrosoft.com');
SELECT auth.grant_power('auto.power@hellodnk8n.onmicrosoft.com');
INSERT INTO internal.areas_of_expertise (name) VALUES ('auto aoe');

SET ROLE "auto.power@hellodnk8n.onmicrosoft.com";

---------------------------------------------------------------
-- Projects: lead_ids drive the pm role
---------------------------------------------------------------
-- TC-PROJ-001: creating a project through the api view with a lead grants pm
INSERT INTO api.projects (name, lead_ids, member_ids, activity_ids, aow_ids)
VALUES ('auto project',
        (SELECT jsonb_build_array(user_id) FROM auth.users WHERE username = 'auto.lead'),
        (SELECT jsonb_build_array(user_id) FROM auth.users WHERE username = 'auto.member'),
        '[]'::jsonb, '[]'::jsonb);

SELECT isnt_empty(
    $$SELECT 1 FROM internal.projects WHERE name = 'auto project'$$,
    'TC-PROJ-001: project created through api view');
SELECT results_eq(
    $$SELECT count(*)::int FROM internal.user_project_roles upr
      JOIN internal.projects p USING (project_id) WHERE p.name = 'auto project'$$,
    $$VALUES (2)$$,
    'TC-PROJ-001: lead and member membership rows created');
SELECT is_member_of('pm', 'auto.lead@hellodnk8n.onmicrosoft.com',
    'TC-PROJ-001: project lead was granted pm');

-- TC-PROJ-002: removing the lead revokes pm (when they lead nothing else)
UPDATE api.projects
SET lead_ids = '[]'::jsonb
WHERE id = (SELECT project_id FROM internal.projects WHERE name = 'auto project');

SELECT ok(
    NOT pg_has_role('auto.lead@hellodnk8n.onmicrosoft.com', 'pm', 'MEMBER'),
    'TC-PROJ-002: pm revoked after removal as lead');

---------------------------------------------------------------
-- AoE teams: supervising a team drives the lead role
---------------------------------------------------------------
-- TC-TEAM-010: upserting a team through the api view grants lead to its supervisor
INSERT INTO api.aoe_teams (aoe, lead, member_ids)
SELECT jsonb_build_object('id', aoe_id),
       (SELECT jsonb_build_object('id', user_id) FROM auth.users WHERE username = 'auto.lead'),
       (SELECT jsonb_build_array(user_id) FROM auth.users WHERE username = 'auto.member')
FROM internal.areas_of_expertise WHERE name = 'auto aoe';

SELECT results_eq(
    $$SELECT count(*)::int FROM internal.aoe_hierarchies ah
      JOIN internal.areas_of_expertise aoe USING (aoe_id) WHERE aoe.name = 'auto aoe'$$,
    $$VALUES (1)$$,
    'TC-TEAM-010: hierarchy row created');
SELECT is_member_of('lead', 'auto.lead@hellodnk8n.onmicrosoft.com',
    'TC-TEAM-010: team supervisor was granted lead');

-- TC-TEAM-011: deleting the team (as power) removes it and revokes lead
DELETE FROM api.aoe_teams
WHERE (aoe->>'id')::int = (SELECT aoe_id FROM internal.areas_of_expertise WHERE name = 'auto aoe')
  AND (lead->>'id')::int = (SELECT user_id FROM auth.users WHERE username = 'auto.lead');

SELECT is_empty(
    $$SELECT 1 FROM internal.aoe_hierarchies ah
      JOIN internal.areas_of_expertise aoe USING (aoe_id) WHERE aoe.name = 'auto aoe'$$,
    'TC-TEAM-011: hierarchy rows removed by power delete');
SELECT ok(
    NOT pg_has_role('auto.lead@hellodnk8n.onmicrosoft.com', 'lead', 'MEMBER'),
    'TC-TEAM-011: lead revoked after team deletion');

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
