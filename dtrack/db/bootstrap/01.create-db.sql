-- Run as the superuser on the maintenance database. Passwords are set by
-- set-passwords.sql (every initdb.sh run), not here.
CREATE ROLE admin NOSUPERUSER CREATEROLE INHERIT LOGIN;

CREATE DATABASE dtrack;

ALTER DATABASE dtrack OWNER TO admin;

ALTER DATABASE dtrack
SET
    search_path TO public,
    pre,
    auth,
    api,
    internal,
    cyanaudit;
