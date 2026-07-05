# Ghost Module

The `ghost/` module installs one production Ghost instance behind Caddy.

It follows the official Ghost Ubuntu stack where practical: Ubuntu 22.04/24.04, MySQL 8, supported Node.js, Ghost-CLI, and systemd. NGINX and SSL setup from Ghost-CLI are disabled because Caddy owns public HTTP/HTTPS for this repository.

References:

* https://docs.ghost.org/install/ubuntu
* https://docs.ghost.org/ghost-cli/

## Requirements

Before you begin, make sure you have:

* a server running **Ubuntu 24.04**
* root access to the server
* Caddy installed on the server
* a domain name already pointed to the server
* the ability to open `80/tcp` and `443/tcp` from the internet

## Files

```text
ghost/
|-- env.example
|-- setup-ghost.sh
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
  | reverse_proxy GHOST_BIND_IP:GHOST_PORT
  v
Ghost
  |
  v
MySQL
```

Default local upstream:

```env
GHOST_BIND_IP=127.0.0.1
GHOST_PORT=2368
```

## Prepare Env

Run this module from the same root-owned checkout where you downloaded `ubuntu-scripts`.
The repository stays there. `GHOST_SYSTEM_USER` is only the Linux user that owns and runs Ghost.

Clone the repository on the server:

```bash
ssh root@YOUR_SERVER_IP
apt update && apt install -y git
git clone https://github.com/jenesei-software/ubuntu-scripts.git ubuntu-scripts
cd ~/ubuntu-scripts
```

Prepare the Ghost env:

```bash
cd ghost
cp env.example .env
nano .env
```

Required values:

```env
GHOST_SYSTEM_USER=ghostadmin
GHOST_SYSTEM_PASSWORD=change_me_system_user_password
GHOST_SYSTEM_SSH_PUB=""
GHOST_URL=https://example.com
GHOST_STAFF_DEVICE_VERIFICATION=false
GHOST_DB_PASSWORD=change_me_ghost_db_password
```

`GHOST_URL` must be the public URL with protocol.
`GHOST_SYSTEM_USER` must not be `root` or `ghost`.
`GHOST_STAFF_DEVICE_VERIFICATION=false` disables Ghost's staff email verification code for new devices, which is useful when transactional email is not configured yet.

See also: [service-users.md](service-users.md)

## Run

Install Caddy first:

```bash
cd ~/ubuntu-scripts/caddy
bash setup-caddy.sh
```

Then run Ghost setup as root:

```bash
cd ~/ubuntu-scripts/ghost
bash setup-ghost.sh
```

The script creates `/etc/sudoers.d/90-ubuntu-scripts-ghost-<GHOST_SYSTEM_USER>` so Ghost-CLI can configure and restart systemd services without an interactive password prompt.

It also writes `"staffDeviceVerification": false` into Ghost's `config.production.json` by default.

After setup, open:

```text
https://example.com/ghost
```

## Domain Conflict Behavior

If `GHOST_URL` uses a domain that is already present in `/etc/caddy/Caddyfile`, the script behaves conservatively:

* If the existing block already points to `GHOST_BIND_IP:GHOST_PORT`, it is kept.
* If the existing block points somewhere else, setup asks whether to replace it.
* If the block was created by this module, it is updated safely between managed markers.

This avoids accidentally replacing an existing Caddy site.

For unattended runs, choose the behavior in `ghost/.env`:

```env
GHOST_CADDY_OVERWRITE_DOMAIN=ask
```

Allowed values:

* `ask` - ask before replacing the occupied domain
* `true` - replace without asking
* `false` - stop without replacing

Set this to skip Caddy changes:

```env
GHOST_CONFIGURE_CADDY=false
```

Use that only when you plan to configure Caddy manually.

## Verify

```bash
cd ~/ubuntu-scripts/ghost
bash check-setup.sh
```

The check script verifies:

* Node.js and Ghost-CLI
* MySQL service and Ghost database
* Ghost install directory
* Ghost listener port
* Caddyfile validation
* Caddy reverse proxy target
* UFW HTTP/HTTPS rules

## Open Ports

Ghost itself listens locally and does not need a public firewall rule.

Public ports are handled by the Caddy module:

* `80/tcp`
* `443/tcp`
