# Authentik

This module installs one Authentik identity provider from Authentik's official versioned Docker Compose definition. Authentik HTTP binds only to loopback and the existing system Caddy terminates public HTTPS and proxies WebSocket traffic.

## Requirements

- Ubuntu 24.04 and root access
- DNS for `AUTHENTIK_URL`
- an existing Caddy installation when `AUTHENTIK_CONFIGURE_CADDY=true`
- at least 2 CPU cores and 2 GB RAM
- outbound HTTPS access to `goauthentik.io` and `ghcr.io`

## Install

```bash
cd ~/ubuntu-scripts/authentik
cp env.example .env
nano .env
chmod 600 .env
bash setup-authentik.sh
bash check-setup.sh
```

The setup downloads the Compose file from the selected Authentik lifecycle channel and verifies that it contains the expected official image and services before use. It stores generated Postgres, application, and bootstrap API secrets in `/opt/authentik/.env` with mode `0600` and preserves them on reruns.

Configure the administrator credentials in `authentik/.env` before the first run:

```env
AUTHENTIK_ADMIN_USERNAME=akadmin
AUTHENTIK_ADMIN_PASSWORD='replace_with_a_strong_password'
AUTHENTIK_ADMIN_PASSWORD_ROTATE=false
AUTHENTIK_BOOTSTRAP_EMAIL=admin@example.com
```

The password must be at least 16 characters and must not contain an example placeholder. The setup uses the root-only bootstrap API token over the loopback interface to rename Authentik's built-in `akadmin` account when requested and set its password. The plaintext administrator password remains only in the module's root-owned `authentik/.env`; it is not copied to `/opt/authentik/.env` or printed.

After setup, sign in at `AUTHENTIK_URL` with `AUTHENTIK_ADMIN_USERNAME` and `AUTHENTIK_ADMIN_PASSWORD`. The generated bootstrap token is intended for repository automation; do not copy it into Git or expose it in shell history.

### Existing installations and password rotation

Normal reruns preserve an existing administrator password. To intentionally replace it, update `AUTHENTIK_ADMIN_PASSWORD`, set the confirmation for one run, and then return it to `false`:

```env
AUTHENTIK_ADMIN_PASSWORD_ROTATE=true
```

```bash
cd ~/ubuntu-scripts/authentik
bash setup-authentik.sh
```

Changing `AUTHENTIK_ADMIN_USERNAME` renames the administrator represented by the module's bootstrap API token. The setup stops if another account already owns the requested username.

## Docker socket policy

The upstream worker mounts `/var/run/docker.sock` to manage Docker outposts automatically. This gives the container root-equivalent control over the Docker host. The module removes that mount by default because native OIDC does not require an outpost.

Set `AUTHENTIK_ENABLE_DOCKER_SOCKET=true` only when automatic Docker outpost management is intentionally needed, then rerun setup and verify the worker's trust boundary.

## Persistent files

- `/opt/authentik/compose.yml`: verified upstream Compose definition
- `/opt/authentik/.env`: generated runtime secrets and version settings
- `authentik/.env`: root-owned module configuration containing the administrator password; keep mode `0600` and back it up securely
- Docker volumes managed by the Compose project: PostgreSQL data, Authentik media, templates, and certificates
- `/opt/authentik/integrations/youtrack-oidc.env`: generated YouTrack OIDC client settings, when enabled

Back up both Authentik data and the root-only runtime files. A database backup without `AUTHENTIK_SECRET_KEY` is incomplete for recovery.

## YouTrack OIDC integration

The current Authentik service guide for YouTrack describes SAML. This repository instead uses native OpenID Connect because YouTrack 2026.1+ now has a generic OIDC module and Authentik exposes standard discovery metadata. The integration does not require a proxy outpost.

First install and initialize Authentik and YouTrack. Keep a working local administrator session open in both services until OIDC login has been tested successfully.

### 1. Prepare the Authentik environment

On the Authentik VPS, check `~/ubuntu-scripts/authentik/.env`:

```dotenv
AUTHENTIK_URL=https://sso.example.com

YOUTRACK_URL=https://youtrack.example.com
AUTHENTIK_YOUTRACK_APP_NAME=YouTrack
AUTHENTIK_YOUTRACK_APP_SLUG=youtrack
AUTHENTIK_YOUTRACK_CLIENT_ID=youtrack
YOUTRACK_OIDC_REDIRECT_URI=https://youtrack.example.com/hub/api/rest/oauth2/auth
```

