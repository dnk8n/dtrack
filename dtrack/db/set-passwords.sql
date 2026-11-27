-- Set the login passwords of the two application roles. Run as the superuser
-- by initdb.sh on every run (so .env stays the source of truth), with the
-- values passed in as psql variables: nothing is substituted into this file.
ALTER ROLE admin PASSWORD :'admin_password';

ALTER ROLE authenticator PASSWORD :'authenticator_password';
