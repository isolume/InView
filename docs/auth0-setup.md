# Auth0 sign-in (Apple + email) and admin login

InView signs people in with Auth0 Universal Login, passwordless: **Sign in with Apple** or a
**one-time code by email**. The app and the admin page trade the ID token Auth0 issues for the
server's own revocable session (`POST /api/accounts/auth0`); everything after that is the existing
bearer session.

```
app / admin page --Universal Login (PKCE)--> Auth0 --ID token--> client
client --POST /api/accounts/auth0 {id_token}--> server verifies RS256 via JWKS
server --> {token, expires_at, account}
```

## What the server checks
- RS256 only (never the token's own `alg`), signature from `https://{domain}/.well-known/jwks.json`.
- `iss == https://{domain}/`; `aud` is the app's client ID, the admin app's client ID, or the
  optional API identifier; `exp`, `nbf`, `sub`, `iat` present.
- The token was issued in the last 10 minutes (it is traded right after sign-in).
- `email_verified` is `true`. An unverified email never links to or creates an account.

## Accounts and roles
- Accounts match by Auth0 `sub`, else link to an existing account with the same **verified** email
  (keeping its id and submissions), else a new user is created.
- **Admin** if the `https://inview.app/roles` claim contains `admin`, or the verified email is in
  `INVIEW_ADMIN_EMAILS`. It is re-derived at every sign-in, so removing the role demotes on the next
  one. Administrator sessions last 8 hours; user sessions 14 days.
- The password administrator from `INVIEW_ADMIN_EMAIL`/`INVIEW_ADMIN_PASSWORD` remains as
  break-glass (`/admin` → "Use administrator password"). Registration and password login are
  closed for everyone else once Auth0 is configured.

## Auth0 tenant (once)
1. **Native application** (iOS), already created: type *Native*, token endpoint auth *None*.
   Allowed Callback URLs and Allowed Logout URLs:
   `inview://inview.us.auth0.com/ios/com.inview.InView/callback`
2. **Connections** → enable for that application: **Apple** (social; needs your Apple Services ID
   and key) and **Email** under *Authentication → Passwordless* (one-time code). Disable the
   database connection so there is no password sign-up.
3. **Admin page**: create a *Single Page Web Application*. Allowed Callback URLs, Allowed Logout
   URLs and Allowed Web Origins: your backend origin + `/admin` (and the origin), e.g.
   `https://<your-host>/admin`. Enable the same Apple and Email connections.
4. **Roles** (optional): create an `admin` role and assign it. Or rely on `INVIEW_ADMIN_EMAILS`.
5. **Action** (*Actions → Library → Build custom → Login / Post Login*, then add it to the Login
   flow) so the role reaches the token:

```js
exports.onExecutePostLogin = async (event, api) => {
  const roles = event.authorization?.roles ?? [];
  api.idToken.setCustomClaim("https://inview.app/roles", roles);
  api.accessToken.setCustomClaim("https://inview.app/roles", roles);
};
```

## Server configuration
| Variable | Purpose |
|---|---|
| `INVIEW_AUTH0_DOMAIN` | Tenant host, e.g. `inview.us.auth0.com`. Unset = password-only (today's behaviour). |
| `INVIEW_AUTH0_CLIENT_ID` | The native app's client ID. |
| `INVIEW_AUTH0_ADMIN_CLIENT_ID` | The admin SPA's client ID (enables "Continue with Auth0" on `/admin`). |
| `INVIEW_AUTH0_AUDIENCE` | Optional API identifier, if you later add an API. |
| `INVIEW_AUTH0_NAMESPACE` | Custom-claim prefix; default `https://inview.app/`. |
| `INVIEW_ADMIN_EMAILS` | Comma-separated emails treated as administrators. |

At least one of the client IDs or the audience is required with a domain; anything else is a
startup error.

## App configuration
`Config/App.xcconfig` carries `INVIEW_AUTH0_DOMAIN`, `INVIEW_AUTH0_CLIENT_ID` and
`INVIEW_AUTH0_CALLBACK_URL`. They are public identifiers (the native app uses PKCE and has no
secret). Override in the git-ignored `Secrets.xcconfig`. Clearing the domain restores email and
password sign-in. The callback URL uses a custom scheme, so no Associated Domains entitlement or
Team ID is needed; it must exactly match an Allowed Callback URL.

The sign-in sheet is ephemeral: the app keeps no Auth0 session or refresh token, and uses only the
server session afterward.

## Verifying
- `cargo test --test auth0` covers verification, linking, roles and the break-glass admin with a
  test-only RSA key and static JWKS.
- Live: with the variables set, sign in from the app, then `GET /api/accounts/me`; on `/admin`,
  sign in as an admin (and confirm a non-admin is refused).
