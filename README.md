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
|-- coolify/
|   |-- env.example
|   |-- check-setup.sh
|   `-- setup-coolify.sh
|-- authentik/
|   |-- env.example
|   |-- check-setup.sh
|   |-- setup-authentik.sh
|   `-- setup-youtrack-oidc.sh
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
|-- youtrack/
|   |-- env.example
|   |-- check-setup.sh
|   `-- setup-youtrack.sh
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
    |-- coolify.md
    |-- authentik.md
    |-- ghost.md
    |-- netdata.md
    |-- remnawave-node.md
    |-- remnawave-panel.md
    |-- service-users.md
    |-- supabase.md
    |-- uptime-kuma.md
    |-- youtrack.md
    |-- umami.md
    |-- web-audits.md
    `-- ubuntu.md
```

## Modules

### `ubuntu/`

Base Ubuntu hardening with key-only SSH authentication. The setup uses an early managed OpenSSH drop-in, and the check validates effective settings with `sshd -T`.

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

### `coolify/`

One self-hosted Coolify control plane using the official Coolify installer.

Use a fresh, dedicated Ubuntu 24.04 server. The recommended installation order is `ubuntu/` followed directly by `coolify/`. Do not install the repository's `caddy/` module on the same server: Coolify manages its own proxy and needs public ports `80/443`.

```bash
cd ~/ubuntu-scripts/coolify
cp env.example .env
nano .env
bash setup-coolify.sh
bash check-setup.sh
```

After installation, replace `SERVER_IP` with the server's public IP and open `http://SERVER_IP:8000` in a web browser for the initial login. For example, if SSH uses `root@203.0.113.10`, open `http://203.0.113.10:8000`. Configure `https://coolify.example.com` as the instance domain in Coolify; after HTTPS works, use the domain instead of port `8000`.

Immediately create the first administrator if predefined credentials were not set in `coolify/.env`. With the default `COOLIFY_CONFIGURE_UFW=true`, the setup adds UFW allow rules for `80`, `443`, `8000`, `6001`, and `6002`, but it does not enable UFW or change the hosting provider's firewall.

Documentation: [wiki/coolify.md](wiki/coolify.md)

### `youtrack/`

One YouTrack Server instance behind the existing system Caddy.

```bash
cd ~/ubuntu-scripts/youtrack
cp env.example .env
nano .env
bash setup-youtrack.sh
bash check-setup.sh
```

On a new installation, finish the JetBrains setup wizard and use the public HTTPS URL as the YouTrack Base URL.

Documentation: [wiki/youtrack.md](wiki/youtrack.md)

### `authentik/`

One Authentik identity provider behind the existing system Caddy, with optional native OIDC integration for YouTrack 2026.1+.

```bash
cd ~/ubuntu-scripts/authentik
cp env.example .env
nano .env
bash setup-authentik.sh
bash check-setup.sh
```

After both services are initialized, prepare the YouTrack OIDC provider:

```bash
cd ~/ubuntu-scripts/authentik
bash setup-youtrack-oidc.sh
```

Documentation: [wiki/authentik.md](wiki/authentik.md)

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

The Coolify module opens:

* `80/tcp`
* `443/tcp`
* `8000/tcp`
* `6001/tcp`
* `6002/tcp`

Coolify publishes ports through Docker. Docker NAT rules can bypass ordinary UFW filtering, so use the provider firewall to control public exposure. After configuring a Coolify domain and integrated proxy, direct access to `8000`, `6001`, and `6002` can normally be closed at the provider firewall.

The Ghost module does not open public ports directly. Ghost listens on a local port, and Caddy proxies public HTTP/HTTPS traffic to it.

The Umami module does not open public ports directly. Umami listens on a local port, and Caddy proxies public HTTP/HTTPS traffic to it.

The Uptime Kuma module does not open public ports directly. Uptime Kuma listens on a local port, and Caddy proxies public HTTP/HTTPS traffic to it.

The YouTrack and Authentik modules do not open public application ports directly. Their HTTP ports bind to loopback, and the existing system Caddy terminates public HTTPS. Authentik's internal HTTPS port also remains loopback-only.

The Netdata module does not open public ports directly. Netdata listens on a local port, and Caddy proxies public HTTP/HTTPS traffic to it. Netdata is protected with Caddy basic auth by default.

The Supabase module does not open public ports directly. Supabase Kong and Supavisor are bound to local IP addresses by default, and Caddy proxies public HTTP/HTTPS traffic to Kong.

The Remnawave Panel module does not open public ports directly. Remnawave Panel and the bundled subscription page are bound to local IP addresses by default, and Caddy proxies public HTTP/HTTPS traffic to them.

The Remnawave Node module opens `PORT_NODE/tcp`, every TCP port from `PORT_ARRAY_INBOUNDS`, and `80/tcp` plus `443/tcp` when `SERVER_DOMAIN` is set for certificate issuance. Caddy is not used by this module.

The Caddy module installs UFW if needed and adds the HTTP/HTTPS rules. It does not force-enable UFW by itself, because enabling a firewall from an isolated Caddy script could affect SSH access on servers that did not run the Ubuntu module first.

## Rules For New Modules

* Follow the production and verification requirements in [AGENTS.md](AGENTS.md).
* Put each install target in its own folder.
* Put module-specific variables in that folder's `env.example`.
* Make scripts default to that folder's `.env`.
* Keep module docs in `wiki/<module>.md`.
* Do not add module-level README files unless there is a specific reason.
* Avoid reading root `.env` files.