The `/hub/api/rest/oauth2/auth` value is only provisional. It allows Authentik to create the provider before YouTrack has generated the real callback URI. Keep the module `.env` root-owned with mode `0600`.

### 2. Create the Authentik OIDC provider

Run on the Authentik VPS:

```bash
cd ~/ubuntu-scripts/authentik
sudo bash setup-youtrack-oidc.sh
sudo bash check-setup.sh
```

The script uses the local root-only bootstrap API token to idempotently create or update:

- an Authentik confidential OAuth2/OpenID provider;
- strict YouTrack redirect URI matching;
- `openid`, `email`, and `profile` scope mappings;
- an Authentik application that launches YouTrack;
- `/opt/authentik/integrations/youtrack-oidc.env` with the OIDC issuer, discovery URL, client ID, client secret, and redirect URI.

With the managed Caddy integration enabled, the script also installs a narrowly scoped static response for `/application/o/youtrack/jwks/` and a systemd timer that refreshes it from Authentik once per minute. YouTrack 2026.2 uses a hard `500 ms` connect/read timeout for JWKS, while Authentik can take longer to derive the response from its signing certificate. The fast path keeps the canonical HTTPS URL and keys unchanged while making the response deterministic. Existing installations created before this feature must run `setup-authentik.sh` once before rerunning `setup-youtrack-oidc.sh` so the managed Caddy block imports integration snippets.

It does not change YouTrack automatically. This prevents an unattended script from replacing the active login path or locking out administrators.

The first check reports a warning while the provisional redirect URI is still configured. That warning is expected until step 5 is complete.

### 3. Read the generated client settings

View the values locally on the Authentik VPS:

```bash
sudo sed -n '1,5p' \
  /opt/authentik/integrations/youtrack-oidc.env
```

Do not send or paste this output into chats, issues, or logs. It contains `YOUTRACK_OIDC_CLIENT_SECRET`.

### 4. Create the YouTrack auth module and copy its redirect URI

In YouTrack:

1. Open **Administration > Access Management > Auth Modules**.
2. Select **New module**, then **OpenID Connect**.
3. Set **Auth module name** to `Authentik`.
4. Set **OIDC URL** to `YOUTRACK_OIDC_ISSUER` from the generated integration file. It is normally `https://sso.example.com/application/o/youtrack/`.
5. Select **Next**. YouTrack displays a redirect URI similar to:

   ```text
   https://youtrack.example.com/hub/api/rest/oauth2/interactive/login/<uuid>/land
   ```

Copy the complete URI exactly. The UUID is unique to this YouTrack auth module; do not replace it with the provisional `/hub/api/rest/oauth2/auth` value.

### 5. Register the real redirect URI in Authentik

On the Authentik VPS, replace `YOUTRACK_OIDC_REDIRECT_URI` in `~/ubuntu-scripts/authentik/.env` with the URI generated by YouTrack, then rerun the integration and its checks:

```bash
cd ~/ubuntu-scripts/authentik
sudo bash setup-youtrack-oidc.sh
sudo bash check-setup.sh
```

The script updates the existing Authentik provider and preserves its client secret. The configured strict URI and the URI shown by YouTrack must match character for character. If the YouTrack auth module is deleted and recreated, repeat this step with its new UUID.

### 6. Finish the YouTrack module

Return to the YouTrack OpenID Connect setup and enter:

- **Client ID**: `YOUTRACK_OIDC_CLIENT_ID`
- **Client Secret**: `YOUTRACK_OIDC_CLIENT_SECRET`
- **Scopes**: `openid email profile`

Configure the claims as follows:

| YouTrack field | OIDC claim |
| --- | --- |
| User identifier | `sub` |
| Username | `preferred_username` |
| Full name | `name` |
| Email | `email` |
| Email verified | `email_verified` |
| Avatar URL | `picture` |
| Groups | `groups` |

Before the first OIDC login, make the existing YouTrack user's email exactly match the email of the corresponding Authentik user. This helps YouTrack link the external identity to the intended account instead of creating a duplicate.

