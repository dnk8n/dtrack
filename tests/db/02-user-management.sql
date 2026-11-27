-- auth.* user and membership management functions.
-- Test case ids: docs/test-cases.md
BEGIN;

SELECT plan(16);

-- TC-EMP-001: create_user creates a NOLOGIN role, grants basic, inserts auth.users
SELECT auth.create_user('test.person@example.com', 'Test', 'Person', 'Engineer');
SELECT has_role('test.person@example.com',
    'TC-EMP-001: role created for new user');
SELECT is_member_of('basic', 'test.person@example.com',
    'TC-EMP-001: new user is granted basic');
SELECT results_eq(
    $$SELECT username, first_name, last_name, position FROM auth.users
      WHERE email = 'test.person@example.com'$$,
    $$VALUES ('test.person'::text, 'Test'::text, 'Person'::text, 'Engineer'::text)$$,
    'TC-EMP-001: auth.users row created, username derived from email');

-- TC-EMP-002: create_user is an upsert on username
SELECT auth.create_user('test.person@example.com', 'Renamed', 'Person', 'Manager');
SELECT results_eq(
    $$SELECT first_name, position FROM auth.users
      WHERE email = 'test.person@example.com'$$,
    $$VALUES ('Renamed'::text, 'Manager'::text)$$,
    'TC-EMP-002: re-creating an existing user updates profile fields');
SELECT is(
    (SELECT count(*)::int FROM auth.users WHERE username = 'test.person'),
    1, 'TC-EMP-002: no duplicate row on upsert');

-- TC-EMP-003: create_user derives first/last name from dotted email local part
SELECT auth.create_user('jane.doe@example.com');
SELECT results_eq(
    $$SELECT first_name, last_name FROM auth.users WHERE username = 'jane.doe'$$,
    $$VALUES ('jane'::text, 'doe'::text)$$,
    'TC-EMP-003: names default from email local part');

-- TC-EMP-004: del_user refuses anything that is not an application user
SELECT throws_ok(
    $$SELECT auth.del_user('someone@example.com')$$,
    'Not an application user: someone@example.com',
    'TC-EMP-004: del_user rejects an email with no auth.users row');
SELECT throws_ok(
    $$SELECT auth.del_user('power')$$,
    'Not an application user: power',
    'TC-EMP-004: del_user cannot drop a system role');
SELECT has_role('power', 'TC-EMP-004: power role still exists');

-- TC-EMP-005: del_user drops role and row of an application user
SELECT auth.del_user('jane.doe@example.com');
SELECT hasnt_role('jane.doe@example.com', 'TC-EMP-005: role dropped');
SELECT is_empty(
    $$SELECT 1 FROM auth.users WHERE username = 'jane.doe'$$,
    'TC-EMP-005: auth.users row deleted');

-- TC-EMP-006: an employee created without an email gets the creator's domain
SELECT auth.create_user('test.power@example.org');
SELECT auth.grant_power('test.power@example.org');
SET ROLE "test.power@example.org";
INSERT INTO api.employees (username, first_name, last_name)
VALUES ('new.hire', 'New', 'Hire');
RESET ROLE;
SELECT results_eq(
    $$SELECT email FROM auth.users WHERE username = 'new.hire'$$,
    $$VALUES ('new.hire@example.org'::text)$$,
    'TC-EMP-006: email domain taken from the creating user, not hard-coded');

-- TC-EMP-007: without an email or a domain to derive, creation fails loudly
SELECT throws_like(
    $$INSERT INTO api.employees (username, first_name, last_name)
      VALUES ('no.domain', 'No', 'Domain')$$,
    '%email is required%',
    'TC-EMP-007: no email and no caller domain raises');

-- TC-AUTH-001: membership predicates
SELECT auth.create_user('pred.lead@example.com');
SELECT auth.create_user('pred.member@example.com');
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
