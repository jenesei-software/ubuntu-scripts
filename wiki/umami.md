# Umami Module

The `umami/` module installs one Umami Analytics instance behind Caddy.

It uses the official Docker Compose style deployment: an Umami container, a PostgreSQL container, and a local reverse proxy through Caddy.

References:

* https://umami.is/
* https://docs.umami.is/docs/install

## Requirements

Before you begin, make sure you have:

* a server running **Ubuntu 24.04**
* root access to the server
* Caddy installed on the server if `UMAMI_CONFIGURE_CADDY=true`
* a domain name already pointed to the server
* the ability to open `80/tcp` and `443/tcp` from the internet

Docker is installed automatically by this module when it is missing.

## Files

```text
umami/
|-- env.example
|-- setup-umami.sh
`-- check-setup.sh
```

## Architecture

```text
Internet
  |
  | 80/tcp, 443/tcp
  v
Caddy
  |
  | reverse_proxy UMAMI_BIND_IP:UMAMI_PORT
  v
Umami container
  |
  v
PostgreSQL container
```

Default local upstream:

```env
UMAMI_BIND_IP=127.0.0.1
UMAMI_PORT=3000
```

## Prepare Env

Connect to the server first:

```bash
ssh root@YOUR_SERVER_IP
```

Install git and clone the repository:

```bash
apt update && apt install -y git
git clone https://github.com/jenesei-software/ubuntu-scripts.git ubuntu-scripts
cd ~/ubuntu-scripts
```

Prepare the Umami env:

```bash
cd umami
cp env.example .env
nano .env
```

Required values:

```env
UMAMI_URL=https://analytics.example.com
UMAMI_DB_PASSWORD=change_me_umami_db_password
UMAMI_APP_SECRET=change_me_random_app_secret
```

`UMAMI_URL` must be the public URL with protocol.
Use only letters, digits, dots, underscores, dashes, and equals signs in `UMAMI_DB_PASSWORD` and `UMAMI_APP_SECRET`.

## Run

Install Caddy first:

```bash
cd ~/ubuntu-scripts/caddy
bash setup-caddy.sh
```

Then run Umami setup:

```bash
cd ~/ubuntu-scripts/umami
bash setup-umami.sh
```

After setup, open `UMAMI_URL` in the browser.

Default credentials:

```text
admin / umami
```

Change the default password immediately after the first login.

## Service User

By default, Docker Compose operations run as root. To run them as a dedicated Linux user, set:

```env
UMAMI_SYSTEM_USER=umamiadmin
UMAMI_SYSTEM_PASSWORD=changeMeSystemPassword
UMAMI_SYSTEM_SSH_PUB=""
```

When `UMAMI_SYSTEM_USER` is set, setup creates or reuses that user, adds it to the `docker` group, gives it `/opt/umami`, and runs Docker Compose as that user.

Details: [service-users.md](service-users.md)

## Domain Conflict Behavior

If `UMAMI_URL` uses a domain that is already present in `/etc/caddy/Caddyfile`:

* If the existing block already points to `UMAMI_BIND_IP:UMAMI_PORT`, it is kept.
* If the existing block points somewhere else, setup asks whether to replace it.
* If the block was created by this module, it is updated safely between managed markers.

For unattended runs, choose the behavior in `umami/.env`:

```env
UMAMI_CADDY_OVERWRITE_DOMAIN=ask
```

Allowed values:

* `ask` - ask before replacing the occupied domain
* `true` - replace without asking
* `false` - stop without replacing

Set this to skip Caddy changes:

```env
UMAMI_CONFIGURE_CADDY=false
```

Use that only when you plan to configure Caddy manually.

## Verify

```bash
cd ~/ubuntu-scripts/umami
bash check-setup.sh
```

The check script verifies:

* Docker and Docker Compose
* Docker apt repository files
* Umami and PostgreSQL containers
* Umami heartbeat
* Caddyfile validation
* Caddy reverse proxy target
* UFW HTTP/HTTPS rules

## Useful Commands

View logs:

```bash
cd /opt/umami
docker compose logs -f
```

Restart Umami:

```bash
cd /opt/umami
docker compose up -d --force-recreate
```

Stop Umami:

```bash
cd /opt/umami
docker compose down
```

## Open Ports

Umami itself listens locally and does not need a public firewall rule.

Public ports are handled by the Caddy module:

* `80/tcp`
* `443/tcp`
