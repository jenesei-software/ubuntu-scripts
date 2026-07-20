# YouTrack Server

This module runs one pinned official YouTrack Server container behind the system Caddy. The container publishes port `8080` only on loopback; Caddy owns public `80/443` and TLS.

## Requirements

- Ubuntu 24.04 and root access
- a DNS record for `YOUTRACK_URL` pointing to the server
- existing Caddy installation when `YOUTRACK_CONFIGURE_CADDY=true`
- at least 2 CPU cores and 2 GB RAM
- direct-attached persistent storage; JetBrains does not support NFS for YouTrack data
- enough space for the database, logs, and backups; the module requires 20 GB free by default

The official container runs as UID/GID `13001:13001`. The script creates and fixes ownership for `/opt/youtrack/data`, `conf`, `logs`, and `backups` accordingly.

## Install

```bash
cd ~/ubuntu-scripts/youtrack
cp env.example .env
nano .env
chmod 600 .env
bash setup-youtrack.sh
bash check-setup.sh
```

The script installs Docker from Docker's official Ubuntu repository if necessary, validates resources and port ownership, writes a Compose definition, starts YouTrack, waits for local HTTP, and adds a validated managed Caddy block with rollback.

## First initialization

On a new installation, obtain the one-time wizard URL only in the administrator terminal:

```bash
docker logs youtrack 2>&1 | grep -m1 wizard_token
```

Open that URL through `YOUTRACK_URL`, finish the JetBrains configuration wizard, and set **Base URL** exactly to the public HTTPS URL from `.env`. The setup script deliberately does not print the wizard token because it grants control over a new instance.

Keep the direct local port private. Caddy forwards the original host and scheme, which YouTrack uses to generate public URLs and authentication redirects.

## Persistent data and backups

Default paths:

- `/opt/youtrack/data`: database and application data
- `/opt/youtrack/conf`: configuration
- `/opt/youtrack/logs`: logs
- `/opt/youtrack/backups`: YouTrack backup archives
- `/opt/youtrack/docker-compose.yml`: generated runtime definition

Configure scheduled application backups in YouTrack and copy them off the server. Before changing `YOUTRACK_IMAGE`, create and verify a backup. JetBrains warns that upgraded databases are not backward compatible, so rollback requires the matching pre-upgrade backup.

## Upgrade

1. Read the JetBrains upgrade notes and check license compatibility.
2. Create a YouTrack backup and copy it off-host.
3. Change `YOUTRACK_IMAGE` to an exact official tag.
4. Set `YOUTRACK_UPGRADE_CONFIRMED=true` for the controlled upgrade run.
5. Rerun `setup-youtrack.sh` and `check-setup.sh`, then return the confirmation variable to `false`.

The script backs up a changed Compose file but that file is not a database backup.

## Authentik OIDC

YouTrack 2026.1 and later supports a generic OpenID Connect authentication module. Install and initialize `authentik/`, then follow [the Authentik module guide](authentik.md#youtrack-oidc-integration).

The integration is a two-pass process: first create the Authentik provider with the provisional redirect URI, then create the YouTrack OpenID Connect module, copy its generated `/hub/api/rest/oauth2/interactive/login/<uuid>/land` URI into `authentik/.env`, and rerun `setup-youtrack-oidc.sh`.

The **Default** checkbox is optional. Leave it disabled until **Test login** and a complete private-window login both succeed. Enabling it makes YouTrack redirect unauthenticated users directly to Authentik; leaving it disabled keeps the normal login page with Authentik as a selectable option. Keep the built-in password module enabled and verify the recovery page at `<youtrack-base-url>/hub/loginOptions` before making Authentik the default.

If the first OIDC login creates a second user with a suffix, merge that account into the existing YouTrack administrator from **Administration > Access Management > Users**. Preserve the existing administrator's username and profile fields; the merge transfers the OIDC login and combines permissions. Do not delete the duplicate manually, and remember that merging accounts is irreversible.

### Authentik behind Cloudflare

The public Authentik hostname can remain **Proxied** in Cloudflare. If YouTrack's Java OIDC client times out while retrieving JWKS through Cloudflare, pin only the YouTrack container's server-to-server connection to the Authentik origin. In `youtrack/.env` on the YouTrack VPS, set both values:

```dotenv
YOUTRACK_OIDC_HOST=sso.example.com
YOUTRACK_OIDC_ORIGIN_IP=203.0.113.10
```

Use the real Authentik hostname and its VPS public IPv4 address. Rerun `setup-youtrack.sh`; the generated Compose file adds an `extra_hosts` entry and recreates only the YouTrack service when required. The URL, hostname, TLS certificate validation, OIDC issuer, and JWKS URL do not change: only DNS resolution inside the YouTrack container bypasses Cloudflare.

The Authentik origin must accept HTTPS from the YouTrack VPS, and Caddy must serve a valid certificate for the public Authentik hostname. Do not replace OIDC URLs with an IP address and do not disable TLS verification. `check-setup.sh` verifies both the generated container override and the hostname resolution seen inside the container.

On the Authentik VPS, rerun `setup-authentik.sh` and then `setup-youtrack-oidc.sh`. The OIDC script installs an automatically refreshed Caddy JWKS fast path because YouTrack 2026.2 allows only `500 ms` for that response. Verify it with `authentik/check-setup.sh`; the report should confirm the JWKS cache, refresh timer, and Caddy fast path.

## Diagnostics

```bash
cd ~/ubuntu-scripts/youtrack
bash check-setup.sh
docker compose -f /opt/youtrack/docker-compose.yml ps
docker logs --tail 200 youtrack
curl -I http://127.0.0.1:8080/
```

The checker is non-destructive and exits nonzero when required checks fail.

## Upstream documentation

- [Install YouTrack with Docker](https://www.jetbrains.com/help/youtrack/server/youtrack-docker-installation.html)
- [Reverse proxy configuration](https://www.jetbrains.com/help/youtrack/server/reverse-proxy-configuration.html)
- [Supported environments](https://www.jetbrains.com/help/youtrack/server/youtrack-supported-environments.html)
- [Upgrade a Docker installation](https://www.jetbrains.com/help/youtrack/server/upgrade-with-docker-image.html)
- [OpenID Connect authentication module](https://www.jetbrains.com/help/youtrack/server/openid-connect-authentication-module.html)
- [Merge user accounts](https://www.jetbrains.com/help/youtrack/server/merge-user-accounts.html)
