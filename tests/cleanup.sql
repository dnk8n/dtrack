-- Remove rows created by previous API and E2E test runs, so those suites
-- always start from a known state and never accumulate residue on a
-- long-lived development database.
--
-- Test entities are recognizable by their reserved name prefixes, which the
-- suites guarantee: entity names starting 'api ' or 'E2E ', time-tracking
-- descriptions starting 'api tt ' or 'E2E logged time ', FAQ questions
-- starting 'api faq '. Those prefixes are reserved for tests — do not use
-- them for real data.
--
-- The api.* personas themselves are kept (their creation is idempotent) and
-- any pm/lead grants they hold are left alone; no suite asserts their
-- absence. Runs as the postgres superuser (bypasses RLS); safe to repeat.
BEGIN;

DELETE FROM internal.time_trackings
WHERE description LIKE 'api tt %'
   OR description LIKE 'E2E logged time %';

DELETE FROM internal.user_project_roles
WHERE project_id IN (
    SELECT project_id FROM internal.projects
    WHERE name LIKE 'api %' OR name LIKE 'E2E %');

DELETE FROM internal.project_activities
WHERE project_id IN (
    SELECT project_id FROM internal.projects
    WHERE name LIKE 'api %' OR name LIKE 'E2E %');

DELETE FROM internal.project_areas_of_work
WHERE project_id IN (
    SELECT project_id FROM internal.projects
    WHERE name LIKE 'api %' OR name LIKE 'E2E %');

DELETE FROM internal.projects
WHERE name LIKE 'api %' OR name LIKE 'E2E %';

DELETE FROM internal.aoe_hierarchies
WHERE aoe_id IN (
    SELECT aoe_id FROM internal.areas_of_expertise
    WHERE name LIKE 'api %' OR name LIKE 'E2E %');

DELETE FROM internal.areas_of_expertise
WHERE name LIKE 'api %' OR name LIKE 'E2E %';

DELETE FROM internal.areas_of_work
WHERE name LIKE 'api %' OR name LIKE 'E2E %';

DELETE FROM internal.activities
WHERE name LIKE 'api %' OR name LIKE 'E2E %';

DELETE FROM internal.faqs
WHERE question LIKE 'api faq %';

COMMIT;
