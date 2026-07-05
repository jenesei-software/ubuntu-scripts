# Uptime Kuma Module

The `uptime-kuma/` module installs one Uptime Kuma instance behind Caddy.

It uses the official Docker deployment style: one Uptime Kuma container with persistent `/app/data` storage and a local reverse proxy through Caddy.

References:

* https://github.com/louislam/uptime-kuma/wiki/%F0%9F%94%A7-How-to-Install
* https://uptime.kuma.pet/

## Requirements

Before you begin, make sure you have:

* a server running **Ubuntu 24.04**
* root access to the server
* Caddy installed on the server if `UPTIME_KUMA_CONFIGURE_CADDY=true`
* `status.cyrilstrone.com` pointed to the server
* the ability to open `80/tcp` and `443/tcp` from the internet

Docker is installed automatically by this module when it is missing.

## Files

```text
uptime-kuma/
|-- env.example
|-- setup-uptime-kuma.sh
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
  | reverse_proxy UPTIME_KUMA_BIND_IP:UPTIME_KUMA_PORT
  v
Uptime Kuma container
  |
  v
Docker volume: uptime-kuma-data
```

Default local upstream:

```env
UPTIME_KUMA_BIND_IP=127.0.0.1
UPTIME_KUMA_PORT=3001
```

## Prepare Env

Run this module from the same root-owned checkout where you downloaded `ubuntu-scripts`.

Clone the repository on the server:

```bash
ssh root@YOUR_SERVER_IP
apt update && apt install -y git
git clone https://github.com/jenesei-software/ubuntu-scripts.git ubuntu-scripts
cd ~/ubuntu-scripts
```

Prepare the Uptime Kuma env:

```bash
cd ~/ubuntu-scripts/uptime-kuma
cp env.example .env
nano .env
```

Required value:

```env
UPTIME_KUMA_URL=https://status.cyrilstrone.com
```

Uptime Kuma asks you to create its own admin account after the first setup.

## Run

Install Caddy first:

```bash
cd ~/ubuntu-scripts/caddy
bash setup-caddy.sh
```

Then run Uptime Kuma setup:

```bash
cd ~/ubuntu-scripts/uptime-kuma
bash setup-uptime-kuma.sh
```

After setup, open:

```text
https://status.cyrilstrone.com
```

Create the first Uptime Kuma admin account.

## Service User

By default, Docker Compose operations run as root. To run them as a dedicated Linux user, set:

```env
UPTIME_KUMA_SYSTEM_USER=uptimeadmin
UPTIME_KUMA_SYSTEM_PASSWORD=changeMeSystemPassword
UPTIME_KUMA_SYSTEM_SSH_PUB=""
```

When `UPTIME_KUMA_SYSTEM_USER` is set, setup creates or reuses that user, adds it to the `docker` group, gives it `/opt/uptime-kuma`, and runs Docker Compose as that user.

Details: [service-users.md](service-users.md)

## Domain Conflict Behavior

If `UPTIME_KUMA_URL` uses a domain that is already present in `/etc/caddy/Caddyfile`:

* If the existing block already points to `UPTIME_KUMA_BIND_IP:UPTIME_KUMA_PORT`, it is kept.
* If the existing block points somewhere else, setup asks whether to replace it.
* If the block was created by this module, it is updated safely between managed markers.

For unattended runs, choose the behavior in `uptime-kuma/.env`:

```env
UPTIME_KUMA_CADDY_OVERWRITE_DOMAIN=ask
```

Allowed values:

* `ask` - ask before replacing the occupied domain
* `true` - replace without asking
* `false` - stop without replacing

Set this to skip Caddy changes:

```env
UPTIME_KUMA_CONFIGURE_CADDY=false
```

Use that only when you plan to configure Caddy manually.

## Verify

```bash
cd ~/ubuntu-scripts/uptime-kuma
bash check-setup.sh
```

The check script verifies:

* Docker and Docker Compose
* Docker apt repository files
* Uptime Kuma container
* Uptime Kuma local HTTP endpoint
* Caddyfile validation
* Caddy reverse proxy target
* UFW HTTP/HTTPS rules

## Useful Commands

View logs:

```bash
cd /opt/uptime-kuma
docker compose logs -f
```

Restart Uptime Kuma:

```bash
cd /opt/uptime-kuma
docker compose up -d --force-recreate
```

Stop Uptime Kuma:

```bash
cd /opt/uptime-kuma
docker compose down
```

## Open Ports

Uptime Kuma itself listens locally and does not need a public firewall rule.

Public ports are handled by the Caddy module:

* `80/tcp`
* `443/tcp`
