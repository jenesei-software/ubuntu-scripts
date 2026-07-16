# Coolify

This module installs or upgrades one self-hosted Coolify instance by downloading and executing the current official installer from `https://cdn.coollabs.io/coolify/install.sh`.

The wrapper adds repository-standard env loading, strict validation, resource and port preflight checks, UFW rules, provenance checks for the downloaded installer, and post-install health verification. The vendor installer remains responsible for Docker, `/data/coolify`, the localhost SSH key, Compose files, secrets, containers, and upgrades.

## Important Isolation Requirement

Use a fresh, dedicated Ubuntu 24.04 server when possible. Coolify's integrated proxy needs ports `80` and `443`, while its dashboard and realtime services initially publish `8000`, `6001`, and `6002`.

Do not install the repository's `caddy/` module on the same host before Coolify. An active Caddy, Nginx, Apache, or another proxy on `80/443` blocks Coolify's default proxy. The setup script stops before installation when those ports are occupied.

`COOLIFY_ALLOW_PROXY_PORT_CONFLICTS=true` only acknowledges an intentional advanced custom-proxy design. It does not reconfigure Coolify or the existing proxy.

### Existing Caddy versus Coolify Caddy

Coolify can use Caddy as its own integrated proxy, but that support is currently marked experimental. It is a separate Caddy instance whose configuration is generated and managed by Coolify under `/data/coolify/proxy`; Coolify does not import or extend the system `/etc/caddy/Caddyfile` installed by this repository.

Therefore an existing system Caddy and Coolify's integrated Caddy both want public ports `80/443` and cannot run with their default bindings on the same IP. The repository keeps the models separate:

- ordinary service modules such as YouTrack and Authentik bind to `127.0.0.1` and use the existing system Caddy;
- a normal Coolify host is dedicated to Coolify and uses the proxy managed by Coolify;
- `COOLIFY_ALLOW_PROXY_PORT_CONFLICTS=true` is only an escape hatch for a manually designed custom-proxy topology, not automatic integration.

Although Coolify exposes proxy selection between Traefik and Caddy, its documentation still recommends Traefik for the most complete and tested integration.

## Requirements

- Ubuntu 24.04 LTS
- root access
- amd64 (`x86_64`) or arm64 (`aarch64`)
- at least 2 CPU cores
- at least 2 GB RAM
- at least 30 GB total and free disk space for a new installation
- working outbound HTTPS access to Coolify's CDN and container registries
- inbound SSH on the server's configured SSH port
- inbound TCP `80`, `443`, `8000`, `6001`, and `6002` during initial setup

The setup script requires 5 GB of free space when it detects an existing installation and is being used for an upgrade. Resource checks can be bypassed only with `COOLIFY_ALLOW_LOW_RESOURCES=true`, intended for disposable test hosts.

Docker installed through Snap is not supported. The official installer installs Docker Engine 24+ when necessary.

## Install

From the root-owned repository checkout:

```bash
cd ~/ubuntu-scripts/coolify
cp env.example .env
nano .env
chmod 600 .env
bash setup-coolify.sh
bash check-setup.sh
```

You may pass a different env file explicitly:

```bash
bash setup-coolify.sh /root/coolify.production.env
bash check-setup.sh /root/coolify.production.env
```

## Environment Variables

- `COOLIFY_VERSION`: empty selects the current stable release; set an exact version such as `4.1.2` to pin an install or upgrade.
- `AUTOUPDATE`: `true` by default; set `false` to disable Coolify automatic updates.
- `REGISTRY_URL`: image registry host used by the official installer; defaults to `docker.io`.
- `DOCKER_ADDRESS_POOL_BASE`: Docker default network pool base; defaults to `10.0.0.0/8`.
- `DOCKER_ADDRESS_POOL_SIZE`: Docker network subnet size from 16 through 28; defaults to `24`.
- `DOCKER_POOL_FORCE_OVERRIDE`: permits the vendor installer to replace an existing Docker address-pool setting. Keep `false` unless the network migration is intentional.
- `ROOT_USERNAME`, `ROOT_USER_EMAIL`, `ROOT_USER_PASSWORD`: optional predefined first administrator. Set all three or none. The wrapper requires at least 12 password characters and never prints the value. Because of an upstream installer limitation, the email and password cannot contain `|`, `&`, or a backslash.
- `COOLIFY_ALLOW_PROXY_PORT_CONFLICTS`: permits occupied `80/443` during a new install. This is not compatible with the default Coolify proxy without additional manual configuration.
- `COOLIFY_CONFIGURE_UFW`: adds allow rules for the five Coolify TCP ports, but never enables UFW.
- `COOLIFY_ALLOW_LOW_RESOURCES`: bypasses documented hardware preflight failures.

The official installer writes stable generated secrets to `/data/coolify/source/.env`. Back up that file securely outside the server. Do not copy it into this repository.

## First Login

Open:

```text
http://SERVER_IP:8000
```

If the administrator variables were left empty, create the first administrator immediately. Until the first account is claimed, anyone who can reach the registration page may gain control of the server.

After login, configure the Coolify instance domain and integrated proxy, verify HTTPS, and then close direct public access to `8000`, `6001`, and `6002` in the provider firewall if they are no longer needed. Keep `80/443` open for application traffic and certificate issuance.

## Firewall

The module can add idempotent UFW allow rules for:

- `80/tcp`: HTTP and certificate validation
- `443/tcp`: HTTPS application traffic
- `8000/tcp`: initial dashboard access
- `6001/tcp`: realtime communications
- `6002/tcp`: terminal access

Docker publishes ports through iptables/NAT and can bypass normal UFW filtering. Use the cloud/provider firewall as the primary public exposure control. UFW rules alone are not proof that a Docker port is closed.

## Upgrade

Back up Coolify and its `/data/coolify/source/.env` first. Then rerun the same wrapper:

```bash
cd ~/ubuntu-scripts/coolify
bash setup-coolify.sh
bash check-setup.sh
```

For a controlled upgrade, set `COOLIFY_VERSION` to an exact vendor version before rerunning. The official installer is designed to be idempotent and preserves existing data and secrets.

## Diagnostics

Run the non-destructive checker:

```bash
cd ~/ubuntu-scripts/coolify
bash check-setup.sh
```

Useful manual commands:

```bash
docker ps --filter name=coolify
docker logs --tail 200 coolify
docker inspect --format '{{.State.Health.Status}}' coolify
curl -fsS http://127.0.0.1:8000/api/health
ls -1t /data/coolify/source/installation-*.log | head
```

The checker validates Ubuntu and resources, Docker 24+, Compose, required files and permissions, the `coolify` network, the four core containers, published ports, the local health endpoint, localhost SSH key access, and UFW rules. It exits nonzero when required checks fail.

## Upstream Documentation

- [Self-hosted installation](https://coolify.io/docs/get-started/installation)
- [Firewall requirements](https://coolify.io/docs/knowledge-base/server/firewall)
- [Supported proxies](https://coolify.io/docs/knowledge-base/server/proxies)
- [Coolify Caddy proxy](https://coolify.io/docs/knowledge-base/proxy/caddy)
- [Server and SSH requirements](https://coolify.io/docs/knowledge-base/server/introduction)
- [Upgrading](https://coolify.io/docs/get-started/upgrade/)
- [Uninstalling](https://coolify.io/docs/get-started/uninstallation/)

Uninstallation is intentionally not automated in this repository because the official procedure removes Coolify containers, volumes, networks, images, and all data under `/data/coolify`.
