# Server Scripts

This repository is a collection of isolated server setup scripts.

Each folder is a separate module. A module keeps its own scripts, its own `env.example`, and its own local `.env` file. Scripts should not depend on another module's `.env` unless that dependency is explicitly documented.

## Requirements

Before you begin, make sure you have:

* a server running **Ubuntu 24.04**
* root access to the server
* a domain name already pointed to the server if you want Caddy to issue TLS certificates
* a valid SSH public key for the `ubuntu/` module
* the ability to open the required ports from the internet

## Root Checkout

Download this repository once as `root` and run every module from that same checkout:

```bash
ssh root@YOUR_SERVER_IP
apt update && apt install -y git
git clone https://github.com/jenesei-software/ubuntu-scripts.git ubuntu-scripts
cd ubuntu-scripts
```

Do not copy module scripts into service users' home directories. Service modules can create their own Linux users internally, but the scripts stay in the root-owned `ubuntu-scripts` directory.

Service user model: [wiki/service-users.md](wiki/service-users.md)

## Structure

```text
.
|-- README.md
|-- caddy/
|   |-- env.example
|   |-- check-setup.sh
|   `-- setup-caddy.sh
|-- ghost/
|   |-- env.example
|   |-- check-setup.sh
|   `-- setup-ghost.sh
|-- netdata/
|   |-- env.example
|   |-- check-setup.sh
|   `-- setup-netdata.sh
|-- remnawave-node/
|   |-- env.example
|   |-- check-setup.sh
|   `-- setup-remnawave-node.sh
|-- remnawave-panel/
|   |-- env.example
|   |-- check-setup.sh
|   |-- setup-remnawave-panel.sh
|   `-- setup-subscription-page.sh
|-- supabase/
|   |-- env.example
|   |-- check-setup.sh
|   `-- setup-supabase.sh
|-- uptime-kuma/
|   |-- env.example
|   |-- check-setup.sh
|   `-- setup-uptime-kuma.sh
|-- umami/
|   |-- env.example
|   |-- check-setup.sh
|   `-- setup-umami.sh
|-- web-audits/
|   |-- env.example
|   |-- check-setup.sh
|   `-- run-web-audit.sh
|-- ubuntu/
|   |-- env.example
|   |-- setup-ubuntu.sh
|   `-- check-setup.sh
`-- wiki/
    |-- caddy.md
    |-- ghost.md
    |-- netdata.md
    |-- remnawave-node.md
    |-- remnawave-panel.md
    |-- service-users.md
    |-- supabase.md
    |-- uptime-kuma.md
    |-- umami.md
    |-- web-audits.md
    `-- ubuntu.md
```

## Modules

### `ubuntu/`

Base Ubuntu hardening and SSH setup.

Use only `ubuntu/.env`:

```bash
cd ~/ubuntu-scripts/ubuntu
cp env.example .env
nano .env
bash setup-ubuntu.sh
bash check-setup.sh
```

Documentation: [wiki/ubuntu.md](wiki/ubuntu.md)

### `caddy/`

Caddy installation and optional reverse proxy configuration.

Base install without a domain:

```bash
cd ~/ubuntu-scripts/caddy
bash setup-caddy.sh
bash check-setup.sh
```

If `caddy/.env` is missing, or if `CADDY_DOMAIN` and `CADDY_UPSTREAM` are empty, the script installs and starts Caddy without replacing the current Caddyfile. Service modules can add their own domains later.

Documentation: [wiki/caddy.md](wiki/caddy.md)

### `ghost/`

One production Ghost instance behind Caddy.

Use only `ghost/.env`:

```bash
cd ~/ubuntu-scripts/ghost
cp env.example .env
nano .env
bash setup-ghost.sh
bash check-setup.sh
```

The Ghost module is started by root from this checkout and creates/uses the Ghost system user from `ghost/.env` only for running Ghost itself.

Documentation: [wiki/ghost.md](wiki/ghost.md)

### `uptime-kuma/`

One Uptime Kuma status monitor behind Caddy.

Use only `uptime-kuma/.env`:

```bash
cd ~/ubuntu-scripts/uptime-kuma
cp env.example .env
nano .env
bash setup-uptime-kuma.sh
bash check-setup.sh
```

Default public URL: `https://status.cyrilstrone.com`

Documentation: [wiki/uptime-kuma.md](wiki/uptime-kuma.md)

### `netdata/`

One Netdata server dashboard behind Caddy basic auth.

