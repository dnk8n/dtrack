# New Azure tenant runbook

How to point DTrack at a different Microsoft Entra ID (Azure AD) tenant,
verify it locally in `make dev` mode, and then repeat it on a server.

Only three values in `.env` are tenant-specific. Nothing else in the code or
schema names a tenant or an email domain (see
[architecture.md](../architecture.md)):

| `.env` variable | What it is |
| --- | --- |
| `AZURE_TENANT_ID` | Directory (tenant) ID of the Entra tenant |
| `AZURE_CLIENT_ID` | Application (client) ID of the app registration |
| `POSTGRES_USER_APP_POWER` | The initial power user, exactly as Entra puts it in the id token's `preferred_username` claim (usually the UPN) |

`keys/jwt-secret` must also hold the tenant's JWKS (signing keys), which
`./rotate-keys.sh` downloads from `AZURE_TENANT_ID`.

## 1. Azure portal

1. **Tenant.** Microsoft Entra admin center → *Manage tenants* → *Create* →
   Workforce. Note the **Tenant ID** from the tenant's *Overview*.
2. **Users.** *Users* → *New user*. Create at least the power user and one
   ordinary user to test onboarding. Prefer `first.last@…` user principal
   names: `auth.create_user` derives first/last name by splitting the part
   before `@` on `.`.
3. **App registration.** *App registrations* → *New registration*:
   - Supported account types: **this organizational directory only** (single
     tenant). `api.onboard` only accepts tokens issued by this tenant.
   - Redirect URI: platform **Single-page application (SPA)**, URI
     `http://localhost:5174/auth-callback` (the local `make dev` UI).
   - After creating, *Authentication* → add the server's URI too:
     `https://<HOST>/auth-callback` (the value of `HOST` in the server's
     `.env`).
   - No client secret or certificate (MSAL runs in the browser as a public
     client). Leave implicit grant off: SPA uses auth code + PKCE.
   - *API permissions*: the default Microsoft Graph **User.Read**
     (delegated) is all that is needed. Grant admin consent so users are
     not prompted.
   - Note the **Application (client) ID** from *Overview*.
4. **Power user's exact name.** Postgres role names are case-sensitive and
   the role is the `preferred_username` claim verbatim. Copy the power user's
   UPN exactly as shown on the user's *Overview* (same capitalisation).

## 2. Verify locally (`make dev`)

```sh
# 1. Set the three values (AZURE_TENANT_ID, AZURE_CLIENT_ID, POSTGRES_USER_APP_POWER)
$EDITOR .env

# 2. Fetch the tenant's JWKS into keys/jwt-secret
./rotate-keys.sh

# 3. Fresh database whose power user is the new UPN, then the real-auth stack
make clean
make initdb
make dev
```

Then, in a browser with **site data for localhost cleared** (MSAL caches
tenant state):

1. Open <http://localhost:5174> and sign in as the power user. You land in
   the app with power permissions (Employees, Areas of work, Activities
   visible).
2. In a private window, sign in as the ordinary user. The first request fails
   with "role does not exist", the UI calls `/rpc/onboard`, and the user lands
   as `basic`. The power user can now see them under Employees.
3. Run a short journey as the power user: create an area of work, an
   activity, a project with the ordinary user as a member; log time as the
   ordinary user.

To go back to debug mode afterwards: `make debug` and clear localhost site
data again. Debug mode ignores `keys/jwt-secret` (the override injects the
debug secret), so the JWKS file can stay.

## 3. Repeat on a server

The server's `.env` is rendered by Ansible from `terraform.tfvars`
(`postgres_user_app_power`, `azure_tenant_id`, `azure_client_id` per
environment), but the `deploy` play currently wipes the database (BUG-001,
see [deployment.md](../deployment.md)). To change tenant by hand instead:

1. Add `https://<HOST>/auth-callback` to the app registration (step 1.3).
2. On the server, `cd /home/ubuntu/dtrack` and set the three values in `.env`.
   Also update `terraform.tfvars` on your machine so the next Ansible run
   renders the same values.
3. `./rotate-keys.sh`
4. `docker compose up -d --build --force-recreate react-admin postgrest`.
   The tenant and client IDs are baked into the UI at **build** time, so
   `react-admin` must be rebuilt. `postgrest` is recreated so it reads the
   new tenant settings and the new key file.
5. **Existing data.** Users are Postgres roles named after their old-tenant
   UPN. Users in the new tenant have different UPNs and will onboard as new,
   empty `basic` users. The `POSTGRES_USER_APP_POWER` power user is only
   created by `initdb`. On an existing database, create and promote it
   yourself (as the app admin):

   ```sql
   SELECT auth.create_user('First.Last@newtenant.onmicrosoft.com');
   SELECT auth.grant_power('First.Last@newtenant.onmicrosoft.com');
   ```

6. Sign in as in section 2. The scheduled
   [rotate-keys.yml](../../.github/workflows/rotate-keys.yml) workflow keeps
   the JWKS current from then on.
