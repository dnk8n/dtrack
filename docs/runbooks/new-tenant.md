# New Azure tenant runbook

How to set up a Microsoft Entra ID (Azure AD) tenant for DTrack from nothing,
prove it works on your own machine with real Microsoft sign-in (`make dev`),
and then repeat it on a server. It also covers switching an existing
deployment from a test tenant to the real one.

Read [development.md](../development.md) first if you have never run DTrack
locally: this runbook assumes `make setup` already works for you in demo mode.

## What DTrack needs from Entra ID

Only three values in `.env` are tenant-specific. Nothing else in the code or
schema names a tenant or an email domain (see
[architecture.md](../architecture.md)):

| `.env` variable | What it is | Where to find it |
| --- | --- | --- |
| `AZURE_TENANT_ID` | Directory (tenant) ID, a GUID | App registration → *Overview* |
| `AZURE_CLIENT_ID` | Application (client) ID, a GUID | App registration → *Overview* |
| `POSTGRES_USER_APP_POWER` | Local `.env` only: the first power user, exactly as Entra puts it in the ID token's `preferred_username` claim (the user principal name, UPN). `make initdb` passes it to `power-user.sh`; on a server you pass the UPN to `./power-user.sh` directly | User → *Overview* → *User principal name* |

`keys/jwt-secret` must also hold the tenant's signing keys (JWKS), which
`./rotate-keys.sh` downloads using `AZURE_TENANT_ID`.

How sign-in works, so the settings below make sense:

- The UI uses MSAL in the browser (authorization code + PKCE, a public client
  with no secret). Authority: `https://login.microsoftonline.com/<AZURE_TENANT_ID>`.
  Redirect URI: `<UI base URL>/auth-callback`. Scope: `User.Read` (MSAL adds
  `openid profile` itself).
- The UI sends the **ID token** (not the access token) to the API.
  PostgREST checks its signature against `keys/jwt-secret` and switches to the
  Postgres role named by the `preferred_username` claim.
- **Each user is a Postgres role named after their UPN.** On first sign-in the
  role doesn't exist yet. The UI then calls `/rpc/onboard`, where the database
  re-validates the ID token against Microsoft (issuer
  `https://login.microsoftonline.com/<AZURE_TENANT_ID>/v2.0`, audience
  `AZURE_CLIENT_ID`) and creates the user as `basic`. The Postgres container
  therefore needs outbound HTTPS to `login.microsoftonline.com`.
- Roles beyond `basic` live in Postgres, not Entra: `pm` and `lead` are granted
  automatically (project lead, team supervisor) and `power` is granted by
  another power user. The app registration needs **no** app roles, groups,
  optional claims or secrets.

## 1. Create the tenant (skip if you already have one)

