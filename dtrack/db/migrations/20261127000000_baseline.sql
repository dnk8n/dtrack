-- migrate:up
-- Baseline: the whole application schema as it stood when dbmate was
-- introduced (#47), squashed from the files initdb.sh used to run in order
-- (dtrack/db/sql/002.postgres_user_app_admin.postgres_db_app/<file>).
-- Applied by dbmate as the `admin` role, inside one transaction, on top of
-- the superuser bootstrap in dtrack/db/bootstrap/. Never edit this file:
-- every later change is a new migration (see docs/development.md).

-- ===========================================================================
-- 000.schema.roles.sql
-- ===========================================================================

-- Revoke public function execution
ALTER DEFAULT PRIVILEGES
REVOKE
EXECUTE ON FUNCTIONS
FROM
    PUBLIC;

-- privileges are cumulative (except pm and lead are in line)
GRANT basic TO pm;

GRANT basic TO lead;

GRANT pm TO power;

GRANT lead TO power;

GRANT power TO admin;

-- Allow each role to login via authenticator
GRANT anon TO authenticator;

GRANT basic TO authenticator;

GRANT pm TO authenticator;

GRANT lead TO authenticator;

GRANT power TO authenticator;

-- Internal schema is home to main data
CREATE SCHEMA internal;

ALTER DEFAULT PRIVILEGES IN SCHEMA internal
GRANT
SELECT
,
    INSERT,
    DELETE,
UPDATE ON TABLES TO basic;

-- change to soft delete
ALTER DEFAULT PRIVILEGES IN SCHEMA internal
GRANT
SELECT
,
    USAGE ON SEQUENCES TO basic;

-- Views abstract what data is allowed to be consumed by the API
CREATE SCHEMA api;

ALTER DEFAULT PRIVILEGES IN SCHEMA api
GRANT
SELECT
,
    INSERT,
    DELETE,
UPDATE ON TABLES TO basic;

-- change to soft delete
ALTER DEFAULT PRIVILEGES IN SCHEMA api
GRANT
SELECT
,
    USAGE ON SEQUENCES TO basic;

-- Schema usage
GRANT USAGE ON SCHEMA api TO anon;

GRANT USAGE ON SCHEMA api TO basic;

GRANT USAGE ON SCHEMA internal TO basic;

GRANT USAGE ON SCHEMA auth TO basic;

-- Allow PostgREST login
GRANT CONNECT ON DATABASE dtrack TO authenticator;

-- Allow basic and above access to executing functions
GRANT
EXECUTE ON ALL FUNCTIONS IN SCHEMA api TO basic;

-- ===========================================================================
-- 001.schema.tables.sql
-- ===========================================================================

CREATE TABLE IF NOT EXISTS
    auth.users (
        user_id serial primary key,
        username text unique not null,
        email text unique not null,
        first_name text,
        last_name text,
        position text
    );

GRANT
SELECT
    ON TABLE auth.users TO basic;

GRANT
SELECT
    ON SEQUENCE auth.users_user_id_seq TO basic;

GRANT INSERT,
UPDATE ON TABLE auth.users TO power;

GRANT
UPDATE ON SEQUENCE auth.users_user_id_seq TO power;

CREATE TABLE IF NOT EXISTS
    internal.activities (
        activity_id serial primary key,
        name text unique not null,
        description text
    );

CREATE TABLE IF NOT EXISTS
    internal.areas_of_work (
        aow_id serial primary key,
        name text unique not null
    );

CREATE TABLE IF NOT EXISTS
    internal.projects (
        project_id serial primary key,
        name text unique not null,
        start_date date,
        end_date date,
        description text
    );

CREATE TABLE IF NOT EXISTS
    internal.project_activities (
        project_id integer not null,
        activity_id integer not null,
        primary key (project_id, activity_id),
        foreign key (project_id) references internal.projects (project_id) on delete restrict on update cascade,
        foreign key (activity_id) references internal.activities (activity_id) on delete restrict on update cascade
    );

CREATE TABLE IF NOT EXISTS
    internal.project_areas_of_work (
        project_id integer not null,
        aow_id integer not null,
        primary key (project_id, aow_id),
        foreign key (project_id) references internal.projects (project_id) on delete restrict on update cascade,
        foreign key (aow_id) references internal.areas_of_work (aow_id) on delete restrict on update cascade
    );

CREATE TABLE IF NOT EXISTS
    internal.user_project_roles (
        user_id integer not null,
        project_id integer not null,
        primary key (user_id, project_id),
        foreign key (user_id) references auth.users (user_id) on delete restrict on update cascade,
        foreign key (project_id) references internal.projects (project_id) on delete restrict on update cascade,
        is_lead boolean not null
    );

CREATE TABLE IF NOT EXISTS
    internal.time_trackings (
        task_id serial primary key,
        description text,
        date date not null,
        duration interval not null,
        user_id integer not null,
        project_id integer not null,
        activity_id integer not null,
        aow_id integer not null,
        foreign key (user_id) references auth.users (user_id) on delete restrict on update cascade,
        foreign key (project_id) references internal.projects (project_id) on delete restrict on update cascade,
        foreign key (activity_id) references internal.activities (activity_id) on delete restrict on update cascade,
        foreign key (aow_id) references internal.areas_of_work (aow_id) on delete restrict on update cascade
    );

ALTER TABLE internal.time_trackings
ADD CONSTRAINT duration_check CHECK (
    EXTRACT(
        epoch
        FROM
            duration
    ) % (15 * 60) = 0
);

-- Create the internal.areas_of_expertise table to store information about areas
-- of expertise
CREATE TABLE IF NOT EXISTS
    internal.areas_of_expertise (
        aoe_id serial primary key,
        name text unique not null,
        description text
    );

-- Create the internal.aoe_hierarchies table to store information about the
-- hierarchy of teams within each area of expertise
CREATE TABLE IF NOT EXISTS
    internal.aoe_hierarchies (
        aoe_id integer not null,
        lead_id integer not null,
        member_id integer not null,
        primary key (aoe_id, lead_id, member_id),
        foreign key (aoe_id) references internal.areas_of_expertise (aoe_id) on delete restrict on update cascade,
        foreign key (lead_id) references auth.users (user_id) on delete restrict on update cascade,
        foreign key (member_id) references auth.users (user_id) on delete restrict on update cascade
    );

-- Create a trigger function to check that a member cannot belong to multiple
-- teams within the same area of expertise before allowing an insert or update
-- operation on the internal.aoe_hierarchies table
CREATE
OR REPLACE FUNCTION internal.check_unique_member_per_aoe () RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM internal.aoe_hierarchies WHERE aoe_id = NEW.aoe_id AND member_id = NEW.member_id AND lead_id <> NEW.lead_id) THEN
        RAISE EXCEPTION 'A member cannot belong to multiple teams within the same area of expertise';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create a trigger to execute the check_unique_member_per_aoe function before
-- insert or update operations on the internal.aoe_hierarchies table
CREATE TRIGGER check_unique_member_per_aoe BEFORE INSERT
OR
UPDATE ON internal.aoe_hierarchies FOR EACH ROW
EXECUTE FUNCTION internal.check_unique_member_per_aoe ();

-- ===========================================================================
-- 002.schema.onboard.sql
-- ===========================================================================

