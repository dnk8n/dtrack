-- auth.* user and membership management functions.
-- Test case ids: docs/test-cases.md
BEGIN;

SELECT plan(12);

-- TC-EMP-001: create_user creates a NOLOGIN role, grants basic, inserts auth.users
SELECT auth.create_user('test.person@hellodnk8n.onmicrosoft.com', 'Test', 'Person', 'Engineer');
SELECT has_role('test.person@hellodnk8n.onmicrosoft.com',
    'TC-EMP-001: role created for new user');
SELECT is_member_of('basic', 'test.person@hellodnk8n.onmicrosoft.com',
    'TC-EMP-001: new user is granted basic');
SELECT results_eq(
    $$SELECT username, first_name, last_name, position FROM auth.users
      WHERE email = 'test.person@hellodnk8n.onmicrosoft.com'$$,
    $$VALUES ('test.person'::text, 'Test'::text, 'Person'::text, 'Engineer'::text)$$,
    'TC-EMP-001: auth.users row created, username derived from email');

-- TC-EMP-002: create_user is an upsert on username
SELECT auth.create_user('test.person@hellodnk8n.onmicrosoft.com', 'Renamed', 'Person', 'Manager');
SELECT results_eq(
    $$SELECT first_name, position FROM auth.users
      WHERE email = 'test.person@hellodnk8n.onmicrosoft.com'$$,
    $$VALUES ('Renamed'::text, 'Manager'::text)$$,
    'TC-EMP-002: re-creating an existing user updates profile fields');
SELECT is(
    (SELECT count(*)::int FROM auth.users WHERE username = 'test.person'),
    1, 'TC-EMP-002: no duplicate row on upsert');

-- TC-EMP-003: create_user derives first/last name from dotted email local part
SELECT auth.create_user('jane.doe@hellodnk8n.onmicrosoft.com');
SELECT results_eq(
    $$SELECT first_name, last_name FROM auth.users WHERE username = 'jane.doe'$$,
    $$VALUES ('jane'::text, 'doe'::text)$$,
    'TC-EMP-003: names default from email local part');

-- TC-EMP-004: del_user refuses emails outside the allowed domain
SELECT throws_ok(
    $$SELECT auth.del_user('someone@example.com')$$,
    'Invalid email format: someone@example.com',
    'TC-EMP-004: del_user rejects foreign domains');

-- TC-EMP-005: del_user drops role and row for the allowed domain
SELECT auth.del_user('jane.doe@hellodnk8n.onmicrosoft.com');
SELECT hasnt_role('jane.doe@hellodnk8n.onmicrosoft.com', 'TC-EMP-005: role dropped');
SELECT is_empty(
    $$SELECT 1 FROM auth.users WHERE username = 'jane.doe'$$,
    'TC-EMP-005: auth.users row deleted');

-- TC-AUTH-001: membership predicates
SELECT auth.create_user('pred.lead@hellodnk8n.onmicrosoft.com');
SELECT auth.create_user('pred.member@hellodnk8n.onmicrosoft.com');
INSERT INTO internal.projects (name) VALUES ('pred project');
INSERT INTO internal.user_project_roles (user_id, project_id, is_lead)
VALUES
    ((SELECT user_id FROM auth.users WHERE username = 'pred.lead'),
     (SELECT project_id FROM internal.projects WHERE name = 'pred project'), TRUE),
    ((SELECT user_id FROM auth.users WHERE username = 'pred.member'),
     (SELECT project_id FROM internal.projects WHERE name = 'pred project'), FALSE);

SELECT ok(auth.is_project_member(
        (SELECT user_id FROM auth.users WHERE username = 'pred.member'),
        (SELECT project_id FROM internal.projects WHERE name = 'pred project')),
    'TC-AUTH-001: is_project_member true for member');
SELECT ok(NOT auth.is_project_member(
        (SELECT user_id FROM auth.users WHERE username = 'pred.member'),
        (SELECT project_id FROM internal.projects WHERE name = 'pred project'),
        is_lead => true),
    'TC-AUTH-001: is_project_member(is_lead) false for plain member');
SELECT ok(auth.is_pm_of(
        (SELECT user_id FROM auth.users WHERE username = 'pred.lead'),
        (SELECT user_id FROM auth.users WHERE username = 'pred.member')),
    'TC-AUTH-001: is_pm_of true for lead over member of same project');

SELECT * FROM finish();
ROLLBACK;
