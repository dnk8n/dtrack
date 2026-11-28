-- Create a user and make them a power user ("God mode": bypasses row-level
-- security). Run as admin by power-user.sh with the email passed in as the
-- psql variable :email. Idempotent.
SELECT
    auth.create_user (:'email');

SELECT
    auth.grant_power (:'email');