CREATE
OR REPLACE FUNCTION auth.create_user (
    email text,
    first_name text DEFAULT NULL,
    last_name text DEFAULT NULL,
    job_position text DEFAULT NULL
) RETURNS integer SECURITY DEFINER
-- Pinned: callers arrive with PostgREST's search_path (api, public). During
-- anonymous onboarding cyanaudit.uid is unset, so cyanaudit resolves its
-- unqualified user_table ('users') through search_path and needs auth (#70).
SET search_path = public, auth AS $$
DECLARE
    username text;
    created_user_id integer;
BEGIN
    username := SUBSTRING(email FROM 1 FOR POSITION('@' IN email) - 1);
    BEGIN
        EXECUTE format('CREATE ROLE %I INHERIT NOLOGIN', email);
    EXCEPTION WHEN duplicate_object THEN
    END;
    EXECUTE format('GRANT %I to authenticator', email);
    EXECUTE format('GRANT basic to %I', email);
    EXECUTE '
        INSERT INTO auth.users (username, email, first_name, last_name, position)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (username)
        DO UPDATE SET
            first_name = EXCLUDED.first_name,
            last_name = EXCLUDED.last_name,
            position = EXCLUDED.position
        RETURNING user_id
    '
    INTO created_user_id
    USING username, email, COALESCE(first_name, split_part(username, '.', 1)), COALESCE(last_name, split_part(username, '.', 2)), job_position;
    RETURN created_user_id;
END;
$$ LANGUAGE plpgsql;

GRANT
EXECUTE ON FUNCTION auth.create_user TO power;

CREATE
OR REPLACE FUNCTION auth.del_user (email text) RETURNS void SECURITY DEFINER AS $$
BEGIN
    -- Only application users (rows in auth.users) may be dropped, so this can
    -- never remove a system role such as power, basic or the authenticator.
    -- format(%I) quotes the identifier, so no further sanitising is needed.
    IF EXISTS (SELECT 1 FROM auth.users u WHERE u.email = del_user.email) THEN
        EXECUTE format('DROP ROLE IF EXISTS %I', email);
        EXECUTE 'DELETE FROM auth.users WHERE email = $1' USING email;
    ELSE
        RAISE EXCEPTION 'Not an application user: %', email;
    END IF;
END;
$$ LANGUAGE plpgsql;

GRANT
EXECUTE ON FUNCTION auth.del_user TO power;

-- TODO: Consider changing onboard function to be an insert on employees
CREATE
OR REPLACE FUNCTION api.onboard (id_token text) RETURNS json SECURITY DEFINER LANGUAGE plpgsql AS $$
DECLARE
    CLAIMS jsonb := auth.decode_id_token(id_token)::jsonb;
    EMAIL text := CLAIMS->>'preferred_username';
BEGIN
    EXECUTE format('SELECT auth.create_user(%L)', EMAIL);
    RETURN format('{
        "status": "success",
        "message": "User, %s successfully onboarded"
    }', EMAIL)::jsonb;
END;
$$;

GRANT
EXECUTE ON FUNCTION api.onboard TO anon;

-- ===========================================================================
-- 003.schema.api_views.sql
-- ===========================================================================

CREATE OR REPLACE VIEW
    api.employees
WITH
    (security_invoker = on) AS
SELECT
    user_id as id,
    username,
    email,
    to_jsonb(roles) as roles,
    'power' = ANY (roles) as is_power,
    first_name,
    last_name,
    position,
    member_of_projects,
    COALESCE(member_of_project_ids, '[]'::jsonb) as member_of_project_ids,
    lead_of_projects,
    COALESCE(lead_of_project_ids, '[]'::jsonb) as lead_of_project_ids,
    COALESCE(member_of_teams, '[]'::jsonb) as member_of_teams,
    COALESCE(member_of_team_ids, '[]'::jsonb) as member_of_team_ids,
    COALESCE(lead_of_teams, '[]'::jsonb) as lead_of_teams,
    COALESCE(lead_of_team_ids, '[]'::jsonb) as lead_of_team_ids
FROM
    auth.users
    LEFT JOIN (
        SELECT
            user_id,
            jsonb_agg(
                jsonb_build_object('id', project_id, 'name', name)
            ) FILTER (
                WHERE
                    is_lead is FALSE
            ) as member_of_projects,
            jsonb_agg(
                jsonb_build_object('id', project_id, 'name', name)
            ) FILTER (
                WHERE
                    is_lead is TRUE
            ) as lead_of_projects,
            jsonb_agg(project_id) FILTER (
                WHERE
                    is_lead is FALSE
            ) as member_of_project_ids,
            jsonb_agg(project_id) FILTER (
                WHERE
                    is_lead is TRUE
            ) as lead_of_project_ids
        FROM
            internal.user_project_roles
            JOIN internal.projects USING (project_id)
        GROUP BY
            user_id
    ) AS user_project_roles_agg USING (user_id)
    LEFT JOIN (
        SELECT
            user_email as email,
            user_roles as roles
        FROM
            auth.get_user_roles ()
    ) AS roles_query USING (email)
    LEFT JOIN (
        SELECT
            lead_id as user_id,
            jsonb_agg(
                DISTINCT jsonb_build_object(
                    'id',
                    LPAD(aoe_id::text, 4, '0') || LPAD(lead_id::text, 4, '0'),
                    'name',
                    aoe.name
                )
            ) as lead_of_teams,
            jsonb_agg(
                DISTINCT LPAD(aoe_id::text, 4, '0') || LPAD(lead_id::text, 4, '0')
            ) as lead_of_team_ids
        FROM
            internal.aoe_hierarchies
            LEFT JOIN internal.areas_of_expertise AS aoe USING (aoe_id)
        GROUP BY
            lead_id
    ) AS lead_team_roles_agg USING (user_id)
    LEFT JOIN (
        SELECT
            member_id as user_id,
            jsonb_agg(
                jsonb_build_object(
                    'id',
                    LPAD(aoe_id::text, 4, '0') || LPAD(lead_id::text, 4, '0'),
                    'name',
                    aoe.name || ' (' || lead.username || ')'
                )
            ) as member_of_teams,
            jsonb_agg(
                LPAD(aoe_id::text, 4, '0') || LPAD(lead_id::text, 4, '0')
            ) as member_of_team_ids
        FROM
            internal.aoe_hierarchies
            LEFT JOIN internal.areas_of_expertise AS aoe USING (aoe_id)
            LEFT JOIN auth.users AS lead ON internal.aoe_hierarchies.lead_id = lead.user_id
        WHERE
            member_id != lead_id
        GROUP BY
            member_id
    ) AS member_team_roles_agg USING (user_id)
WHERE
    email ILIKE '%@%';

CREATE OR REPLACE VIEW
    api.current_employee
WITH
    (security_invoker = on) AS
SELECT
    *
FROM
    api.employees
WHERE
    email = CURRENT_USER;

CREATE OR REPLACE VIEW
    -- RLS is bypassed because view is executed as role of view definer
    api.all_employees AS
SELECT
    id,
    username
FROM
    api.employees;

REVOKE
SELECT
    ON api.all_employees
FROM
    basic;

GRANT
SELECT
    ON api.all_employees TO pm;

GRANT
SELECT
    ON api.all_employees TO lead;

CREATE OR REPLACE VIEW
    api.activities
WITH
    (security_invoker = on) AS
SELECT
    activities.activity_id as id,
    activities.name,
    activities.description,
    jsonb_agg(
        jsonb_build_object('id', projects.project_id, 'name', projects.name)
    ) FILTER (
        WHERE
            projects.project_id IS NOT NULL
    ) AS projects,
    COALESCE(
        jsonb_agg(projects.project_id) FILTER (
            WHERE
                projects.project_id IS NOT NULL
        ),
        '[]'::jsonb
    ) as project_ids
FROM
    internal.activities AS activities
    LEFT JOIN internal.project_activities USING (activity_id)
    LEFT JOIN internal.projects AS projects USING (project_id)
GROUP BY
    activities.activity_id;

CREATE OR REPLACE VIEW
    api.areas_of_work
WITH
    (security_invoker = on) AS
SELECT
    aow.aow_id as id,
    aow.name,
    jsonb_agg(
        jsonb_build_object('id', projects.project_id, 'name', projects.name)
    ) FILTER (
        WHERE
            projects.project_id IS NOT NULL
    ) AS projects,
    COALESCE(
        jsonb_agg(projects.project_id) FILTER (
            WHERE
                projects.project_id IS NOT NULL
        ),
        '[]'::jsonb
    ) as project_ids
FROM
    internal.areas_of_work AS aow
    LEFT JOIN internal.project_areas_of_work USING (aow_id)
    LEFT JOIN internal.projects AS projects USING (project_id)
GROUP BY
    aow.aow_id;

CREATE OR REPLACE VIEW
    api.projects
WITH
    (security_invoker = on) AS
SELECT
    projects.project_id as id,
    leads,
    COALESCE(lead_ids, '[]'::jsonb) as lead_ids,
    members,
    COALESCE(member_ids, '[]'::jsonb) as member_ids,
    projects.name,
    projects.description,
    projects.start_date,
    projects.end_date,
    activities,
    COALESCE(activity_ids, '[]'::jsonb) as activity_ids,
    areas_of_work,
    COALESCE(aow_ids, '[]'::jsonb) as aow_ids
FROM
    internal.projects as projects
    LEFT JOIN (
        SELECT
            project_id,
            jsonb_agg(
                jsonb_build_object('id', user_id, 'name', username)
            ) FILTER (
                WHERE
                    is_lead is TRUE
            ) as leads,
            jsonb_agg(user_id) FILTER (
                WHERE
                    is_lead is TRUE
            ) as lead_ids,
            jsonb_agg(
                jsonb_build_object('id', user_id, 'name', username)
            ) FILTER (
                WHERE
                    is_lead is FALSE
            ) as members,
            jsonb_agg(user_id) FILTER (
                WHERE
                    is_lead is FALSE
            ) as member_ids
        FROM
            internal.user_project_roles
            JOIN auth.users USING (user_id)
        GROUP BY
            project_id
    ) AS user_project_roles_agg USING (project_id)
    LEFT JOIN (
        SELECT
            project_id,
            jsonb_agg(
                jsonb_build_object('id', activity_id, 'name', name)
            ) as activities,
            jsonb_agg(activity_id) as activity_ids
        FROM
            internal.project_activities
            JOIN internal.activities USING (activity_id)
        GROUP BY
            project_id
    ) AS project_activities_agg USING (project_id)
    LEFT JOIN (
        SELECT
            project_id,
            jsonb_agg(jsonb_build_object('id', aow_id, 'name', name)) as areas_of_work,
            jsonb_agg(aow_id) as aow_ids
        FROM
            internal.project_areas_of_work
            JOIN internal.areas_of_work USING (aow_id)
        GROUP BY
            project_id
    ) AS project_aow_agg USING (project_id);

-- Create the internal.aoe_teams view to calculate team hierarchies based on
-- data in the internal.aoe_hierarchies table
CREATE OR REPLACE VIEW
    internal.aoe_teams
WITH
    (security_invoker = on) AS
SELECT
    aoe1.aoe_id,
    CASE
        WHEN aoe1.lead_id IN (
            SELECT
                member_id
            FROM
                internal.aoe_hierarchies
            WHERE
                aoe_id = aoe1.aoe_id
        ) THEN (
            SELECT
                lead_id
            FROM
                internal.aoe_hierarchies
            WHERE
                member_id = aoe1.lead_id
                AND aoe_id = aoe1.aoe_id
        )
        ELSE aoe1.lead_id
    END AS supervisor_id,
    aoe1.lead_id,
    array_agg(DISTINCT aoe2.member_id) FILTER (
        WHERE
            aoe2.member_id IS NOT NULL
            AND aoe2.member_id <> aoe2.lead_id
    ) as member_ids
FROM
    internal.aoe_hierarchies aoe1
    LEFT JOIN internal.aoe_hierarchies aoe2 ON aoe1.aoe_id = aoe2.aoe_id
    AND aoe1.lead_id = aoe2.lead_id
GROUP BY
    aoe1.aoe_id,
    aoe1.lead_id;

-- Create the api.aoe_teams view to expose information about team hierarchies
-- within areas of expertise to API users
CREATE OR REPLACE VIEW
    api.aoe_teams
WITH
    (security_invoker = on) AS
SELECT
    lpad((aoe ->> 'id')::text, 4, '0') || lpad((lead ->> 'id')::text, 4, '0') AS id,
    CASE
        WHEN (
            select
                roles
            from
                api.current_employee
        ) @> '["power"]'::jsonb THEN (aoe ->> 'name')::text || ' (' || (lead ->> 'name')::text || ')'
        ELSE (aoe ->> 'name')::text
    END as name,
    aoe,
    supervisor,
    lead,
    members,
    COALESCE(member_ids, '[]'::jsonb) as member_ids
FROM
    (
        SELECT
            (
                SELECT
                    jsonb_build_object('id', aoe_id, 'name', name)
                FROM
                    internal.areas_of_expertise
                WHERE
                    internal.aoe_teams.aoe_id = internal.areas_of_expertise.aoe_id
            ) AS aoe,
            (
                SELECT
                    jsonb_build_object('id', user_id, 'name', username)
                FROM
                    auth.users
                WHERE
                    internal.aoe_teams.supervisor_id = auth.users.user_id
            ) AS supervisor,
            (
                SELECT
                    jsonb_build_object('id', user_id, 'name', username)
                FROM
                    auth.users
                WHERE
                    internal.aoe_teams.lead_id = auth.users.user_id
            ) AS lead,
            (
                SELECT
                    jsonb_agg(
                        jsonb_build_object('id', user_id, 'name', username)
                    )
                FROM
                    auth.users
                WHERE
                    user_id = ANY (internal.aoe_teams.member_ids)
            ) AS members,
            to_jsonb(member_ids) as member_ids
        FROM
            internal.aoe_teams
    ) aoe_teams;

-- Create the api.areas_of_expertise view to expose information about areas of
-- expertise to API users
CREATE OR REPLACE VIEW
    api.areas_of_expertise
WITH
    (security_invoker = on) AS
WITH
    supervisors_cte AS (
        SELECT
            (aoe ->> 'id')::integer AS aoe_id,
            jsonb_agg(lead) AS supervisors,
            jsonb_agg(DISTINCT (lead ->> 'id')::integer) as supervisor_ids
        FROM
            api.aoe_teams
        WHERE
            supervisor = lead
        GROUP BY
            aoe_id
    )
SELECT
    internal.areas_of_expertise.aoe_id AS id,
    name,
    description,
    supervisors_cte.supervisors,
    COALESCE(supervisors_cte.supervisor_ids, '[]'::jsonb) as supervisor_ids
FROM
    internal.areas_of_expertise
    LEFT JOIN supervisors_cte ON internal.areas_of_expertise.aoe_id = supervisors_cte.aoe_id;

CREATE OR REPLACE VIEW
    api.time_trackings
WITH
    (security_invoker = on) AS
WITH
    teams_cte AS (
        SELECT
            aoe_hierarchies.member_id,
            aoe_hierarchies.lead_id,
            jsonb_agg(
                -- TODO: This is repeated from api.aoe_teams view, try make more DRY
                lpad((aoe_hierarchies.aoe_id)::text, 4, '0') || lpad((aoe_hierarchies.lead_id)::text, 4, '0')
            ) AS aoe_team_ids
        FROM
            internal.aoe_hierarchies AS aoe_hierarchies
        GROUP BY
            aoe_hierarchies.member_id,
            aoe_hierarchies.lead_id
    ),
    teams_union_cte AS (
        SELECT
            user_id,
            jsonb_agg(DISTINCT aoe_team_id) AS aoe_team_ids
        FROM
            (
                SELECT
                    teams_cte.member_id AS user_id,
                    jsonb_array_elements(teams_cte.aoe_team_ids) AS aoe_team_id
                FROM
                    teams_cte
                UNION ALL
                SELECT
                    teams_cte.lead_id AS user_id,
                    jsonb_array_elements(teams_cte.aoe_team_ids) AS aoe_team_id
                FROM
                    teams_cte
                WHERE
                    (
                        SELECT
                            roles
                        FROM
                            api.current_employee
                    ) @> '["power"]'::jsonb
            ) subq
        GROUP BY
            user_id
    ),
    time_trackings_cte AS (
        SELECT
            time_trackings.task_id as id,
            time_trackings.description,
            time_trackings.date,
            to_char(
                round(
                    (
                        extract(
                            epoch
                            FROM
                                time_trackings.duration
                        ) / 3600
                    )::numeric,
                    2
                ),
                'FM999999990.00'
            ) || ' hrs' as duration,
            jsonb_build_object('id', users.user_id, 'name', users.username) AS user,
            jsonb_build_object('id', projects.project_id, 'name', projects.name) AS project,
            jsonb_build_object(
                'id',
                activities.activity_id,
                'name',
                activities.name
            ) AS activity,
            jsonb_build_object('id', aows.aow_id, 'name', aows.name) AS aow,
            teams_union_cte.aoe_team_ids
        FROM
            internal.time_trackings AS time_trackings
            LEFT JOIN auth.users AS users USING (user_id)
            LEFT JOIN internal.projects AS projects USING (project_id)
            LEFT JOIN internal.activities AS activities USING (activity_id)
            LEFT JOIN internal.areas_of_work AS aows USING (aow_id)
            LEFT JOIN teams_union_cte USING (user_id)
    )
SELECT
    *
FROM
    time_trackings_cte;

-- ===========================================================================
-- 004.schema.insert_functions.sql
-- ===========================================================================

CREATE
OR REPLACE FUNCTION api.time_trackings_instead_of_insert () RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO internal.time_trackings (
        description,
        date,
        duration,
        user_id,
        project_id,
        activity_id,
        aow_id
    )
    VALUES (
        NEW.description,
        NEW.date,
        NEW.duration::interval,
        (NEW.user->>'id')::integer,
        (NEW.project->>'id')::integer,
        (NEW.activity->>'id')::integer,
        (NEW.aow->>'id')::integer
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER time_trackings_instead_of_insert INSTEAD OF INSERT ON api.time_trackings FOR EACH ROW
EXECUTE FUNCTION api.time_trackings_instead_of_insert ();

-- This function is a trigger function for upserting Area of Expertise (AoE) teams in the internal.aoe_hierarchies table.
-- It performs various checks and operations such as checking if lead.id is empty, checking if the user has permission to edit AoE or Line Manager,
-- deleting and inserting rows in the internal.aoe_hierarchies table, and updating privileges based on changes.
CREATE
OR REPLACE FUNCTION internal.upsert_aoe_teams () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  new_member_ids jsonb;
BEGIN
  -- The trigger function only operates on INSERT or UPDATE operations
  IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
    -- Check if lead.id is empty
    IF NEW.lead->>'id' IS NULL THEN
      RAISE EXCEPTION 'Lead cannot be empty';
    END IF;

    -- Check if the user has permission to edit AoE or Line Manager
    IF (OLD.lead->>'id' <> NEW.lead->>'id' OR OLD.aoe->>'id' <> NEW.aoe->>'id')
    AND NOT pg_has_role('power', 'MEMBER') THEN
      RAISE EXCEPTION 'Permission denied to edit AoE or Line Manager';
    END IF;

    -- If no value is passed in for members, use the lead.id as the default value
    new_member_ids = COALESCE(NULLIF(NEW.member_ids, '[]'), jsonb_build_array(NEW.lead->>'id'));

    -- Delete only the necessary rows for the given aoe_id and lead_id
    DELETE FROM internal.aoe_hierarchies as aoe_hierarchies
    WHERE aoe_id = (OLD.aoe->>'id')::integer
    AND lead_id = (OLD.lead->>'id')::integer
    AND member_id NOT IN (
        SELECT value::integer
        FROM jsonb_array_elements_text(new_member_ids)
    );

    -- Insert only the necessary rows for each member_id in new_member_ids
    INSERT INTO internal.aoe_hierarchies (aoe_id, lead_id, member_id)
    SELECT
        (NEW.aoe->>'id')::integer,
        (NEW.lead->>'id')::integer,
        new_member_id
    FROM (
        SELECT jsonb_array_elements_text(new_member_ids)::integer AS new_member_id
    ) AS new_members
    WHERE new_member_id NOT IN (
        SELECT value::integer
        FROM jsonb_array_elements_text(OLD.member_ids)
    );

    -- Cleanup placeholder if it exists when it shouldn't (i.e. entry where lead_id = member_id is not the only record for given aoe_id)
    DELETE FROM internal.aoe_hierarchies
    WHERE aoe_id = (NEW.aoe->>'id')::integer
      AND lead_id = (NEW.lead->>'id')::integer
      AND lead_id = member_id
      AND EXISTS (
        SELECT 1 FROM internal.aoe_hierarchies
        WHERE aoe_id = (NEW.aoe->>'id')::integer
          AND lead_id = (NEW.lead->>'id')::integer
          AND lead_id <> member_id
      );

    -- Update privileges based on changes using the internal.aoe_teams_grant_or_revoke_privs function
    PERFORM internal.aoe_teams_grant_or_revoke_privs ((NEW.lead->>'id')::integer);

  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER upsert_aoe_teams INSTEAD OF INSERT
OR
UPDATE ON api.aoe_teams FOR EACH ROW
EXECUTE FUNCTION internal.upsert_aoe_teams ();

-- ===========================================================================
-- 005.schema.update_functions.sql
-- ===========================================================================

CREATE
OR REPLACE FUNCTION api.time_trackings_instead_of_update () RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE internal.time_trackings
    SET description = NEW.description,
        date = NEW.date,
        duration = NEW.duration::interval,
        user_id = (NEW.user->>'id')::integer,
        project_id = (NEW.project->>'id')::integer,
        activity_id = (NEW.activity->>'id')::integer,
        aow_id = (NEW.aow->>'id')::integer
    WHERE task_id = OLD.id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER time_trackings_instead_of_update INSTEAD OF
UPDATE ON api.time_trackings FOR EACH ROW
EXECUTE FUNCTION api.time_trackings_instead_of_update ();

-- ===========================================================================
-- 006.schema.delete_functions.sql
-- ===========================================================================

CREATE
OR REPLACE FUNCTION api.time_trackings_instead_of_delete () RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM internal.time_trackings
    WHERE task_id = OLD.id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER time_trackings_instead_of_delete INSTEAD OF DELETE ON api.time_trackings FOR EACH ROW
EXECUTE FUNCTION api.time_trackings_instead_of_delete ();

CREATE
OR REPLACE FUNCTION auth.auto_aoe_hierarchies_insert (given_aoe_id integer, given_lead_id integer) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM internal.aoe_hierarchies WHERE aoe_id = given_aoe_id AND lead_id = given_lead_id) THEN
        INSERT INTO internal.aoe_hierarchies (aoe_id, lead_id, member_id)
        VALUES (given_aoe_id, given_lead_id, given_lead_id);
    END IF;
END;
$$;

GRANT
EXECUTE ON FUNCTION auth.auto_aoe_hierarchies_insert (given_aoe_id integer, given_lead_id integer) TO lead;

-- TODO: Add description
CREATE
OR REPLACE FUNCTION internal.delete_aoe_teams () RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'DELETE') THEN
        -- Delete rows for the given aoe_id and lead_id
        DELETE FROM internal.aoe_hierarchies WHERE aoe_id = (OLD.aoe->>'id')::integer AND lead_id = (OLD.lead->>'id')::integer;

        -- Power users can fully delete the record, but a lead should only be
        -- able to delete their members from the team, leaving themselves as a placeholder
        IF NOT pg_has_role('power', 'MEMBER') THEN
            PERFORM auth.auto_aoe_hierarchies_insert((OLD.aoe->>'id')::integer, (OLD.lead->>'id')::integer);
        END IF;

        -- Sync privs
        PERFORM internal.aoe_teams_grant_or_revoke_privs ((OLD.lead->>'id')::integer);
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

