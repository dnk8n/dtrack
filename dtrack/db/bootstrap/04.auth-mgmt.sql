-- JWT decode function (used for onboarding)
CREATE EXTENSION plpython3u;

CREATE
OR REPLACE FUNCTION auth.decode_id_token (id_token text) RETURNS json LANGUAGE plpython3u AS $$
  import asyncio
  import json
  from guardpost.jwts import JWTValidator
  settings = plpy.execute("SELECT current_setting('app.settings.AZURE_TENANT_ID') AS tid, current_setting('app.settings.AZURE_CLIENT_ID') AS cid")
  tenant_id = settings[0]["tid"]
  client_id = settings[0]["cid"]
  async def main():
    validator = JWTValidator(
      authority=f"https://login.microsoftonline.com/{tenant_id}/",
      valid_issuers=[f"https://login.microsoftonline.com/{tenant_id}/v2.0"],
      valid_audiences=[client_id]
    )
    return await validator.validate_jwt(id_token)
  return json.dumps(asyncio.run(main()))
$$;

ALTER FUNCTION auth.decode_id_token (id_token text) OWNER TO admin;

-- Function owner by and run as superuser, only executable by power
CREATE
OR REPLACE FUNCTION auth.grant_power (username text) RETURNS void SECURITY DEFINER LANGUAGE plpgsql AS $$
BEGIN
  RAISE NOTICE 'PERFORMING -> GRANT power TO %; ALTER ROLE % BYPASSRLS;', username, username;
  EXECUTE format('GRANT power TO %I', username);
  EXECUTE format('ALTER ROLE %I BYPASSRLS', username);
END;
$$;

REVOKE
EXECUTE ON FUNCTION auth.grant_power
FROM
  PUBLIC;

GRANT
EXECUTE ON FUNCTION auth.grant_power TO power;

-- Function owner by and run as superuser, only executable by power
CREATE
OR REPLACE FUNCTION auth.revoke_power (username text) RETURNS void SECURITY DEFINER LANGUAGE plpgsql AS $$
BEGIN
  RAISE NOTICE 'PERFORMING -> REVOKE power FROM %; ALTER ROLE % NOBYPASSRLS;', username, username;
  EXECUTE format('REVOKE power FROM %I', username);
  EXECUTE format('ALTER ROLE %I NOBYPASSRLS', username);
END;
$$;

REVOKE
EXECUTE ON FUNCTION auth.revoke_power
FROM
  PUBLIC;

GRANT
EXECUTE ON FUNCTION auth.revoke_power TO power;

-- Function owner by and run as superuser, only executable by power
CREATE
OR REPLACE FUNCTION auth.grant_priv (username text, priv text) RETURNS void SECURITY DEFINER LANGUAGE plpgsql AS $$
BEGIN
  RAISE NOTICE 'PERFORMING -> GRANT % TO %', priv, username;
  EXECUTE format('GRANT %I TO %I', priv, username);
END;
$$;

REVOKE
EXECUTE ON FUNCTION auth.grant_priv
FROM
  PUBLIC;

GRANT
EXECUTE ON FUNCTION auth.grant_priv TO power;

-- Function owner by and run as superuser, only executable by power
CREATE
OR REPLACE FUNCTION auth.revoke_priv (username text, priv text) RETURNS void SECURITY DEFINER LANGUAGE plpgsql AS $$
BEGIN
  RAISE NOTICE 'PERFORMING -> REVOKE % FROM %', priv, username;
  EXECUTE format('REVOKE %I FROM %I', priv, username);
END;
$$;

REVOKE
EXECUTE ON FUNCTION auth.revoke_priv
FROM
  PUBLIC;

GRANT
EXECUTE ON FUNCTION auth.revoke_priv TO power;

CREATE
OR REPLACE FUNCTION auth.get_user_roles () RETURNS TABLE (user_email TEXT, user_roles TEXT[]) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY
  WITH role_counts AS (
    SELECT
      r.rolname::text as email,
      COUNT(*) as role_count
    FROM pg_authid r
    JOIN pg_auth_members ON r.oid = member
    JOIN pg_roles m ON m.oid = roleid
    WHERE r.rolname ILIKE '%@%'
      AND m.rolname NOT ILIKE '%@%'
    GROUP BY r.rolname
  ),
  role_agg AS (
    SELECT
      r.rolname::text as email,
      array_agg(
        m.rolname::text
        ORDER BY
          CASE m.rolname
            WHEN 'basic' THEN 1
            WHEN 'pm' THEN 2
            WHEN 'lead' THEN 3
            WHEN 'power' THEN 4
            ELSE 5
          END ASC
      ) FILTER (
        WHERE m.rolname <> 'basic'
        OR rc.role_count = 1
      ) as roles_agg
    FROM pg_authid r
    JOIN pg_auth_members ON r.oid = member
    JOIN pg_roles m ON m.oid = roleid
    JOIN role_counts rc ON rc.email = r.rolname::text
    WHERE r.rolname ILIKE '%@%'
      AND m.rolname NOT ILIKE '%@%'
    GROUP BY r.rolname
  )
  SELECT
    email,
    CASE WHEN roles_agg = ARRAY[]::text[] THEN NULL ELSE roles_agg END as roles
  FROM role_agg;
END;
$$;

REVOKE
EXECUTE ON FUNCTION auth.get_user_roles
FROM
  PUBLIC;

GRANT
EXECUTE ON FUNCTION auth.get_user_roles TO basic;
