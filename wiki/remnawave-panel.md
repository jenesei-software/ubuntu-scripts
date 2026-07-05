# Remnawave Panel Module

The `remnawave-panel/` module installs Remnawave Panel and the bundled subscription page behind the repository's shared Caddy reverse proxy.

References:

* https://docs.rw/install/reverse-proxies/caddy/
* https://docs.rw/install/subscription-page/bundled/
* https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml
* https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample

## Files

```text
remnawave-panel/
|-- env.example
|-- setup-remnawave-panel.sh
|-- setup-subscription-page.sh
`-- check-setup.sh
```

## Architecture

```text
Internet
  |
  | 80/tcp, 443/tcp
  v
Caddy
  |                          |
  | reverse_proxy panel      | reverse_proxy subscription page
  v                          v
Remnawave Panel              Bundled Subscription Page
  |
  +-- Postgres
  +-- Redis
```

Default local upstreams:

```env
REMNAWAVE_PANEL_BIND_IP=127.0.0.1
REMNAWAVE_PANEL_PORT=3000
REMNAWAVE_METRICS_PORT=3001
SUBSCRIPTION_PAGE_BIND_IP=127.0.0.1
SUBSCRIPTION_PAGE_PORT=3010
```

## Prepare Env

Run this module from the same root-owned checkout where you downloaded `ubuntu-scripts`.

```bash
cd ~/ubuntu-scripts/remnawave-panel
cp env.example .env
nano .env
```

Required before the first panel run:

```env
PANEL_DOMAIN=panel.example.com
SUBSCRIPTION_PAGE_DOMAIN=sub.panel.example.com
```

Required before the bundled subscription-page run:

```env
REMNAWAVE_API_TOKEN=your_token_here
```

The API token is created inside Remnawave after the first admin account exists.

## Run

Install Caddy first:

```bash
cd ~/ubuntu-scripts/caddy
bash setup-caddy.sh
```

Deploy the panel:

```bash
cd ~/ubuntu-scripts/remnawave-panel
bash setup-remnawave-panel.sh
```

The script:

* installs Docker if needed
* downloads the official Remnawave Panel compose and env sample
* writes runtime settings to `/opt/remnawave/.env`
* generates secrets when placeholders are found
* patches published panel and metrics ports to local bind addresses
* starts `remnawave`, `remnawave-db`, and `remnawave-redis`
* adds a managed Caddy block for `PANEL_DOMAIN`

After setup, open `https://PANEL_DOMAIN`, create the first super-admin account, then create a Remnawave API token.

Add the token to `remnawave-panel/.env`:

```env
REMNAWAVE_API_TOKEN=your_token_here
```

Deploy the bundled subscription page:

```bash
cd ~/ubuntu-scripts/remnawave-panel
bash setup-subscription-page.sh
```

The script:

* writes `/opt/remnawave/subscription/docker-compose.yml`
* writes `/opt/remnawave/subscription/.env`
* updates `SUB_PUBLIC_DOMAIN` in `/opt/remnawave/.env`
* recreates the `remnawave` container so the new env is applied
* starts `remnawave-subscription-page`
* adds a managed Caddy block for `SUBSCRIPTION_PAGE_DOMAIN`

The subscription page must be served from the root of its own domain or subdomain. It must not be mounted under a reverse-proxy path such as `/subscription`.

## Service User

By default, Docker Compose operations run as root. To use a dedicated Linux user:

```env
REMNAWAVE_PANEL_SYSTEM_USER=remnawaveadmin
REMNAWAVE_PANEL_SYSTEM_PASSWORD=changeMeSystemPassword
REMNAWAVE_PANEL_SYSTEM_SSH_PUB=""
```

When this is set, setup creates or reuses the user, updates its password when provided, adds the SSH key when provided, adds the user to `docker`, gives it `/opt/remnawave`, and runs Docker Compose operations as that user.

Details: [service-users.md](service-users.md)

## Caddy

The module writes managed Caddy blocks into `/etc/caddy/Caddyfile` by default:

```caddyfile
# BEGIN ubuntu-scripts remnawave-panel panel.example.com
panel.example.com {
    encode zstd gzip
    reverse_proxy 127.0.0.1:3000
}
# END ubuntu-scripts remnawave-panel panel.example.com
```

```caddyfile
# BEGIN ubuntu-scripts remnawave-subscription sub.panel.example.com
sub.panel.example.com {
    encode zstd gzip
    reverse_proxy 127.0.0.1:3010
}
# END ubuntu-scripts remnawave-subscription sub.panel.example.com
```

Conflict behavior:

```env
REMNAWAVE_PANEL_CADDY_OVERWRITE_DOMAIN=ask
```

Allowed values:

* `ask` - ask before replacing an occupied domain
* `true` - replace without asking
* `false` - stop without replacing

Disable Caddy changes:

```env
REMNAWAVE_PANEL_CONFIGURE_CADDY=false
```

## Verify

```bash
cd ~/ubuntu-scripts/remnawave-panel
bash check-setup.sh
```

The check script verifies:

* Docker and Docker Compose
* Docker apt repository files
* service user Docker access when configured
* Remnawave files in `/opt/remnawave`
* subscription files in `/opt/remnawave/subscription`
* `remnawave`, `remnawave-db`, `remnawave-redis`, and `remnawave-subscription-page`
* the `remnawave-network` Docker network
* local panel, metrics, and subscription page ports
* local health endpoints
* Caddyfile validation and reverse proxy targets
* UFW HTTP/HTTPS rules

## Useful Commands

Panel logs:

```bash
cd /opt/remnawave
docker compose logs -f remnawave
```

Panel status:

```bash
cd /opt/remnawave
docker compose ps
```

Subscription page logs:

```bash
cd /opt/remnawave/subscription
docker compose logs -f
```

Recreate panel after editing `/opt/remnawave/.env`:

```bash
cd /opt/remnawave
docker compose up -d --force-recreate remnawave
```

Recreate subscription page after editing `/opt/remnawave/subscription/.env`:

```bash
cd /opt/remnawave/subscription
docker compose up -d --force-recreate
```

Validate and reload Caddy:

```bash
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
```

## Open Ports

Remnawave Panel and the bundled subscription page are local-only by default.

Public ports are handled by the Caddy module:

* `80/tcp`
* `443/tcp`