-- TODO: Add description
CREATE TRIGGER delete_aoe_teams INSTEAD OF DELETE ON api.aoe_teams FOR EACH ROW
EXECUTE FUNCTION internal.delete_aoe_teams ();

-- Create a trigger function to perform upsert operations on the
-- internal.areas_of_expertise table when an insert or update operation is
-- performed on the api.areas_of_expertise view
CREATE
OR REPLACE FUNCTION internal.upsert_areas_of_expertise () RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO internal.areas_of_expertise (name, description)
        VALUES (NEW.name, NEW.description)
        ON CONFLICT (name) DO UPDATE SET description = EXCLUDED.description;
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        UPDATE internal.areas_of_expertise SET name = NEW.name, description = NEW.description WHERE aoe_id = OLD.id;
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Create a trigger to execute the upsert_areas_of_expertise function instead of
-- insert or update operations on the api.areas_of_expertise view
CREATE TRIGGER upsert_areas_of_expertise INSTEAD OF INSERT
OR
UPDATE ON api.areas_of_expertise FOR EACH ROW
EXECUTE FUNCTION internal.upsert_areas_of_expertise ();

CREATE
OR REPLACE FUNCTION internal.delete_areas_of_expertise () RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM internal.areas_of_expertise
    WHERE aoe_id = OLD.id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER delete_areas_of_expertise INSTEAD OF DELETE ON api.areas_of_expertise FOR EACH ROW
EXECUTE FUNCTION internal.delete_areas_of_expertise ();

CREATE
OR REPLACE FUNCTION internal.delete_employee () RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    user_email text;
BEGIN
    DELETE FROM internal.aoe_hierarchies
    WHERE lead_id = OLD.id OR member_id = OLD.id;
    DELETE FROM internal.user_project_roles
    WHERE user_id = OLD.id;
    PERFORM auth.del_user(OLD.email);
    RETURN OLD;
END;
$$;

CREATE TRIGGER delete_employee INSTEAD OF DELETE ON api.employees FOR EACH ROW
EXECUTE FUNCTION internal.delete_employee ();

-- ===========================================================================
-- 007.schema.projects.sql
-- ===========================================================================

CREATE
OR REPLACE FUNCTION internal.projects_upsert () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    new_project_id integer;
    lead_email_revoke text;
    lead_email_grant text;
