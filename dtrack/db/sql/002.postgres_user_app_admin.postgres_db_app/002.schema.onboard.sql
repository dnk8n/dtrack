CREATE
OR REPLACE FUNCTION auth.create_user (
    email text,
    first_name text DEFAULT NULL,
    last_name text DEFAULT NULL,
    job_position text DEFAULT NULL
) RETURNS integer SECURITY DEFINER AS $$
DECLARE
    username text;
    created_user_id integer;
BEGIN
    username := SUBSTRING(email FROM 1 FOR POSITION('@' IN email) - 1);
    BEGIN
        EXECUTE format('CREATE ROLE %I INHERIT NOLOGIN', email);
    EXCEPTION WHEN duplicate_object THEN
    END;
    EXECUTE format('GRANT %I to $POSTGRES_USER_APP', email);
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
