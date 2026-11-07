-- Data-integrity constraints and triggers on the internal tables.
-- Test case ids: docs/test-cases.md
BEGIN;

SELECT plan(9);

-- Fixture: one user and the reference rows a time tracking needs
SELECT auth.create_user('fixture.user@hellodnk8n.onmicrosoft.com');
INSERT INTO internal.activities (name) VALUES ('fixture activity');
INSERT INTO internal.areas_of_work (name) VALUES ('fixture aow');
INSERT INTO internal.projects (name) VALUES ('fixture project');

CREATE FUNCTION pg_temp.fixture_tt_insert(dur interval) RETURNS void LANGUAGE sql AS $$
    INSERT INTO internal.time_trackings (date, duration, user_id, project_id, activity_id, aow_id)
    VALUES (
        CURRENT_DATE,
        dur,
        (SELECT user_id FROM auth.users WHERE username = 'fixture.user'),
        (SELECT project_id FROM internal.projects WHERE name = 'fixture project'),
        (SELECT activity_id FROM internal.activities WHERE name = 'fixture activity'),
        (SELECT aow_id FROM internal.areas_of_work WHERE name = 'fixture aow')
    );
$$;

-- TC-TT-001: durations that are multiples of 15 minutes are accepted
SELECT lives_ok($$SELECT pg_temp.fixture_tt_insert('15 minutes')$$,
    'TC-TT-001: 15 minute duration accepted');
SELECT lives_ok($$SELECT pg_temp.fixture_tt_insert('7.5 hours')$$,
    'TC-TT-001: 7.5 hour duration accepted');
SELECT lives_ok($$SELECT pg_temp.fixture_tt_insert('0 minutes')$$,
    'TC-TT-001: zero duration accepted (in-lieu-of-overtime convention)');

-- TC-TT-002: durations that are not multiples of 15 minutes are rejected
SELECT throws_ok($$SELECT pg_temp.fixture_tt_insert('20 minutes')$$, '23514',
    NULL, 'TC-TT-002: 20 minute duration violates duration_check');
SELECT throws_ok($$SELECT pg_temp.fixture_tt_insert('1 hour 1 minute')$$, '23514',
    NULL, 'TC-TT-002: 61 minute duration violates duration_check');

-- TC-TT-003: the UI's duration format parses to the intended interval
SELECT is('0.25 hrs'::interval, '15 minutes'::interval,
    'TC-TT-003: "0.25 hrs" parses as 15 minutes');
SELECT is('7.50 hrs'::interval, '450 minutes'::interval,
    'TC-TT-003: "7.50 hrs" parses as 7.5 hours');

-- TC-TEAM-001: a member cannot belong to two teams within one area of expertise
SELECT auth.create_user('fixture.lead2@hellodnk8n.onmicrosoft.com');
INSERT INTO internal.areas_of_expertise (name) VALUES ('fixture aoe');
INSERT INTO internal.aoe_hierarchies (aoe_id, lead_id, member_id)
SELECT aoe_id,
       (SELECT user_id FROM auth.users WHERE username = 'fixture.lead2'),
       (SELECT user_id FROM auth.users WHERE username = 'fixture.user')
FROM internal.areas_of_expertise WHERE name = 'fixture aoe';

SELECT throws_ok($$
    INSERT INTO internal.aoe_hierarchies (aoe_id, lead_id, member_id)
    SELECT aoe_id,
           (SELECT user_id FROM auth.users WHERE username = 'fixture.user'),
           (SELECT user_id FROM auth.users WHERE username = 'fixture.user')
    FROM internal.areas_of_expertise WHERE name = 'fixture aoe'
    $$,
    'A member cannot belong to multiple teams within the same area of expertise',
    'TC-TEAM-001: second team membership in same AoE rejected');

-- TC-TEAM-002: the same member may join teams in different areas of expertise
INSERT INTO internal.areas_of_expertise (name) VALUES ('fixture aoe 2');
SELECT lives_ok($$
    INSERT INTO internal.aoe_hierarchies (aoe_id, lead_id, member_id)
    SELECT aoe_id,
           (SELECT user_id FROM auth.users WHERE username = 'fixture.lead2'),
           (SELECT user_id FROM auth.users WHERE username = 'fixture.user')
    FROM internal.areas_of_expertise WHERE name = 'fixture aoe 2'
    $$,
    'TC-TEAM-002: membership in a second AoE accepted');

SELECT * FROM finish();
ROLLBACK;