BEGIN
    IF NEW.id IS NULL THEN
        INSERT INTO internal.projects (name, description, start_date, end_date)
        VALUES (NEW.name, NEW.description, NEW.start_date, NEW.end_date)
        RETURNING project_id INTO new_project_id;
    ELSE
        new_project_id = NEW.ID;
        INSERT INTO internal.projects (project_id, name, description, start_date, end_date)
        VALUES (new_project_id, NEW.name, NEW.description, NEW.start_date, NEW.end_date)
        ON CONFLICT (project_id)
        DO UPDATE SET
            name = NEW.name,
            description = NEW.description,
            start_date = NEW.start_date,
            end_date = NEW.end_date;
    END IF;

    -- Revoke pm role from removed leads
    FOR lead_email_revoke IN
        SELECT u.email
        FROM internal.user_project_roles upr
        JOIN auth.users u USING (user_id)
        WHERE upr.project_id = new_project_id
        AND upr.is_lead IS TRUE
        AND upr.user_id IN (
            SELECT value::integer FROM jsonb_array_elements_text(OLD.lead_ids)
        )
        AND upr.user_id NOT IN (
            SELECT value::integer FROM jsonb_array_elements_text(NEW.lead_ids)
        )
        AND NOT EXISTS (
            SELECT 1
            FROM internal.user_project_roles upr2
            WHERE upr2.user_id = upr.user_id
            AND upr2.project_id <> new_project_id
            AND upr2.is_lead IS TRUE
        )
    LOOP
        PERFORM auth.revoke_priv(lead_email_revoke, 'pm');
    END LOOP;

    -- Grant pm role to new leads if not already
    FOR lead_email_grant IN
        SELECT email
        FROM jsonb_array_elements_text(NEW.lead_ids) AS lead_id
        JOIN api.employees e ON lead_id::integer = e.id
        WHERE NOT e.roles ? 'pm'
    LOOP
        PERFORM auth.grant_priv(lead_email_grant, 'pm');
    END LOOP;

    -- Delete only the necessary user_project_roles records
    DELETE FROM internal.user_project_roles
    WHERE project_id = new_project_id AND (
        (is_lead = FALSE AND user_id NOT IN (SELECT value::integer FROM jsonb_array_elements_text(NEW.member_ids)))
        OR (is_lead = TRUE AND user_id NOT IN (SELECT value::integer FROM jsonb_array_elements_text(NEW.lead_ids)))
    );

    -- Add new members
    INSERT INTO internal.user_project_roles (user_id, project_id, is_lead)
    SELECT member_id::integer, new_project_id, FALSE
    FROM jsonb_array_elements_text(NEW.member_ids) AS member_id
    WHERE member_id::integer NOT IN (SELECT user_id FROM internal.user_project_roles WHERE project_id = new_project_id AND is_lead = FALSE);

    -- Add new leads
    INSERT INTO internal.user_project_roles (user_id, project_id, is_lead)
    SELECT lead_id::integer, new_project_id, TRUE
    FROM jsonb_array_elements_text(NEW.lead_ids) AS lead_id
    WHERE lead_id::integer NOT IN (SELECT user_id FROM internal.user_project_roles WHERE project_id = new_project_id AND is_lead = TRUE);

    -- Delete only the necessary project_areas_of_work records
    DELETE FROM internal.project_areas_of_work
    WHERE project_id = new_project_id AND aow_id NOT IN (SELECT value::integer FROM jsonb_array_elements_text(NEW.aow_ids));

    -- Add new aows
    INSERT INTO internal.project_areas_of_work (project_id, aow_id)
    SELECT new_project_id, aow_id::integer
    FROM jsonb_array_elements_text(NEW.aow_ids) AS aow_id
    WHERE aow_id::integer NOT IN (SELECT aow_id FROM internal.project_areas_of_work WHERE project_id = new_project_id);

    -- Delete only the necessary project_activities records
    DELETE FROM internal.project_activities
    WHERE project_id = new_project_id AND activity_id NOT IN (SELECT value::integer FROM jsonb_array_elements_text(NEW.activity_ids));

    -- Add new activities
    INSERT INTO internal.project_activities (project_id, activity_id)
    SELECT new_project_id, activity_id::integer
    FROM jsonb_array_elements_text(NEW.activity_ids) AS activity_id
    WHERE activity_id::integer NOT IN (SELECT activity_id FROM internal.project_activities WHERE project_id = new_project_id);

    RETURN NEW;
END;
$$;

CREATE TRIGGER projects_instead_of_insert INSTEAD OF INSERT ON api.projects FOR EACH ROW
EXECUTE FUNCTION internal.projects_upsert ();

CREATE TRIGGER projects_instead_of_update INSTEAD OF
UPDATE ON api.projects FOR EACH ROW
EXECUTE FUNCTION internal.projects_upsert ();

CREATE
OR REPLACE FUNCTION internal.projects_delete () RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    lead_email_revoke text;
BEGIN
    -- Revoke pm role from all OLD leads if they aren't also a lead elsewhere
    FOR lead_email_revoke IN
        SELECT u.email
        FROM internal.user_project_roles upr
        JOIN auth.users u USING (user_id)
        WHERE upr.user_id IN (
            SELECT value::integer FROM jsonb_array_elements_text(OLD.lead_ids)
        )
        AND NOT EXISTS (
            SELECT 1
            FROM internal.user_project_roles upr2
            WHERE upr2.user_id = upr.user_id
            AND upr2.project_id <> OLD.id
            AND upr2.is_lead IS TRUE
        )
    LOOP
        PERFORM auth.revoke_priv(lead_email_revoke, 'pm');
    END LOOP;
    -- internal.areas_of_work
    DELETE FROM internal.project_areas_of_work
    WHERE project_id = OLD.id;
    -- internal.activities
    DELETE FROM internal.project_activities
    WHERE project_id = OLD.id;
    -- internal.user_project_roles
    DELETE FROM internal.user_project_roles
    WHERE project_id = OLD.id;
    -- internal.projects
    DELETE FROM internal.projects
    WHERE project_id = OLD.id;
    --
    RETURN OLD;
END;
$$;

CREATE TRIGGER projects_instead_of_delete INSTEAD OF DELETE ON api.projects FOR EACH ROW
EXECUTE FUNCTION internal.projects_delete ();

-- ===========================================================================
-- 008.auth.pre_request.sql
-- ===========================================================================

CREATE SCHEMA pre;

ALTER SCHEMA pre OWNER TO admin;

CREATE
OR REPLACE FUNCTION pre.request () RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_state TEXT;
    v_msg TEXT;
BEGIN
    -- TODO: Consider checking audience and issuer
    PERFORM set_config('cyanaudit.uid', auth.get_current_user_id()::varchar, true);
EXCEPTION
    WHEN insufficient_privilege THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
        RAISE WARNING '%: %', v_state, v_msg;
END;
$$;

GRANT USAGE ON SCHEMA pre TO anon;

GRANT USAGE ON SCHEMA pre TO basic;

GRANT
EXECUTE ON FUNCTION pre.request TO anon;

GRANT
EXECUTE ON FUNCTION pre.request TO basic;

-- ===========================================================================
-- 009.activities.sql
-- ===========================================================================

CREATE
OR REPLACE FUNCTION internal.activities_upsert () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    new_activity_id integer;
BEGIN
    IF NEW.id IS NULL THEN
        INSERT INTO internal.activities (name, description)
        VALUES (NEW.name, NEW.description)
        RETURNING activity_id INTO new_activity_id;
    ELSE
        new_activity_id = NEW.ID;
        INSERT INTO internal.activities (activity_id, name, description)
        VALUES (new_activity_id, NEW.name, NEW.description)
        ON CONFLICT (activity_id)
        DO UPDATE SET
            name = NEW.name,
            description = NEW.description;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER activities_instead_of_insert INSTEAD OF INSERT ON api.activities FOR EACH ROW
EXECUTE FUNCTION internal.activities_upsert ();

CREATE TRIGGER activities_instead_of_update INSTEAD OF
UPDATE ON api.activities FOR EACH ROW
EXECUTE FUNCTION internal.activities_upsert ();

CREATE
OR REPLACE FUNCTION internal.activities_delete () RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM internal.activities
    WHERE activity_id = OLD.id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER activities_instead_of_delete INSTEAD OF DELETE ON api.activities FOR EACH ROW
EXECUTE FUNCTION internal.activities_delete ();

-- ===========================================================================
-- 010.aows.sql
-- ===========================================================================

CREATE
OR REPLACE FUNCTION internal.areas_of_work_upsert () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    new_aow_id integer;
BEGIN
    IF NEW.id IS NULL THEN
        INSERT INTO internal.areas_of_work (name)
        VALUES (NEW.name)
        RETURNING aow_id INTO new_aow_id;
    ELSE
        new_aow_id = NEW.ID;
        INSERT INTO internal.areas_of_work (aow_id, name)
        VALUES (new_aow_id, NEW.name)
        ON CONFLICT (aow_id)
        DO UPDATE SET
            name = NEW.name;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER areas_of_work_instead_of_insert INSTEAD OF INSERT ON api.areas_of_work FOR EACH ROW
EXECUTE FUNCTION internal.areas_of_work_upsert ();

CREATE TRIGGER areas_of_work_instead_of_update INSTEAD OF
UPDATE ON api.areas_of_work FOR EACH ROW
EXECUTE FUNCTION internal.areas_of_work_upsert ();

CREATE
OR REPLACE FUNCTION internal.areas_of_work_delete () RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM internal.areas_of_work
    WHERE aow_id = OLD.id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER areas_of_work_instead_of_delete INSTEAD OF DELETE ON api.areas_of_work FOR EACH ROW
EXECUTE FUNCTION internal.areas_of_work_delete ();

-- ===========================================================================
-- 011.plot_views.sql
-- ===========================================================================

-- Usage: select * from api.daterange_active(array['user_id']);
-- Usage: select * from api.daterange_active();
-- TODO: Relook at this, I had trouble ordering the dateranges in the array_agg because of the DISTINCT keyword
CREATE
OR REPLACE FUNCTION api.daterange_active (dims TEXT[] DEFAULT '{}') RETURNS TABLE (
  id BIGINT,
  dimensions JSONB,
  years DATERANGE[],
  months DATERANGE[],
  weeks DATERANGE[],
  days DATERANGE[]
) SECURITY INVOKER LANGUAGE plpgsql AS $$
DECLARE
  dim TEXT;
  inner_dims TEXT := '';
  outer_dims TEXT;
  final_dims TEXT;
  group_by_list TEXT := 'GROUP BY ';
  final_group_by TEXT;
