-- Security posture tests that currently FAIL and point at genuine issues in
-- the application. Per the testing policy (docs/testing.md) they are kept
-- committed but marked TODO (pgTAP's expected-fail), so they don't break the
-- suite; when the underlying issue is fixed, pg_prove reports them as
-- "unexpectedly succeeded" and the todo marker must be removed.
BEGIN;

SELECT plan(1);

-- TC-SEC-001: privilege-syncing function should not be executable by basic.
-- internal.aoe_teams_grant_or_revoke_privs is SECURITY DEFINER and can grant
-- or revoke the `lead` role, yet EXECUTE is granted to `basic` (the source
-- marks this "TODO: This is potentially insecure, fix").
SELECT * FROM todo('aoe_teams_grant_or_revoke_privs is executable by basic; flagged TODO in 013.project_aoe_functions.sql', 1);
SELECT ok(
    NOT has_function_privilege('basic', 'internal.aoe_teams_grant_or_revoke_privs(integer)', 'EXECUTE'),
    'TC-SEC-001: basic cannot execute internal.aoe_teams_grant_or_revoke_privs');

SELECT * FROM finish();
ROLLBACK;
