-- Run as admin by `dtrack-ops restore` after the data and audit log are
-- loaded into a freshly initialised database. Users are Postgres roles, which
-- a data-only backup doesn't carry, so they are recreated from the restored
-- rows. Power is not recreated: grant it with `dtrack-ops power-user`.
SET client_min_messages = warning;

-- Fast forward new server transaction ids to after the historic ones
DO $$
DECLARE
    current_value BIGINT := 0;
    target_value BIGINT;
BEGIN
    SELECT max(txid) INTO target_value FROM cyanaudit.vw_audit_log;
    WHILE current_value < target_value LOOP
    current_value := txid_current();
    COMMIT;
    RAISE NOTICE 'Current value: %', current_value;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
-- Recreate users
SELECT auth.create_user(email)
FROM unnest(
    (SELECT array_agg(email) FROM api.employees WHERE roles IS NULL AND email LIKE '%@%')
) AS t(email);
-- Reassign PM role if applicable
DO $$
DECLARE
  lead_email text;
BEGIN
  FOR lead_email IN
    SELECT distinct email
    FROM internal.user_project_roles AS upr
    JOIN api.employees AS employees ON employees.id = upr.user_id
    WHERE is_lead = TRUE
    AND NOT (roles @> '["pm"]'::jsonb)
  LOOP
    PERFORM auth.grant_priv(lead_email, 'pm');
  END LOOP;
END;
$$ LANGUAGE plpgsql;
-- Reassign lead role if applicable
DO $$
DECLARE
  lead_email text;
BEGIN
  FOR lead_email IN
    SELECT distinct e.email
    FROM internal.aoe_hierarchies AS aoeh
    JOIN api.employees AS e ON aoeh.lead_id = e.id
    WHERE auth.is_supervisor(e.id)
    AND NOT (e.roles @> '["lead"]'::jsonb)
  LOOP
    PERFORM auth.grant_priv(lead_email, 'lead');
  END LOOP;
END;
$$ LANGUAGE plpgsql;