BEGIN
  FOR dim IN SELECT UNNEST(dims) LOOP
    inner_dims := inner_dims || format('%L, %I,', dim, dim);
    group_by_list := group_by_list || format('%I,', dim);
  END LOOP;
  inner_dims := rtrim(inner_dims, ',');
  group_by_list := rtrim(group_by_list, ',');
  outer_dims := CASE WHEN inner_dims = '' THEN 'NULL::jsonb as dimensions' ELSE format('jsonb_build_object(%s) as dimensions', inner_dims) END;
  final_dims := CASE WHEN inner_dims = '' THEN 'NULL::jsonb as dimensions' ELSE 'dimensions' END;
  group_by_list := CASE WHEN inner_dims = '' THEN '' ELSE group_by_list END;
  final_group_by := CASE WHEN inner_dims = '' THEN '' ELSE 'GROUP BY dimensions' END;
  RETURN QUERY EXECUTE format('
    WITH cte AS (
      SELECT
        %s,
        array_agg(
          DISTINCT daterange (
            date_trunc(''year'', date)::date,
            (date_trunc(''year'', date) + interval ''1 year'')::date,
            ''[)''
          )
        ) AS years,
        array_agg(
          DISTINCT daterange (
            date_trunc(''month'', date)::date,
            (date_trunc(''month'', date) + interval ''1 month'')::date,
            ''[)''
          )
        ) AS months,
        array_agg(
          DISTINCT daterange (
            date_trunc(''week'', date)::date,
            (date_trunc(''week'', date) + interval ''1 week'')::date,
            ''[)''
          )
        ) AS weeks,
        array_agg(
          DISTINCT daterange (
            date_trunc(''day'', date)::date,
            (date_trunc(''day'', date) + interval ''1 day'')::date,
            ''[)''
          )
        ) AS days
      FROM
        internal.time_trackings
        %s
    ),
    expanded_dates AS (
      SELECT
        %s,
        unnest(years) AS year,
        unnest(months) AS month,
        unnest(weeks) AS week,
        unnest(days) AS day
      FROM cte
    )
    SELECT
      ROW_NUMBER() OVER () AS id,
      %s,
      array_agg(year ORDER BY year DESC) FILTER (WHERE year IS NOT NULL) AS years,
      array_agg(month ORDER BY month DESC) FILTER (WHERE month IS NOT NULL) AS months,
      array_agg(week ORDER BY week DESC) FILTER (WHERE week IS NOT NULL) AS weeks,
      array_agg(day ORDER BY day DESC) FILTER (WHERE day IS NOT NULL) AS days
    FROM expanded_dates
    %s
  ', outer_dims, group_by_list, final_dims, final_dims, final_group_by);
END;
$$;

GRANT
EXECUTE ON FUNCTION api.daterange_active TO basic;

-- Usage: select * from internal.timetracking_summary(array['user_id', 'project_id']);
-- Usage: select * from internal.timetracking_summary(array['user_id', 'project_id', 'aow_id', 'activity_id', 'daterange'], date_part := 'week');
-- Usage: select * from internal.timetracking_summary(array['user_id', 'daterange', 'aow_id', 'project_id', 'activity_id'], date_part := 'month');
-- Usage: select * from internal.timetracking_summary(array['user_id', 'aow_id', 'daterange', 'project_id', 'activity_id'], date_part := 'month');
-- Usage: select * from internal.timetracking_summary(array['user_id', 'project_id', 'daterange', 'activity_id', 'aow_id']);
-- Usage: select * from internal.timetracking_summary(array['user_id', 'project_id', 'aow_id', 'activity_id', 'daterange']);
-- Usage: select * from internal.timetracking_summary(array['daterange', 'user_id', 'project_id'], date_part := 'month');
-- Usage: select * from internal.timetracking_summary(array['daterange', 'project_id']);
-- Usage: select * from internal.timetracking_summary(array['project_id']);
-- Usage: select * from internal.timetracking_summary(array['daterange']);
-- Usage: select total_duration from internal.timetracking_summary();
CREATE
OR REPLACE FUNCTION internal.timetracking_summary (
  axes TEXT[] DEFAULT ARRAY[]::TEXT[],
  date_part TEXT DEFAULT 'month'
) RETURNS TABLE (
  user_id INTEGER,
  aow_id INTEGER,
  project_id INTEGER,
  activity_id INTEGER,
  daterange DATERANGE,
  total_duration NUMERIC
) SECURITY INVOKER LANGUAGE plpgsql AS $$
DECLARE
  valid_axes TEXT[];
  axis_value TEXT;
  axis_type TEXT;
  foreign_axes TEXT[];
  null_axes TEXT[];
  group_by_columns TEXT;
  select_columns TEXT;
BEGIN
  -- Define the valid axes values
  valid_axes := ARRAY['user_id', 'aow_id', 'project_id', 'activity_id', 'daterange'];

  -- Check if any elements in the axes argument are not in the valid axes array
  foreign_axes := (select array(select unnest(axes) except select unnest(valid_axes)));

  -- If there are any invalid elements, raise an exception
  IF foreign_axes <> array[]::text[] THEN
    RAISE EXCEPTION 'Invalid axes arguments: %', foreign_axes;
  END IF;

  -- Construct the select and group by columns for the final query using the valid axes array and the axes argument
  select_columns := array_to_string(valid_axes, ', ');
  group_by_columns := CASE
    WHEN array_length(axes, 1) IS NULL THEN ''
    ELSE format('GROUP BY %s', array_to_string(axes, ', '))
  END;

  -- Check if any elements in the valid axes array are not in the axes argument
  null_axes := (SELECT array_agg(x) FROM (SELECT unnest(valid_axes) EXCEPT SELECT unnest(axes)) t(x));

  -- If there are any such elements, set their values to NULL in the select columns
  IF null_axes IS NOT NULL THEN
    FOREACH axis_value IN ARRAY null_axes LOOP
      IF position('_id' in axis_value) > 0 THEN
        axis_type := 'INTEGER';
      ELSIF axis_value = 'daterange' THEN
        axis_type := 'DATERANGE';
      ELSE
        axis_type := 'TEXT';
      END IF;
      select_columns := replace(select_columns, axis_value, format('NULL::%s as %s', axis_type, axis_value));
    END LOOP;
  END IF;

  -- Check if 'daterange' is in the axes argument. If it is, update the select columns to include a date range calculation using the date_part argument.
  IF 'daterange' = ANY(axes) THEN
    select_columns := replace(select_columns, 'daterange', format('daterange(date_trunc(%L, date)::date, (date_trunc(%L, date) + interval ''1 %s'')::date, ''[)'') as daterange', date_part, date_part, date_part));
  END IF;

  -- Add a column for the total duration to the select columns
  select_columns := select_columns || ', ' || 'TRUNC(EXTRACT(epoch FROM SUM(duration))/3600, 2) as total_duration';

  -- Construct and execute a dynamic query using the constructed select and group by columns
  RETURN QUERY EXECUTE format('
    SELECT %s FROM internal.time_trackings %s ORDER BY total_duration DESC
  ', select_columns, group_by_columns);
END;
$$;

GRANT
EXECUTE ON FUNCTION internal.timetracking_summary TO basic;

-- Usage: select "user", project, total_duration from api.timetracking_summary_export(array['user', 'project']);
-- Usage: select * from api.timetracking_summary_export(array['user', 'project', 'aow', 'activity', 'daterange'], date_part := 'week');
-- Usage: select * from api.timetracking_summary_export(array['user', 'daterange', 'aow', 'project', 'activity'], date_part := 'month');
-- Usage: select * from api.timetracking_summary_export(array['user', 'project', 'aow', 'activity', 'daterange'], date_part := 'month');
-- Usage: select * from api.timetracking_summary_export(array['user', 'aow', 'daterange', 'project', 'activity'], date_part := 'month');
-- Usage: select * from api.timetracking_summary_export(array['user', 'project', 'daterange', 'activity', 'aow']);
-- Usage: select * from api.timetracking_summary_export(array['user', 'project', 'aow', 'activity', 'daterange']);
-- Usage: select * from api.timetracking_summary_export(array['daterange', 'user', 'project'], date_part := 'month');
-- Usage: select * from api.timetracking_summary_export(array['daterange', 'project']);
-- Usage: select * from api.timetracking_summary_export(array['project']);
-- Usage: select * from api.timetracking_summary_export(array['daterange']);
-- Usage: select total_duration from api.timetracking_summary_export();
CREATE
OR REPLACE FUNCTION api.timetracking_summary_export (
  axes TEXT[] DEFAULT ARRAY[]::TEXT[],
  date_part TEXT DEFAULT 'month'
) RETURNS TABLE (
  id BIGINT,
  "user" JSONB,
  aow JSONB,
  project JSONB,
  activity JSONB,
  daterange DATERANGE,
  total_duration NUMERIC
) SECURITY INVOKER LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY EXECUTE format('
    SELECT
      ROW_NUMBER() OVER () AS id,
      NULLIF(jsonb_build_object(''id'', u.user_id, ''name'', u.username), jsonb_build_object(''id'', NULL, ''name'', NULL)) AS "user",
      NULLIF(jsonb_build_object(''id'', a.aow_id, ''name'', a.name), jsonb_build_object(''id'', NULL, ''name'', NULL)) AS aow,
      NULLIF(jsonb_build_object(''id'', p.project_id, ''name'', p.name), jsonb_build_object(''id'', NULL, ''name'', NULL)) AS project,
      NULLIF(jsonb_build_object(''id'', ac.activity_id, ''name'', ac.name), jsonb_build_object(''id'', NULL, ''name'', NULL)) AS activity,
      t.daterange,
      t.total_duration
    FROM internal.timetracking_summary(%L, %L) t
    LEFT JOIN auth.users AS u USING (user_id)
    LEFT JOIN internal.areas_of_work AS a USING (aow_id)
    LEFT JOIN internal.projects AS p USING (project_id)
    LEFT JOIN internal.activities AS ac USING (activity_id)
    ORDER BY total_duration DESC
  ', (SELECT array_agg(CASE WHEN axis != 'daterange' THEN axis || '_id' ELSE axis END) FROM unnest(axes) AS axis), date_part);
END;
$$;

GRANT
EXECUTE ON FUNCTION api.timetracking_summary_export TO basic;

-- Usage:
-- select * from api.timetracking_summary(array['user', 'project'], date_part := 'month', zoom_level := 0);
-- select * from api.timetracking_summary(array['user', 'project'], date_part := 'month', zoom_level := 1);
-- select * from api.timetracking_summary(array['user', 'project'], date_part := 'month', zoom_level := 2);
-- select * from api.timetracking_summary(array['user', 'project', 'aow', 'activity', 'daterange'], date_part := 'week');
-- select * from api.timetracking_summary(array['user', 'daterange', 'aow', 'project', 'activity'], date_part := 'month', zoom_level := 2);
-- select * from api.timetracking_summary(array['user', 'aow', 'daterange', 'project', 'activity'], date_part := 'month', zoom_level := 3);
-- select * from api.timetracking_summary(array['user', 'project', 'daterange', 'activity', 'aow'], zoom_level := 3);
-- select * from api.timetracking_summary(array['user', 'project', 'aow', 'activity', 'daterange'], zoom_level := 3);
-- select * from api.timetracking_summary(array['user',  'daterange'], date_part := 'month', zoom_level := 2);
-- select id, total_duration from api.timetracking_summary();
-- select to_char(lower(daterange), 'YYYY-MM-DD') as day, total_duration from
--   api.timetracking_summary(array['user', 'daterange'], date_part := 'day', zoom_level := 2)
--   where user_id = 2 and '[2023-04-01, 2023-05-01)'::daterange @> daterange order by daterange asc;
-- select * from api.timetracking_summary(array['daterange', 'user', 'aow', 'project', 'activity'], date_part := 'month', zoom_level := 1, filter_by := 'user', filter_ids := array[2]);
-- select * from api.timetracking_summary(array['daterange', 'aow', 'project', 'activity', 'user'], date_part := 'month', zoom_level := 1, filter_by := 'user', filter_ids := array[2]);
-- select * from api.timetracking_summary(array['daterange', 'aow', 'project', 'activity'], date_part := 'month', zoom_level := 2, filter_by := 'user', filter_ids := array[2]);
-- select * from api.timetracking_summary(array['daterange', 'aow', 'user', 'project', 'activity'], date_part := 'month', zoom_level := 3, filter_by := 'user', filter_ids := array[2]);
-- select * from api.timetracking_summary('{daterange,activity,user}'::TEXT[],date_part:='month',zoom_level:=1,filter_by:='user',filter_ids:='{2,3,7,8,10,11,12,23}'::INTEGER[]);
-- select * from api.timetracking_summary('{daterange,project}'::TEXT[],date_part:='month',zoom_level:=1,filter_by:='user',filter_ids:='{2,3,7,8,10,11,12,23}'::INTEGER[]);
-- select * from api.timetracking_summary ('{user,daterange}'::TEXT[],date_part:='day',zoom_level:=2);
CREATE
OR REPLACE FUNCTION api.timetracking_summary (
  axes TEXT[] DEFAULT ARRAY[]::TEXT[], -- axes to group data by
  date_part TEXT DEFAULT 'month', -- date part to use for grouping
  zoom_level INTEGER DEFAULT 0, -- level of detail for returned data
  filter_by TEXT DEFAULT NULL, -- axes to filter by
  filter_ids INTEGER[] DEFAULT ARRAY[]::INTEGER[] -- ID values to filter by
) RETURNS TABLE (
  id BIGINT,
  user_id INTEGER,
  aow_id INTEGER,
  project_id INTEGER,
  activity_id INTEGER,
  daterange daterange,
  total_duration NUMERIC,
  data jsonb
) LANGUAGE plpgsql IMMUTABLE SECURITY invoker AS $$
DECLARE
  valid_axes TEXT[]; -- array of valid axes
  foreign_axes TEXT[]; -- array of invalid axes
  axes_ids TEXT[]; -- array of column names for grouping
  query_text TEXT; -- dynamic query text
  cte_name TEXT; -- name of current CTE
  table_name TEXT; -- name of current table
  cte_select TEXT; -- SELECT statement for current CTE
  axes_select TEXT; -- SELECT statement for grouping columns
  null_select TEXT; -- SELECT statement for NULL columns
  cte_group_by TEXT; -- GROUP BY statement for current CTE
  foreign_table TEXT; -- name of foreign table for JOIN
  join_column TEXT; -- name of column for JOIN condition
  display_column TEXT; -- name of column to display in JSON data
  i INTEGER;
BEGIN
  valid_axes := ARRAY['user', 'aow', 'project', 'activity', 'daterange']; -- define valid axes
  -- check if provided axes are valid and raise exception if not
  foreign_axes := (select array(select unnest(axes) except select unnest(valid_axes)));
    IF foreign_axes <> array[]::text[] THEN
    RAISE EXCEPTION 'Invalid axes arguments: %', foreign_axes;
  END IF;
  -- generate array of column names for grouping based on provided axes
  axes_ids := (
    SELECT array_agg(CASE WHEN item != 'daterange' THEN item || '_id' ELSE item END)
    FROM UNNEST(
      CASE
        WHEN filter_by IS NOT NULL AND filter_by != ANY(axes) THEN array_cat(axes, array[filter_by])
        ELSE axes
      END
    ) AS item
  );
  query_text := format(
    'WITH summary_cte AS (
      SELECT %s, %stotal_duration, NULL::jsonb AS data
      FROM internal.timetracking_summary(%L::TEXT[], %L)
      %s
      %s
    ),',
    array_to_string(
      (
        SELECT array_agg(
          CASE
            WHEN item = ANY(axes) THEN
              CASE
                WHEN item != 'daterange' THEN item || '_id'
                ELSE item
              END
            ELSE
              CASE
                WHEN item != 'daterange' THEN 'NULL::INTEGER AS ' || item || '_id'
                ELSE 'NULL::DATERANGE AS ' || item
              END
          END
        )
        FROM UNNEST(valid_axes) AS item
      ),
      ','
    ),
    (
      CASE
        WHEN filter_by IS NOT NULL THEN 'SUM(total_duration) AS '
        ELSE ''
      END
    ),
    axes_ids,
    date_part,
    (
      CASE
        WHEN filter_by IS NOT NULL THEN format('WHERE %s_id = ANY (%L::INTEGER[])', filter_by, filter_ids)
        ELSE ''
      END
    ),
    (
      CASE
        WHEN filter_by IS NOT NULL THEN format(
          'GROUP BY %s',
          array_to_string(
            (
              SELECT array_agg(
                CASE
                  WHEN item != 'daterange' THEN item || '_id'
                  ELSE item
                END
              )
              FROM UNNEST(axes) AS item
            ),
            ','
          )
        )
        ELSE ''
      END
    )
  );
  -- loop through provided axes in reverse order to build nested CTEs for grouping and aggregating data at different levels of detail based on zoom_level argument.
  i := array_upper(axes, 1);
  WHILE i >= array_lower(axes, 1) LOOP
    -- generate SELECT statement for NULL columns to maintain consistent column order in all CTEs.
    null_select := (
      SELECT array_to_string(
        array_agg(
          CASE WHEN elem != 'daterange' THEN format('NULL::INTEGER AS %s_id', elem)
          ELSE format('NULL::DATERANGE AS %s', elem)
          END
        ), ', '
      ) FROM unnest(
        (SELECT ARRAY(SELECT unnest(valid_axes) EXCEPT SELECT unnest(axes))) || axes[i:]
      ) elem
    );
    -- set names for current CTE and table based on current axis.
    cte_name := format('%s_cte', axes[i]);
    table_name := format('%s_table', axes[i]);
    -- generate SELECT statement for grouping columns based on current axis.
    axes_select := array_to_string(
      ARRAY(
        SELECT format('%s.%s', format('%s_table', COALESCE(axes[i+1], 'summary')), elem)
        FROM unnest((axes_ids)[1:i-1]) elem
      ),
      ','
    );
    -- set foreign table, join column and display column based on current axis.
    IF axes[i] = 'user' THEN
      foreign_table := 'auth.users';
      join_column := 'user_id';
      display_column := 'username';
    ELSIF axes[i] = 'project' THEN
      foreign_table := 'internal.projects';
      join_column := 'project_id';
      display_column := 'name';
    ELSIF axes[i] = 'aow' THEN
      foreign_table := 'internal.areas_of_work';
      join_column := 'aow_id';
      display_column := 'name';
    ELSIF axes[i] = 'activity' THEN
      foreign_table := 'internal.activities';
      join_column := 'activity_id';
      display_column := 'name';
    ELSIF axes[i] = 'daterange' THEN
      foreign_table := 'summary_cte';
      join_column := 'daterange';
      display_column := 'daterange';
    END IF;
    -- generate GROUP BY statement for current CTE based on grouping columns.
    cte_group_by := format('GROUP BY %s', axes_select);
    -- add comma separator to axes_select if not empty.
    IF axes_select != '' THEN
      axes_select := axes_select || ',';
    END IF;
    -- generate SELECT statement for current CTE based on current axis and level of detail.
    IF i = array_upper(axes, 1) THEN
      cte_select := format(
        '%s %s, NULL::NUMERIC as total_duration, jsonb_agg(jsonb_build_object(''name'', %s_table.%s, ''value'', summary_table.total_duration)) AS data',
        axes_select,
        null_select,
        (CASE WHEN axes[i] != 'daterange' THEN axes[i] ELSE 'summary' END),
        display_column
      );
    ELSE
      cte_select := format(
        '%s %s, NULL::NUMERIC as total_duration, jsonb_agg(jsonb_build_object(''name'', %s_table.%s, ''children'', %s_table.data)) AS data',
        axes_select,
        null_select,
        (CASE WHEN axes[i] != 'daterange' THEN axes[i] ELSE 'summary' END),
        display_column,
        axes[i+1]
      );
    END IF;
    -- add current CTE to dynamic query with SELECT, FROM and LEFT JOIN statements.
    query_text := format(
      '%s %s AS (
        SELECT %s
        FROM %s AS %s
        %s
        %s
      ),',
      query_text,
      cte_name,
      cte_select,
      (CASE WHEN i = array_upper(axes, 1) THEN 'summary_cte' ELSE format('%s_cte', axes[i+1]) END),
      (CASE WHEN i = array_upper(axes, 1) THEN 'summary_table' ELSE format('%s_table', axes[i+1]) END),
      (
        CASE WHEN i = array_upper(axes, 1) AND foreign_table = 'summary_cte' THEN ''
        ELSE format(
          'LEFT JOIN %s AS %s USING (%s)',
          foreign_table,
          (CASE WHEN axes[i] = 'daterange' THEN 'summary_table' ELSE table_name END),
          join_column)
        END
      ),
      (CASE WHEN i = 1 THEN '' ELSE cte_group_by END)
    );
    i := i - 1;
  END LOOP;
  -- add final SELECT statement to dynamic query to return data at specified level of detail based on zoom_level argument.
  query_text := format(
    '%s SELECT
      ROW_NUMBER() OVER () AS id,
      user_id,
      aow_id,
      project_id,
      activity_id,
      daterange,
      total_duration,
      data
    FROM %s_cte AS %s_table;',
    rtrim(query_text, ','),
    (array_cat(axes, ARRAY['summary']))[zoom_level+1],
    (array_cat(axes, ARRAY['summary']))[zoom_level+1]
  );
  -- execute dynamic query and return results.
  RETURN QUERY EXECUTE query_text;
END;
$$;

GRANT
EXECUTE ON FUNCTION api.timetracking_summary TO basic;

-- Usage:
-- select day, duration from api.duration_calendar where user_id = 2 and daterange <@ '[2023-04-01, 2023-05-01)'::daterange;
CREATE OR REPLACE VIEW
  api.duration_calendar
WITH
  (security_invoker = on) AS
SELECT
  id,
  user_id,
  daterange,
  TO_CHAR(LOWER(daterange), 'YYYY-MM-DD') AS day,
  total_duration AS duration
FROM
  api.timetracking_summary (
    ARRAY['user', 'daterange'],
    date_part := 'day',
    zoom_level := 2
  )
ORDER BY
  daterange ASC;

-- ===========================================================================
-- 012.faq.sql
-- ===========================================================================

CREATE TABLE IF NOT EXISTS
    internal.faqs (
        faq_id serial primary key,
        priority integer,
        question text not null,
        answer text not null,
        is_published boolean not null
    );

CREATE OR REPLACE VIEW
    api.faqs
WITH
    (security_invoker = on) AS
SELECT
    faq_id as id,
    priority,
    question,
    answer,
    is_published
FROM
    internal.faqs;

ALTER TABLE internal.faqs ENABLE ROW LEVEL SECURITY;

-- TODO: Check these policies directly, as they are obscured away from user in frontend
CREATE POLICY faqs_policy ON internal.faqs USING (is_published IS TRUE)
WITH
    CHECK (pg_has_role('power', 'MEMBER'));

CREATE POLICY delete_faqs_policy ON internal.faqs FOR DELETE USING (pg_has_role('power', 'MEMBER'));

-- ===========================================================================
-- 013.project_aoe_functions.sql
-- ===========================================================================

-- Note: Don't include in other functions, especially where security   definer
CREATE
OR REPLACE FUNCTION auth.get_current_user_id () RETURNS integer LANGUAGE sql AS $$
    SELECT user_id FROM auth.users WHERE email = current_user;
$$;

GRANT
EXECUTE ON FUNCTION auth.get_current_user_id () TO basic;

-- The auth.is_project_member function takes in a user_id, project_id, and an optional is_lead parameter.
-- It returns a boolean value indicating whether the specified user is either a regular member or lead member of the specified project.
-- If the is_lead parameter is provided as true, the function will only return true if the user is a lead member.
-- Id the is_lead parameter is provided as false, the function will only return true if the user is a regular member.
-- The function constructs and executes a dynamic query to check for the existence of a row in the internal.user_project_roles table matching the provided parameters.
CREATE
OR REPLACE FUNCTION auth.is_project_member (
    user_id integer,
    project_id integer,
    is_lead boolean default null
) RETURNS boolean LANGUAGE plpgsql SECURITY definer AS $$
DECLARE
    query text;
    result boolean;
BEGIN
    query := 'SELECT 1 FROM internal.user_project_roles WHERE user_id = $1 AND project_id::integer = $2';
    IF is_lead IS NOT NULL THEN
        query := query || ' AND is_lead = $3';
    END IF;
    query := 'SELECT EXISTS (' || query || ')';
    EXECUTE query INTO result USING user_id, project_id::integer, is_lead;
    RETURN result;
END;
$$;

GRANT
EXECUTE ON FUNCTION auth.is_project_member (
    user_id integer,
    project_id integer,
    is_lead boolean
) TO basic;

-- Note: Can now get this information if 'pm' is part of auth.users.roles
CREATE
OR REPLACE FUNCTION auth.is_manager (p_user_id integer) RETURNS boolean LANGUAGE sql SECURITY definer AS $$
    SELECT EXISTS (
        SELECT 1
        FROM internal.user_project_roles as upr
        WHERE upr.user_id = p_user_id AND upr.is_lead = true
    );
$$;

GRANT
EXECUTE ON FUNCTION auth.is_manager (p_user_id integer) TO basic;

-- This function checks if a given user is a supervisor.
-- It returns true if the user is a supervisor and false otherwise.
-- A user is considered a supervisor if their ID appears in the lead_id column
-- of the internal.aoe_teams table where the supervisor_id column is equal to the lead_id column.
-- Note this IS a priveleged function, SECURITY   definer
CREATE
OR REPLACE FUNCTION auth.is_supervisor (given_user_id integer) RETURNS boolean LANGUAGE sql SECURITY definer AS $$
    SELECT EXISTS (
        SELECT 1
        FROM internal.aoe_teams
        WHERE supervisor_id = lead_id
        AND lead_id = given_user_id
    );
$$;

GRANT
EXECUTE ON FUNCTION auth.is_supervisor (given_user_id integer) TO basic;

-- This function checks if the first given user id (lead) is a lead of second given user id (member).
-- It returns true if the first user is a lead of the second and false otherwise.
CREATE
OR REPLACE FUNCTION auth.is_lead_of (given_lead_id integer, given_member_id integer) RETURNS boolean LANGUAGE sql SECURITY definer AS $$
    SELECT EXISTS (
        SELECT 1
        FROM internal.aoe_hierarchies
        WHERE lead_id = given_lead_id
        AND member_id = given_member_id
    );
$$;

GRANT
EXECUTE ON FUNCTION auth.is_lead_of (given_lead_id integer, given_member_id integer) TO basic;

-- This function checks if the first given user id (pm) is a pm of second given user id (member).
-- It returns true if the first user is a pm of the second and false otherwise.
-- Note that there can be multiple pms of a project, this also answers true in
-- the case that the second given user id is on the same pm team as the first
-- TODO: Review the usage here, does the fact that the function is true for pm colleagues have impact?
CREATE
OR REPLACE FUNCTION auth.is_pm_of (given_pm_id integer, given_member_id integer) RETURNS boolean LANGUAGE sql SECURITY definer AS $$
  SELECT bool_or(is_lead)
  FROM internal.user_project_roles
  WHERE user_id = given_pm_id AND project_id IN (
    SELECT project_id
    FROM internal.user_project_roles
    WHERE user_id = given_member_id
  )
$$;

GRANT
EXECUTE ON FUNCTION auth.is_pm_of (given_pm_id integer, given_member_id integer) TO basic;

CREATE
OR REPLACE FUNCTION auth.is_supervisor_of_aoe (given_aoe_id integer, given_lead_id integer) RETURNS bool LANGUAGE sql SECURITY definer AS $$
    SELECT EXISTS (
        SELECT 1
        FROM internal.aoe_teams
        WHERE aoe_id = given_aoe_id
        AND lead_id = given_lead_id
        AND supervisor_id = lead_id
    );
$$;

GRANT
EXECUTE ON FUNCTION auth.is_supervisor_of_aoe (integer, integer) TO basic;

CREATE
OR REPLACE FUNCTION internal.aoe_teams_grant_or_revoke_privs (given_lead_id integer) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    user_email text;
BEGIN
    SELECT email INTO user_email FROM auth.users WHERE user_id = given_lead_id;
    IF auth.is_supervisor(given_lead_id) THEN
        IF NOT pg_has_role(user_email, 'lead', 'MEMBER') THEN
            PERFORM auth.grant_priv(
                user_email,
                'lead'
            );
        END IF;
    ELSE
        IF pg_has_role(user_email, 'lead', 'MEMBER') THEN
            PERFORM auth.revoke_priv(
                user_email,
                'lead'
            );
        END IF;
    END IF;
END;
$$;

-- TODO: This is potentially insecure, fix
GRANT
EXECUTE ON FUNCTION internal.aoe_teams_grant_or_revoke_privs (integer) TO basic;

-- ===========================================================================
-- 014.schema.policies.sql
-- ===========================================================================

--------------
-- PROJECTS --
--------------
-- Create row-level security policies for the projects table
ALTER TABLE internal.projects ENABLE ROW LEVEL SECURITY;

-- Only power users can delete projects
REVOKE DELETE ON internal.projects
FROM
    PUBLIC;

GRANT DELETE ON internal.projects TO power;

-- Current user can select the projects they and the AoE teams they lead are members/pms of
CREATE POLICY select_projects_policy ON internal.projects USING (
    EXISTS (
        WITH
            lead_status_cte AS (
                SELECT
                    user_id,
                    auth.is_lead_of (auth.get_current_user_id (), user_id) AS current_user_is_lead
                FROM
                    auth.users
            )
        SELECT
            1
        FROM
            lead_status_cte
            JOIN internal.user_project_roles upr USING (user_id)
        WHERE
            (
                current_user_is_lead IS TRUE
                OR user_id = auth.get_current_user_id ()
            )
            AND upr.project_id = internal.projects.project_id
    )
);

-- Only PMs can do inserts (upserts) on their projects, only power users can do inserts on new projects
CREATE POLICY insert_leads_projects_policy ON internal.projects FOR INSERT
WITH
    CHECK (
        auth.is_project_member (
            auth.get_current_user_id (),
            project_id::integer,
            is_lead => true
        )
    );

-- Only PMs can do updates on their projects
CREATE POLICY update_leads_projects_policy ON internal.projects FOR
UPDATE USING (
    auth.is_project_member (
        auth.get_current_user_id (),
        project_id::integer,
        is_lead => true
    )
)
WITH
    CHECK (
        auth.is_project_member (
            auth.get_current_user_id (),
            project_id::integer,
            is_lead => true
        )
    );

-- Create row-level security policies for the user_project_roles table
ALTER TABLE internal.user_project_roles ENABLE ROW LEVEL SECURITY;

-- Updates aren't allowed (TODO: Check what happens when user is changed from manager to member and visa versa)
REVOKE
UPDATE ON internal.user_project_roles
FROM
    PUBLIC;

-- All members can select their user_project_roles (or those that they lead?)
-- Permissive for now
CREATE POLICY select_user_project_roles_policy ON internal.user_project_roles FOR
SELECT
    USING (
        -- auth.is_project_member (auth.get_current_user_id (), project_id::integer)
        true
    );

-- Only leads (is_lead=true) can insert/delete relationships that define project membership (i.e. if row includes is_lead=false)
CREATE POLICY insert_user_project_roles_policy ON internal.user_project_roles FOR INSERT
WITH
    CHECK (
        (is_lead is false)
        AND (
            auth.is_project_member (
                auth.get_current_user_id (),
                project_id::integer,
                is_lead => true
            )
        )
    );

CREATE POLICY delete_user_project_roles_policy ON internal.user_project_roles FOR DELETE USING (
    (is_lead is false)
    AND (
        auth.is_project_member (
            auth.get_current_user_id (),
            project_id::integer,
            is_lead => true
        )
    )
);

-----------
-- Users --
-----------
-- Enable Row Level Security on the users table
ALTER TABLE auth.users ENABLE ROW LEVEL SECURITY;

-- Create a policy that allows SELECT and UPDATE operations on the users table only for the current user
CREATE POLICY select_users_policy ON auth.users FOR
SELECT
    USING (
        email = current_user
        OR auth.is_lead_of (auth.get_current_user_id (), user_id)
        OR auth.is_pm_of (auth.get_current_user_id (), user_id)
        OR auth.is_lead_of (user_id, auth.get_current_user_id ())
        OR auth.is_pm_of (user_id, auth.get_current_user_id ())
    );

CREATE POLICY update_users_policy ON auth.users FOR
UPDATE
WITH
    CHECK (email = current_user);

----------
-- AOWs --
----------
-- Create row-level security policies for the project_areas_of_work table
ALTER TABLE internal.project_areas_of_work ENABLE ROW LEVEL SECURITY;

-- Updates aren't allowed
REVOKE
UPDATE ON internal.project_areas_of_work
FROM
    PUBLIC;

-- All members can select their project_areas_of_work
CREATE POLICY select_project_areas_of_work_policy ON internal.project_areas_of_work FOR
SELECT
    USING (
        auth.is_project_member (auth.get_current_user_id (), project_id::integer)
    );

-- Only leads (is_lead=true) can insert/delete relationships that define areas of work
CREATE POLICY insert_project_areas_of_work_policy ON internal.project_areas_of_work FOR INSERT
WITH
    CHECK (
        auth.is_project_member (
            auth.get_current_user_id (),
            project_id::integer,
            is_lead => true
        )
    );

CREATE POLICY delete_project_areas_of_work_policy ON internal.project_areas_of_work FOR DELETE USING (
    auth.is_project_member (
        auth.get_current_user_id (),
        project_id::integer,
        is_lead => true
    )
);

-- Only power users can insert/delete internal.areas_of_work
ALTER TABLE internal.areas_of_work ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_areas_of_work_policy ON internal.areas_of_work FOR
SELECT
    USING (true);

CREATE POLICY insert_areas_of_work_policy ON internal.areas_of_work FOR INSERT
WITH
    CHECK (pg_has_role('power', 'MEMBER'));

CREATE POLICY delete_areas_of_work_policy ON internal.areas_of_work FOR DELETE USING (pg_has_role('power', 'MEMBER'));

----------------
-- Activities --
----------------
-- Create row-level security policies for the project_activities table
ALTER TABLE internal.project_activities ENABLE ROW LEVEL SECURITY;

-- Updates aren't allowed
REVOKE
UPDATE ON internal.project_activities
FROM
    PUBLIC;

-- All members can select their project_activities
CREATE POLICY select_project_activities_policy ON internal.project_activities FOR
SELECT
    USING (
        auth.is_project_member (auth.get_current_user_id (), project_id::integer)
    );

-- Only leads (is_lead=true) can insert/delete relationships that define activities
CREATE POLICY insert_project_activities_policy ON internal.project_activities FOR INSERT
WITH
    CHECK (
        auth.is_project_member (
            auth.get_current_user_id (),
            project_id::integer,
            is_lead => true
        )
    );

CREATE POLICY delete_project_activities_policy ON internal.project_activities FOR DELETE USING (
    auth.is_project_member (
        auth.get_current_user_id (),
        project_id::integer,
        is_lead => true
    )
);

-- Only power users can insert/delete internal.activities
ALTER TABLE internal.activities ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_activities_policy ON internal.activities FOR
SELECT
    USING (true);

CREATE POLICY insert_activities_policy ON internal.activities FOR INSERT
WITH
    CHECK (pg_has_role('power', 'MEMBER'));

CREATE POLICY delete_activities_policy ON internal.activities FOR DELETE USING (pg_has_role('power', 'MEMBER'));

-------------------
-- Time Tracking --
-------------------
-- Enable row-level security on the internal.time_trackings table.
ALTER TABLE internal.time_trackings ENABLE ROW LEVEL SECURITY;

-- This is a row-level security policy for the internal.time_trackings table.
-- It allows users to see and modify rows where:
-- 1. The user_id column matches their own ID (as returned by the auth.get_current_user_id() function)
-- 2. They are a lead of the member whose ID is in the user_id column (as determined by calling the auth.is_lead_of() function)
CREATE POLICY time_trackings_policy ON internal.time_trackings USING (
    user_id = auth.get_current_user_id ()
    OR auth.is_lead_of (auth.get_current_user_id (), user_id)
)
WITH
    CHECK (
        user_id = auth.get_current_user_id ()
        OR auth.is_lead_of (auth.get_current_user_id (), user_id)
    );

-----------------
-- AoE / Teams --
-----------------
ALTER TABLE internal.areas_of_expertise ENABLE ROW LEVEL SECURITY;

CREATE POLICY aoe_policy ON internal.areas_of_expertise FOR
SELECT
    USING (
        EXISTS (
            SELECT
                1
            FROM
                internal.aoe_hierarchies
            WHERE
                internal.aoe_hierarchies.aoe_id = internal.areas_of_expertise.aoe_id
                AND (
                    internal.aoe_hierarchies.lead_id = auth.get_current_user_id ()
                    OR internal.aoe_hierarchies.member_id = auth.get_current_user_id ()
                )
        )
    );

ALTER TABLE internal.aoe_hierarchies ENABLE ROW LEVEL SECURITY;

REVOKE
UPDATE ON internal.aoe_hierarchies
FROM
    PUBLIC;

CREATE POLICY select_aoe_hierarchies_policy ON internal.aoe_hierarchies FOR
SELECT
    USING (
        lead_id = auth.get_current_user_id ()
        OR member_id = auth.get_current_user_id ()
    );

CREATE POLICY insert_aoe_hierarchies_policy ON internal.aoe_hierarchies FOR INSERT
WITH
    CHECK (lead_id = auth.get_current_user_id ());

CREATE POLICY delete_aoe_hierarchies_policy ON internal.aoe_hierarchies FOR DELETE USING (lead_id = auth.get_current_user_id ());

-- ===========================================================================
-- 015.schema.employees.sql
-- ===========================================================================

CREATE
OR REPLACE FUNCTION internal.employees_upsert () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    new_user_id integer;
    -- A new employee created without an email gets the creating user's own
    -- domain (the caller's role is their email), so no tenant domain is
    -- configured anywhere: switching Azure tenants needs no code change.
    new_email text = COALESCE(NEW.email, NEW.username || '@' || NULLIF(split_part(current_user, '@', 2), ''));
BEGIN
    IF new_email IS NULL THEN
        RAISE EXCEPTION 'email is required: cannot derive a domain from role %', current_user;
    END IF;
    -- If the new ID is NULL, create a new user using the provided data
    IF NEW.id IS NULL THEN
        EXECUTE 'SELECT auth.create_user($1, $2, $3, $4)'
        INTO new_user_id
        USING new_email, NEW.first_name, NEW.last_name, NEW.position;
    ELSE
        -- Else, update the existing user with the provided data
        new_user_id = NEW.ID;
        INSERT INTO auth.users(user_id, username, email, first_name, last_name, position)
        VALUES (NEW.id, NEW.username, new_email, NEW.first_name, NEW.last_name, NEW.position)
        ON CONFLICT (user_id)
        DO UPDATE SET
            first_name = EXCLUDED.first_name,
            last_name = EXCLUDED.last_name,
            position = EXCLUDED.position;
    END IF;
    -- Delete from user_project_roles where user is no longer a member or a lead
    DELETE FROM internal.user_project_roles
    WHERE user_id = new_user_id AND (
        (is_lead = FALSE AND project_id NOT IN (SELECT value::integer FROM jsonb_array_elements_text(NEW.member_of_project_ids)))
        OR (is_lead = TRUE AND project_id NOT IN (SELECT value::integer FROM jsonb_array_elements_text(NEW.lead_of_project_ids)))
    );
    -- Add the user as a member to new projects
    INSERT INTO internal.user_project_roles (user_id, project_id, is_lead)
    SELECT new_user_id, member_project_id::integer, FALSE
    FROM jsonb_array_elements_text(NEW.member_of_project_ids) AS member_project_id
    WHERE member_project_id::integer NOT IN (SELECT project_id FROM internal.user_project_roles WHERE user_id = new_user_id AND is_lead = FALSE);
    -- Add the user as a lead to new projects
    INSERT INTO internal.user_project_roles (user_id, project_id, is_lead)
    SELECT new_user_id, lead_project_id::integer, TRUE
    FROM jsonb_array_elements_text(NEW.lead_of_project_ids) AS lead_project_id
    WHERE lead_project_id::integer NOT IN (SELECT project_id FROM internal.user_project_roles WHERE user_id = new_user_id AND is_lead = TRUE);
    -- If the user was not a lead of any project and now is a lead, grant them 'pm' privilege
    IF jsonb_array_length(COALESCE(OLD.lead_of_project_ids, '[]'::jsonb)) = 0 AND jsonb_array_length(COALESCE(NEW.lead_of_project_ids, '[]'::jsonb)) > 0 THEN
        PERFORM auth.grant_priv(new_email, 'pm');
    -- If the user was a lead of a project and is no longer a lead, revoke their 'pm' privilege
    ELSIF jsonb_array_length(COALESCE(OLD.lead_of_project_ids, '[]'::jsonb)) > 0 AND jsonb_array_length(COALESCE(NEW.lead_of_project_ids, '[]'::jsonb)) = 0 THEN
        PERFORM auth.revoke_priv(new_email, 'pm');
    END IF;
    -- Grant / Revoke Power is necessary
    IF OLD.is_power is FALSE and NEW.is_power is TRUE THEN
        PERFORM auth.grant_power(new_email);
    ELSIF OLD.is_power is TRUE and NEW.is_power is FALSE THEN
        PERFORM auth.revoke_power(new_email);
    END IF;
    -- Return the new row to be inserted/updated
    RETURN NEW;
END;
$$;

CREATE TRIGGER employees_instead_of_insert INSTEAD OF INSERT ON api.employees FOR EACH ROW
EXECUTE FUNCTION internal.employees_upsert ();

CREATE TRIGGER employees_instead_of_update INSTEAD OF
UPDATE ON api.employees FOR EACH ROW
EXECUTE FUNCTION internal.employees_upsert ();

-- ===========================================================================
-- 098.activate.cyanaudit.sql
-- ===========================================================================

DO $$
DECLARE
    r RECORD;
BEGIN
    UPDATE cyanaudit.tb_config SET VALUE = 'users' WHERE NAME = 'user_table';
    -- Because postgres user/roles take format of email, username_col must match to email
    -- Role needs to come from JWT preferred username (which is an email)
    UPDATE cyanaudit.tb_config SET VALUE = 'email' WHERE NAME = 'user_table_username_col';
    UPDATE cyanaudit.tb_config SET VALUE = 'email' WHERE NAME = 'user_table_email_col';
    UPDATE cyanaudit.tb_config SET VALUE = 'user_id' WHERE NAME = 'user_table_uid_col';
    FOR r IN (
        SELECT nspname
        FROM pg_namespace
        WHERE nspname NOT IN ('cyanaudit', 'dbmate', 'pg_toast', 'pg_catalog', 'information_schema')
    )
    LOOP
        BEGIN
            EXECUTE format('SELECT cyanaudit.fn_update_audit_fields(%L)', r.nspname);
            RAISE INFO 'Turned on CyanAudit logging for schema %', r.nspname;
        EXCEPTION WHEN insufficient_privilege THEN
            RAISE WARNING 'Permission denied for schema %: skipping update', r.nspname;
        END;
    END LOOP;
END $$;

-- ===========================================================================
-- 099.admin.tools.sql
-- ===========================================================================

CREATE SCHEMA admin AUTHORIZATION admin;

-- Get transactions
CREATE
OR REPLACE FUNCTION admin.transactions () RETURNS TABLE (txid bigint, recorded timestamp, duration numeric) AS $$
BEGIN
    RETURN QUERY
    SELECT
        c.txid AS txid,
        MIN(c.recorded AT TIME ZONE 'UTC' AT TIME ZONE current_setting('TimeZone')) AS recorded,
        EXTRACT(EPOCH FROM MAX(c.recorded) - MIN(c.recorded)) AS duration
    FROM cyanaudit.vw_audit_log AS c
    GROUP BY c.txid
    ORDER BY c.txid DESC;
END;
$$ LANGUAGE plpgsql;

-- Get slowest transactions
CREATE
OR REPLACE FUNCTION admin.slowest_transactions () RETURNS TABLE (txid bigint, duration numeric, recorded timestamp) AS $$
BEGIN
    RETURN QUERY
    SELECT t.txid AS txid, t.duration AS duration, t.recorded AS recorded
    FROM admin.transactions() AS t
    ORDER BY t.duration DESC;
END;
$$ LANGUAGE plpgsql;

-- Get latest transactions
CREATE
OR REPLACE FUNCTION admin.latest_transactions () RETURNS TABLE (txid bigint, recorded timestamp, duration numeric) AS $$
BEGIN
    RETURN QUERY
    SELECT t.txid AS txid, t.recorded AS recorded, t.duration AS duration
    FROM admin.transactions() AS t
    ORDER BY t.recorded DESC;
END;
$$ LANGUAGE plpgsql;

-- Get details about transaction
CREATE
OR REPLACE FUNCTION admin.transaction_details (p_txid bigint) RETURNS TABLE (
    recorded timestamp,
    uid integer,
    user_email varchar,
    txid bigint,
    description varchar,
    table_name varchar,
    column_name varchar,
    pk_vals text[],
    op character,
    old_value text,
    new_value text
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        c.recorded AT TIME ZONE 'UTC' AT TIME ZONE current_setting('TimeZone') AS recorded,
        c.uid AS uid,
        c.user_email AS user_email,
        c.txid AS txid,
        c.description AS description,
        c.table_name AS table_name,
        c.column_name AS column_name,
        c.pk_vals AS pk_vals,
        c.op AS op,
        c.old_value AS old_value,
        c.new_value AS new_value
    FROM cyanaudit.vw_audit_log AS c
    WHERE c.txid = p_txid
    ORDER BY c.recorded DESC;
END;
$$ LANGUAGE plpgsql;

-- Get the latest transaction id
CREATE
OR REPLACE FUNCTION admin.latest_transaction_id () RETURNS bigint AS $$
BEGIN
    RETURN (SELECT MAX(txid) FROM admin.latest_transactions() LIMIT 1);
END;
$$ LANGUAGE plpgsql;

-- migrate:down
-- Forward-only: the baseline cannot be rolled back.
