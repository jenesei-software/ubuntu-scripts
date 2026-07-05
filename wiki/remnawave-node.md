# Remnawave Node Module

The `remnawave-node/` module installs one Remnawave Node with Docker.

Unlike the panel, the node is not served through Caddy. It uses `network_mode: host`, listens directly on `PORT_NODE`, and optionally mounts TLS certificate files into the container.

## Files

```text
remnawave-node/
|-- env.example
|-- setup-remnawave-node.sh
`-- check-setup.sh
```

## Architecture

```text
Internet / Remnawave Panel
  |
  | PORT_NODE/tcp
  v
remnanode container
  |
  | network_mode: host
  v
Host network
```

Optional inbound proxy ports from `PORT_ARRAY_INBOUNDS` are opened in UFW.

## Prepare Env

```bash
cd ~/ubuntu-scripts/remnawave-node
cp env.example .env
nano .env
```

Required values:

```env
PORT_NODE=22222
NODE_SECRET=change_me_super_secret_key
```

Required when `SERVER_DOMAIN` is set:

```env
SERVER_DOMAIN=node.example.com
DOMAIN_MAIL=admin@example.com
```

The setup script rejects placeholder values for `NODE_SECRET`.

## Run

```bash
cd ~/ubuntu-scripts/remnawave-node
bash setup-remnawave-node.sh
```

The script:

* installs Docker if needed
* configures UFW for `PORT_NODE` and `PORT_ARRAY_INBOUNDS`
* issues a TLS certificate with `acme.sh` when `SERVER_DOMAIN` is set
* writes `/opt/remnanode/docker-compose.yml`
* starts the `remnanode` container
* applies the configured IPv6 mode

If `SERVER_DOMAIN` is empty, TLS certificate issuance is skipped and Docker Compose is written without `SSL_CERT`, `SSL_KEY`, or the certificate volume.

If `SERVER_DOMAIN` is set, `80/tcp` must be reachable and not occupied by another standalone ACME flow during issuance. On a server already using Caddy, prefer a separate node host or provide certificates manually before running without `SERVER_DOMAIN`.

## Service User

By default, Docker Compose operations run as root. To use a dedicated Linux user:

```env
REMNAWAVE_NODE_SYSTEM_USER=remnanodeadmin
REMNAWAVE_NODE_SYSTEM_PASSWORD=changeMeSystemPassword
REMNAWAVE_NODE_SYSTEM_SSH_PUB=""
```

When this is set, setup creates or reuses the user, updates its password when provided, adds the SSH key when provided, adds the user to `docker`, gives it `/opt/remnanode`, and runs Docker Compose operations as that user.

Details: [service-users.md](service-users.md)

## IPv6

Default:

```env
DISABLE_IPV6=true
```

This writes:

```text
/etc/sysctl.d/99-remnawave-node-disable-ipv6.conf
```

Set `DISABLE_IPV6=false` when the node should actively use IPv6. In that mode, setup:

* removes the Remnawave IPv6 disable sysctl file
* writes `/etc/sysctl.d/99-remnawave-node-enable-ipv6.conf`
* enables IPv6 forwarding
* enables router advertisements on the detected or configured interface
* disables temporary IPv6 addresses on that interface
* sets `IPV6=yes` in `/etc/default/ufw`

Use this to force the interface:

```env
IPV6_INTERFACE=eth0
```

## Verify

```bash
cd ~/ubuntu-scripts/remnawave-node
bash check-setup.sh
```

The check script verifies:

* Docker and Docker Compose
* Docker apt repository files
* service user Docker access when configured
* IPv6 sysctl state
* UFW rules for node and inbound ports
* `PORT_NODE` listener
* TLS certificate files when `SERVER_DOMAIN` is set
* `/opt/remnanode/docker-compose.yml`
* `remnanode` container status

## Useful Commands

Show status:

```bash
cd /opt/remnanode
docker compose ps
```

Show logs:

```bash
cd /opt/remnanode
docker compose logs -f
```

Restart node:

```bash
cd /opt/remnanode
docker compose restart
```

Recreate node after editing compose:

```bash
cd /opt/remnanode
docker compose up -d --force-recreate
```

Check certificate files:

```bash
ls -l /etc/ssl/remnawave-node
```

## Open Ports

This module opens:

* `PORT_NODE/tcp`
* every TCP port from `PORT_ARRAY_INBOUNDS`
* `80/tcp` and `443/tcp` when `SERVER_DOMAIN` is set

Caddy is not used by this module.