1. Sign in to the [Microsoft Entra admin center](https://entra.microsoft.com)
   with any work or personal Microsoft account (a free Azure account is
   enough).
2. *Entra ID* → *Overview* → *Manage tenants* → *Create* → **Microsoft Entra
   ID** (workforce), not External ID / B2C.
3. Organization name, initial domain (`<something>.onmicrosoft.com`, which
   can't be changed later) and country → *Review + create*.
4. Switch into the new tenant with the account menu (top right).
5. Leave **Security defaults** on. Users will be asked to register the
   Microsoft Authenticator app on their first sign-in.

## 2. Register the app

*App registrations* → *New registration*:

1. **Name:** anything, e.g. `dtrack (test)`.
2. **Supported account types:** *Accounts in this organizational directory
   only* (single tenant). Onboarding only accepts tokens issued by this exact
   tenant.
3. **Redirect URI:** platform **Single-page application (SPA)**, URI
   `http://localhost:5174/auth-callback` (the local `make dev` UI). It must be
   SPA, not *Web*: with *Web*, sign-in fails with `AADSTS9002326`.
4. *Register*, then on *Authentication* add the server's URI under the same
   SPA platform: `https://<HOST>/auth-callback`, where `<HOST>` is the value
   of `HOST` in the server's `.env`. Entra accepts plain `http` only for
   `localhost`. Leave both implicit-grant boxes unticked.
5. *API permissions*: the default Microsoft Graph **User.Read** (delegated) is
   all that's needed. Click *Grant admin consent* so users aren't prompted.
6. Don't add a client secret, certificate, *Expose an API*, app roles or token
   claims.
7. Optional: *Enterprise applications* → your app → *Properties* →
   **Assignment required = Yes**, then assign users or groups. Without it,
   anyone in the tenant can sign in and is onboarded as `basic`. Decide this
   deliberately for production.
8. Copy the **Application (client) ID** and **Directory (tenant) ID** from
   *Overview*. Use the tenant **GUID**, never the domain name: onboarding
   compares the token issuer literally, and the issuer always contains the
   GUID.

Check the tenant from any machine (including the server, which only needs
outbound HTTPS):

```sh
curl -s https://login.microsoftonline.com/<TENANT_ID>/v2.0/.well-known/openid-configuration \
  | grep -o '"issuer":"[^"]*"'
# expect "issuer":"https://login.microsoftonline.com/<TENANT_ID>/v2.0"
```

## 3. Create users

*Users* → *New user* → *Create new user*, with *Auto-generate password*. For
testing, three users cover every permission tier:

| Example UPN | Tier it proves | How it gets the tier |
| --- | --- | --- |
| `app.admin@<domain>` | `power` (sees and manages everyone) | `./power-user.sh app.admin@<domain>` (locally: `POSTGRES_USER_APP_POWER` before `make initdb`) |
| `first.lead@<domain>` | `pm` + `lead` (sees their project and team members) | Power user makes them a project lead and a team supervisor |
| `first.member@<domain>` | `basic` (sees only their own time) | Automatic on first sign-in |

Rules that matter, all from the code:

- **Use `first.last` before the `@`.** `auth.create_user` fills first and last
  name by splitting on `.`; `testuser1` gets an empty last name.
- **Use lowercase, and copy the power user's UPN exactly.** Postgres role names
  are case-sensitive and the role is `preferred_username` verbatim.
- **Use member users, not invited guests.** A guest's `preferred_username` is
  their home email (or contains `#EXT#`), which doesn't match the tenant. This
  includes the personal account you may have created the tenant with.
- If you enabled *Assignment required*, assign the users to the app.

Power is "God mode" (it bypasses row-level security). Keep it for configuring
users and the few catalogue items only power can create (below), and do
day-to-day work as ordinary users.

## 4. Verify locally (`make dev`)

Host prerequisites are in [development.md](../development.md).

```sh
# 1. Set AZURE_TENANT_ID, AZURE_CLIENT_ID, POSTGRES_USER_APP_POWER
$EDITOR .env

# 2. Fetch the tenant's signing keys into keys/jwt-secret
./rotate-keys.sh

# 3. Fresh database whose power user is the new UPN, then the real-auth stack
make clean
make initdb
make dev
```

Then, in a browser with **site data for localhost cleared** (MSAL caches
tenant state), go through this checklist:

- [ ] **Power user signs in.** Open <http://localhost:5174>, sign in as the
      power user (password change and Authenticator setup on first use). You
      land in the app with Employees, Areas of work and Activities visible.
- [ ] **Ordinary user onboards.** In a private window, sign in as the member.
      The first API call fails with "role does not exist", the UI calls
      `/rpc/onboard` and retries, and the user lands as `basic`. Do the same
      for the lead.
- [ ] **Roles are right.** `docker compose exec postgres psql -U postgres -d dtrack -c 'SELECT * FROM auth.get_user_roles();'`
      shows the power user with `power` and the others with `basic`.
- [ ] **Lead gets promoted.** As power, create a project with the lead as
      lead, and an area-of-expertise team with the lead as supervisor and the
      member in it. The lead now shows `pm` and `lead`.
- [ ] **Row-level security holds.** The member logs time and sees only their
      own entries; the lead sees theirs plus the member's.
- [ ] **Outsiders are refused.** A personal Microsoft account or a user from
      another tenant is rejected by Microsoft (`AADSTS50020`).

To inspect what the API receives, copy the ID token from the browser's
localStorage (key containing `idtoken`) into [jwt.ms](https://jwt.ms): expect
`ver` 2.0, `aud` = client ID, `iss` = the tenant issuer and
`preferred_username` = the lowercase UPN.

Realistic sample data for the lead and member (three months of time entries,
created as those users) is available in
[dtrack/dev/fixtures/simulated](../../dtrack/dev/fixtures/simulated/README.md).
Its README also lists which setup steps only power can do today (areas of
work, activities, projects, areas of expertise and teams; see #74).

Running the automated tests while `.env` holds real tenant values fails,
because the suites expect the dummy power user (#71). Until that's fixed,
put the template values from `.env.tpl` back for the test run.

To return to demo mode: `make demo` and clear localhost site data again.
Demo mode ignores `keys/jwt-secret`, so the JWKS file can stay.

## 5. Repeat on a server

Repeat sections 2 to 4 with the server's values: the server's `HOST`
redirect URI must be on the app registration, and the server's `.env` holds
`AZURE_TENANT_ID` and `AZURE_CLIENT_ID`. Create the first power user once,
after `./initdb.sh`, with `sudo ./power-user.sh <UPN>` (skip it when you
restore a backup instead). Things specific to a server:

- With Terraform + Ansible, set them per environment in `terraform.tfvars`
  (`azure_tenant_id`, `azure_client_id`, `postgres_user_app_power`); the
  playbook writes them into the server's `.env`. On a hand-built server, edit
  `.env` directly (see [deployment.md](../deployment.md#single-server-deploy-pull-based)).
- Only the `prod` compose override signs in through Entra ID. The Terraform
  `staging` environment uses `staging-demo`, which has the demo login and
  ignores these values.

- With the single-server stack, the published UI image reads the tenant ID,
  client ID and `HOST` from the container environment at start, so changing
  them only needs `docker compose up -d`. The Terraform/Ansible stack still
  bakes them in at **build** time, so there the `react-admin` image must be
  rebuilt.
- `./rotate-keys.sh` reloads PostgREST itself when the keys change. Schedule
  it (the single-server cron file runs it every 6 hours) so the keys follow
  Microsoft's key rotation.
- The server must allow outbound HTTPS to `login.microsoftonline.com` for the
  key download and for onboarding (from inside the Postgres container).
- Don't use the Ansible `deploy` play on a database you need: it wipes the
  database (BUG-001, see [deployment.md](../deployment.md)).

## 6. Switch an existing deployment to another tenant

Typical case: you proved everything with a test tenant and now move to the
organisation's real one.

1. Register the app in the new tenant (section 2) with the server's redirect
   URI.
2. Set `AZURE_TENANT_ID` and `AZURE_CLIENT_ID` in the server's `.env`, run
   `./rotate-keys.sh`, then recreate the UI and API: `docker compose up -d --force-recreate react-admin postgrest`
   (single-server stack). On the Terraform/Ansible stack add `--build`, since
   its UI image bakes the IDs in.
3. **Existing data.** Users are Postgres roles named after their UPN in the
   tenant they signed in with. Users from the new tenant have different UPNs
   and onboard as new, empty `basic` users. Create and promote the new power
   user with `./power-user.sh first.last@<new-domain>`.

   If you restore a production backup instead, the backup's users and roles
   come with it (see [backup-restore.md](backup-restore.md)).
4. Delete the test app registration, or the whole test tenant, when done.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `AADSTS9002326` (cross-origin token redemption) | Redirect URI registered under *Web*. Move it to *Single-page application*. |
| `AADSTS50011` (redirect URI mismatch) | The UI's `<base URL>/auth-callback` isn't on the app registration. Add it exactly, scheme and port included. |
| `AADSTS50020` (user not in tenant) | Expected for outsiders. For your own users: they're guests in another tenant, or you're signed in with a different account. |
| `AADSTS50058` in the Entra/Azure portal itself | The portal's own background sign-in. Sign out fully, open a private window, go to `https://entra.microsoft.com/<domain>.onmicrosoft.com`. |
| "Tenant '…' not found" | Wrong tenant ID or domain, or the tenant no longer exists. Check with the `curl` above. |
| Sign-in works but the app offers to log out, and the user never appears | Onboarding failed. Check `docker compose logs postgres` for errors from `api.onboard` or `auth.decode_id_token` (no outbound HTTPS, wrong `AZURE_CLIENT_ID`, or tenant domain instead of GUID). Builds before the #70 fix fail here with `relation "users" does not exist`. |
| Power user signs in but has no power | The email given to `power-user.sh` (locally: `POSTGRES_USER_APP_POWER`) didn't match the UPN exactly (case). Run `./power-user.sh <exact UPN>`. |
| API returns `JWSError`/`JWT invalid` | `keys/jwt-secret` doesn't hold this tenant's keys. Run `./rotate-keys.sh` and recreate postgrest. |
