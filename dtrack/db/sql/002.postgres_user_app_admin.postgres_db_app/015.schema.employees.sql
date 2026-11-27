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
