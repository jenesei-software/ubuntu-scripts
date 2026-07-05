# Netdata Module

The `netdata/` module installs one Netdata server dashboard behind Caddy.

It uses the official Docker deployment style: one Netdata container with host mounts for system metrics and a local reverse proxy through Caddy.

References:

* https://learn.netdata.cloud/docs/netdata-agent/installation/docker
* https://www.netdata.cloud/open-source/

## Requirements

Before you begin, make sure you have:

* a server running **Ubuntu 24.04**
* root access to the server
* Caddy installed on the server if `NETDATA_CONFIGURE_CADDY=true`
* `server.cyrilstrone.com` pointed to the server
* the ability to open `80/tcp` and `443/tcp` from the internet

Docker is installed automatically by this module when it is missing.

## Files

```text
netdata/
|-- env.example
|-- setup-netdata.sh
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
  | basic_auth
  | reverse_proxy NETDATA_BIND_IP:NETDATA_PORT
  v
Netdata container
  |
  v
Host metrics and Docker socket mounts
```

Default local upstream:

```env
NETDATA_BIND_IP=127.0.0.1
NETDATA_PORT=19999
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

Prepare the Netdata env:

```bash
cd ~/ubuntu-scripts/netdata
cp env.example .env
nano .env
```

Required values:

```env
NETDATA_URL=https://server.cyrilstrone.com
NETDATA_BASIC_AUTH_USER=admin
NETDATA_BASIC_AUTH_PASSWORD=change_me_netdata_password
```

Change `NETDATA_BASIC_AUTH_PASSWORD` before running setup. The script stops if the placeholder password is still present.

## Run

Install Caddy first:

```bash
cd ~/ubuntu-scripts/caddy
bash setup-caddy.sh
```

Then run Netdata setup:

```bash
cd ~/ubuntu-scripts/netdata
bash setup-netdata.sh
```

After setup, open:

```text
https://server.cyrilstrone.com
```

Log in with `NETDATA_BASIC_AUTH_USER` and `NETDATA_BASIC_AUTH_PASSWORD`.

## Service User

By default, Docker Compose operations run as root. To run them as a dedicated Linux user, set:

```env
NETDATA_SYSTEM_USER=netdataadmin
NETDATA_SYSTEM_PASSWORD=changeMeSystemPassword
NETDATA_SYSTEM_SSH_PUB=""
```

When `NETDATA_SYSTEM_USER` is set, setup creates or reuses that user, adds it to the `docker` group, gives it `/opt/netdata`, and runs Docker Compose as that user.

Details: [service-users.md](service-users.md)

## Caddy Basic Auth

Netdata has no app login in this setup, so Caddy basic auth is enabled by default:

```env
NETDATA_BASIC_AUTH_ENABLED=true
NETDATA_BASIC_AUTH_USER=admin
NETDATA_BASIC_AUTH_PASSWORD=change_me_netdata_password
```

The setup script hashes `NETDATA_BASIC_AUTH_PASSWORD` before writing it to `/etc/caddy/Caddyfile`.

## Domain Conflict Behavior

If `NETDATA_URL` uses a domain that is already present in `/etc/caddy/Caddyfile`:

* If the existing block already points to `NETDATA_BIND_IP:NETDATA_PORT`, it is kept.
* If the existing block points somewhere else, setup asks whether to replace it.
* If the block was created by this module, it is updated safely between managed markers.

For unattended runs, choose the behavior in `netdata/.env`:

```env
NETDATA_CADDY_OVERWRITE_DOMAIN=ask
```

Allowed values:

* `ask` - ask before replacing the occupied domain
* `true` - replace without asking
* `false` - stop without replacing

Set this to skip Caddy changes:

```env
NETDATA_CONFIGURE_CADDY=false
```

Use that only when you plan to configure Caddy manually.

## Verify

```bash
cd ~/ubuntu-scripts/netdata
bash check-setup.sh
```

The check script verifies:

* Docker and Docker Compose
* Docker apt repository files
* Netdata container
* Netdata local API endpoint
* Caddyfile validation
* Caddy reverse proxy target
* Caddy basic auth marker
* UFW HTTP/HTTPS rules

## Useful Commands

View logs:

```bash
cd /opt/netdata
docker compose logs -f
```

Restart Netdata:

```bash
cd /opt/netdata
docker compose up -d --force-recreate
```

Stop Netdata:

```bash
cd /opt/netdata
docker compose down
```

## Open Ports

Netdata itself listens locally and does not need a public firewall rule.

Public ports are handled by the Caddy module:

* `80/tcp`
* `443/tcp`