Save the settings and initially leave automatic user creation and **Default** disabled. Select **Test login** first. If it succeeds, select **Enable**, then verify a complete login from a private browser window. Keep the existing administrator session open and password login enabled throughout this check.

If the first OIDC login creates a suffixed duplicate such as `username.abcd`, do not delete it. In **Administration > Access Management > Users**, select only the original account and the OIDC duplicate, then select **Merge**. Preserve the original username, full name, and email, leave **Ban** disabled, and confirm the merge. YouTrack transfers the Authentik login to the resulting account and retains the union of roles and group memberships. Account merging is irreversible, so verify both selected accounts before confirming.

### 7. Optionally make Authentik the default

The **Default** checkbox is not required for OIDC login. When it is disabled, unauthenticated users see the standard YouTrack login page and can choose the Authentik module. When it is enabled, YouTrack sends unauthenticated users directly to Authentik and skips the standard login page. Only one authentication module can be the default.

Enable **Default** only if automatic redirection to Authentik is the intended user experience and all of the following are already true:

- **Test login** succeeds;
- the module is enabled and a full login works in a private browser window;
- the OIDC identity is linked to the intended YouTrack account;
- the built-in password authentication module remains enabled as a recovery path;
- an administrator has verified the alternative login page at `https://youtrack.example.com/hub/loginOptions`.

For this deployment, replace the example hostname with the real YouTrack hostname. If Authentik is unavailable or the default-provider flow fails, open `/hub/loginOptions` directly and choose the built-in password login. Do not disable the built-in module after making Authentik the default.

Password login should remain available as a recovery path. Restrict access in Authentik with application policy bindings if not every Authentik user should enter YouTrack.

### Cloudflare proxy and YouTrack JWKS access

`AUTHENTIK_URL` may remain **Proxied** in Cloudflare. If the YouTrack OIDC module reports a timeout while retrieving the Authentik JWKS URL, keep every configured OIDC URL on the public HTTPS hostname and configure the optional direct origin route in `youtrack/.env` on the separate YouTrack VPS:

```dotenv
YOUTRACK_OIDC_HOST=sso.example.com
YOUTRACK_OIDC_ORIGIN_IP=203.0.113.10
```

After rerunning `youtrack/setup-youtrack.sh`, only the YouTrack container resolves that hostname directly to the Authentik VPS. Browsers still use Cloudflare, while the OIDC issuer and TLS hostname remain unchanged.

The Authentik OIDC setup additionally serves the JWKS document from its automatically refreshed Caddy cache. Both parts are needed for YouTrack 2026.2: the container origin override avoids Cloudflare latency, and the Caddy fast path keeps the origin response below YouTrack's `500 ms` JWKS timeout.

## Upgrade

Read the Authentik release notes, take and verify database and configuration backups, then update both `AUTHENTIK_VERSION` and its matching `AUTHENTIK_RELEASE_CHANNEL`. Set `AUTHENTIK_UPGRADE_CONFIRMED=true`, rerun setup and diagnostics, then return it to `false`. Never use `latest`; Authentik has deprecated that tag for normal upgrades.

## Diagnostics

```bash
cd ~/ubuntu-scripts/authentik
bash check-setup.sh
docker compose --project-directory /opt/authentik --env-file /opt/authentik/.env -f /opt/authentik/compose.yml ps
curl -fsS http://127.0.0.1:9000/-/health/ready/
curl -fsS https://auth.example.com/application/o/youtrack/.well-known/openid-configuration
systemctl status authentik-youtrack-jwks-refresh.timer
```

## Upstream documentation

- [Docker Compose installation](https://docs.goauthentik.io/install-config/install/docker-compose/)
- [Automated installation and bootstrap variables](https://docs.goauthentik.io/install-config/automated-install)
- [Authentik user API](https://docs.goauthentik.io/docs/developer-docs/api/reference/core-users-partial-update)
- [Reverse proxy requirements](https://docs.goauthentik.io/install-config/reverse-proxy/)
- [OAuth2/OpenID provider](https://docs.goauthentik.io/add-secure-apps/providers/oauth2/)
- [Authentik YouTrack service guide](https://docs.goauthentik.io/integrations/services/youtrack/)