Use only `netdata/.env`:

```bash
cd ~/ubuntu-scripts/netdata
cp env.example .env
nano .env
bash setup-netdata.sh
bash check-setup.sh
```

Default public URL: `https://server.cyrilstrone.com`

Documentation: [wiki/netdata.md](wiki/netdata.md)

### `remnawave-panel/`

One Remnawave Panel instance and bundled subscription page behind Caddy.

Use only `remnawave-panel/.env`:

```bash
cd ~/ubuntu-scripts/remnawave-panel
cp env.example .env
nano .env
bash setup-remnawave-panel.sh
```

After creating the first Remnawave admin and API token, run:

```bash
cd ~/ubuntu-scripts/remnawave-panel
bash setup-subscription-page.sh
bash check-setup.sh
```

Documentation: [wiki/remnawave-panel.md](wiki/remnawave-panel.md)

### `remnawave-node/`

One Remnawave Node with Docker and direct node ports.

Use only `remnawave-node/.env`:

```bash
cd ~/ubuntu-scripts/remnawave-node
cp env.example .env
nano .env
bash setup-remnawave-node.sh
bash check-setup.sh
```

Remnawave Node is not Caddy-managed. It uses `network_mode: host` and listens directly on `PORT_NODE`.

Documentation: [wiki/remnawave-node.md](wiki/remnawave-node.md)

### `supabase/`

One self-hosted Supabase project behind Caddy.

Use only `supabase/.env`:

```bash
cd ~/ubuntu-scripts/supabase
cp env.example .env
nano .env
bash setup-supabase.sh
bash check-setup.sh
```

Supabase requires more resources than the smaller service modules. Use at least 4 GB RAM, with 8 GB+ RAM recommended.

Documentation: [wiki/supabase.md](wiki/supabase.md)

### `umami/`

One Umami Analytics instance behind Caddy.

Use only `umami/.env`:

```bash
cd ~/ubuntu-scripts/umami
cp env.example .env
nano .env
bash setup-umami.sh
bash check-setup.sh
```

Documentation: [wiki/umami.md](wiki/umami.md)

### `web-audits/`

One-off website audits with Lighthouse CI and sitespeed.io.

Use only `web-audits/.env`; the env file is optional:

```bash
cd ~/ubuntu-scripts/web-audits
cp env.example .env
nano .env
bash run-web-audit.sh
```

Reports are saved under `web-audits/reports/<site>/<timestamp>/` and can be zipped for download to Windows.

Documentation: [wiki/web-audits.md](wiki/web-audits.md)

## Firewall Summary

The Ubuntu module opens:

* `PORT_SSH/tcp`

The Caddy module opens:

* `80/tcp`
* `443/tcp`

The Ghost module does not open public ports directly. Ghost listens on a local port, and Caddy proxies public HTTP/HTTPS traffic to it.

The Umami module does not open public ports directly. Umami listens on a local port, and Caddy proxies public HTTP/HTTPS traffic to it.

The Uptime Kuma module does not open public ports directly. Uptime Kuma listens on a local port, and Caddy proxies public HTTP/HTTPS traffic to it.

The Netdata module does not open public ports directly. Netdata listens on a local port, and Caddy proxies public HTTP/HTTPS traffic to it. Netdata is protected with Caddy basic auth by default.

The Supabase module does not open public ports directly. Supabase Kong and Supavisor are bound to local IP addresses by default, and Caddy proxies public HTTP/HTTPS traffic to Kong.

The Remnawave Panel module does not open public ports directly. Remnawave Panel and the bundled subscription page are bound to local IP addresses by default, and Caddy proxies public HTTP/HTTPS traffic to them.

The Remnawave Node module opens `PORT_NODE/tcp`, every TCP port from `PORT_ARRAY_INBOUNDS`, and `80/tcp` plus `443/tcp` when `SERVER_DOMAIN` is set for certificate issuance. Caddy is not used by this module.

The Caddy module installs UFW if needed and adds the HTTP/HTTPS rules. It does not force-enable UFW by itself, because enabling a firewall from an isolated Caddy script could affect SSH access on servers that did not run the Ubuntu module first.

## Rules For New Modules

* Put each install target in its own folder.
* Put module-specific variables in that folder's `env.example`.
* Make scripts default to that folder's `.env`.
* Keep module docs in `wiki/<module>.md`.
* Do not add module-level README files unless there is a specific reason.
* Avoid reading root `.env` files.
