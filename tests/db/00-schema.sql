-- Schema sanity: the objects the API and UI depend on exist and are guarded.
-- Deliberately loose (existence + security posture), so the schema can grow
-- without breaking these tests. Test case ids: docs/test-cases.md
BEGIN;

SELECT plan(38);

-- TC-SCH-001: base tables exist
SELECT has_table('auth', 'users', 'TC-SCH-001: auth.users exists');
SELECT has_table('internal', 'activities', 'TC-SCH-001: internal.activities exists');
SELECT has_table('internal', 'areas_of_work', 'TC-SCH-001: internal.areas_of_work exists');
SELECT has_table('internal', 'projects', 'TC-SCH-001: internal.projects exists');
SELECT has_table('internal', 'project_activities', 'TC-SCH-001: internal.project_activities exists');
SELECT has_table('internal', 'project_areas_of_work', 'TC-SCH-001: internal.project_areas_of_work exists');
SELECT has_table('internal', 'user_project_roles', 'TC-SCH-001: internal.user_project_roles exists');
SELECT has_table('internal', 'time_trackings', 'TC-SCH-001: internal.time_trackings exists');
SELECT has_table('internal', 'areas_of_expertise', 'TC-SCH-001: internal.areas_of_expertise exists');
SELECT has_table('internal', 'aoe_hierarchies', 'TC-SCH-001: internal.aoe_hierarchies exists');
SELECT has_table('internal', 'faqs', 'TC-SCH-001: internal.faqs exists');

-- TC-SCH-002: api views exist (the PostgREST surface)
SELECT has_view('api', 'employees', 'TC-SCH-002: api.employees exists');
SELECT has_view('api', 'current_employee', 'TC-SCH-002: api.current_employee exists');
SELECT has_view('api', 'all_employees', 'TC-SCH-002: api.all_employees exists');
SELECT has_view('api', 'activities', 'TC-SCH-002: api.activities exists');
SELECT has_view('api', 'areas_of_work', 'TC-SCH-002: api.areas_of_work exists');
SELECT has_view('api', 'projects', 'TC-SCH-002: api.projects exists');
SELECT has_view('api', 'areas_of_expertise', 'TC-SCH-002: api.areas_of_expertise exists');
SELECT has_view('api', 'aoe_teams', 'TC-SCH-002: api.aoe_teams exists');
SELECT has_view('api', 'time_trackings', 'TC-SCH-002: api.time_trackings exists');
SELECT has_view('api', 'faqs', 'TC-SCH-002: api.faqs exists');
SELECT has_view('api', 'duration_calendar', 'TC-SCH-002: api.duration_calendar exists');

-- TC-SCH-003: API entry-point functions exist
SELECT has_function('api', 'onboard', ARRAY['text'], 'TC-SCH-003: api.onboard exists');
SELECT has_function('pre', 'request', 'TC-SCH-003: pre.request exists');
SELECT has_function('api', 'timetracking_summary', 'TC-SCH-003: api.timetracking_summary exists');

-- TC-SCH-004: row-level security is enabled on all guarded tables
SELECT ok(
    (SELECT bool_and(relrowsecurity)
     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE (n.nspname, c.relname) IN (
         ('auth', 'users'),
         ('internal', 'projects'),
         ('internal', 'user_project_roles'),
         ('internal', 'project_areas_of_work'),
         ('internal', 'areas_of_work'),
         ('internal', 'project_activities'),
         ('internal', 'activities'),
         ('internal', 'time_trackings'),
         ('internal', 'areas_of_expertise'),
         ('internal', 'aoe_hierarchies'),
         ('internal', 'faqs')
     )),
    'TC-SCH-004: RLS enabled on auth.users and all internal tables'
);

-- TC-SCH-005: access roles exist
SELECT has_role('anon', 'TC-SCH-005: role anon exists');
SELECT has_role('basic', 'TC-SCH-005: role basic exists');
SELECT has_role('pm', 'TC-SCH-005: role pm exists');
SELECT has_role('lead', 'TC-SCH-005: role lead exists');
SELECT has_role('power', 'TC-SCH-005: role power exists');

-- TC-SCH-006: privilege tiers are cumulative
SELECT is_member_of('basic', 'pm', 'TC-SCH-006: pm inherits basic');
SELECT is_member_of('basic', 'lead', 'TC-SCH-006: lead inherits basic');
SELECT is_member_of('pm', 'power', 'TC-SCH-006: power inherits pm');
SELECT is_member_of('lead', 'power', 'TC-SCH-006: power inherits lead');

-- TC-SCH-007: power bypasses row-level security
SELECT ok(
    (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'power'),
    'TC-SCH-007: power has BYPASSRLS'
);

-- TC-SCH-008: anon has no access to data views (API surface is opt-in)
SELECT ok(
    NOT has_table_privilege('anon', 'api.employees', 'SELECT'),
    'TC-SCH-008: anon cannot select api.employees'
);
SELECT ok(
    NOT has_table_privilege('anon', 'api.time_trackings', 'SELECT'),
    'TC-SCH-008: anon cannot select api.time_trackings'
);

SELECT * FROM finish();
ROLLBACK;
