# Mistgate Module

The `mistgate/` module installs one self-hosted Mistgate panel on a dedicated Ubuntu 24.04 server and keeps it under systemd.

Mistgate is a control panel for a small VPN fleet. The panel holds users, groups, protocol profiles and servers in one SQLite database, serves subscriptions and user pages, and hides the admin behind a decoy site. Each VPN server runs a `mistgate-node` agent that connects outbound to the panel and applies the desired state.

There is intentionally no `mistgate-node/` module in this repository: the panel installs the agent on a node itself, over SSH, or prints a one-time manual command. See [Node servers](#node-servers).

References:

* https://mistgate.app/ru/getting-started/overview/
* https://mistgate.app/ru/getting-started/install-panel/
* https://mistgate.app/ru/getting-started/ssh-install/
* https://mistgate.app/ru/operations/security/
* https://github.com/Mistgate/mistgate

## Files

```text
mistgate/
|-- env.example
|-- setup-mistgate.sh
|-- update-mistgate.sh
|-- check-setup.sh
|-- use-decoy-site.sh
`-- decoy-sites/
```

`setup-mistgate.sh` also installs `/usr/local/bin/mistgate-decoy`, a small wrapper around `use-decoy-site.sh`; use it to replace the panel decoy site.

## Architecture

```text
Clients                Panel server                     Node server
  |                        |                                 |
  | HTTPS 443              |                                 |
  | (decoy site,           |                                 |
  |  subscriptions,        |                                 |
  |  user pages)           |                                 |
  v                        |                                 |
Internet -------------> mistgate serve <---- mTLS ------ mistgate-node
                           |  (agents connect outbound)      |
                           |                                 |
                           | TCP 443/80                      | UDP 443 Hysteria2
                           | (no CDN, no proxy)              | TCP 443 decoy/ACME
                           |                                 | UDP 10000-60000 AmneziaWG
                           v                                 v
                     /var/lib/mistgate                  /var/lib/mistgate-node
                     SQLite + master.key + acme/        identity, CA, state
```

The panel never connects to a node to manage it; the agent keeps one connection open and receives changes. SSH is used by the panel only to install a node (or to change its server password, if you keep that access).

### Service Model

Mistgate runs as `root`, as upstream requires: `mistgate setup` creates a root-owned data directory and the service binds `80/443`. The unit drops every capability except `CAP_NET_BIND_SERVICE`, sets `NoNewPrivileges=yes` and `ProtectSystem=strict`, and can write only `MISTGATE_DATA_DIR`; `/home` and `/root` are hidden. There is no dedicated service user, because the panel's self-update helper needs to replace a root-owned binary and restart the unit.

## Requirements

Panel server:

* Ubuntu 24.04, amd64 or arm64
* root access
* systemd
* a hostname whose A/AAAA record points directly at the server, for example `panel.example.com`
* inbound `80/tcp` and `443/tcp`, with **no CDN or TLS-terminating proxy** in front: node agents verify the panel's own CA over TCP 443, and Let's Encrypt must validate the domain on this server
* outbound HTTPS to GitHub (`api.github.com`, `github.com` and its download host) for the node package and panel updates
* at least 1 CPU, 512 MB RAM and about 3 GB free disk

Do not install the `caddy/` module on the same server unless you choose `MISTGATE_TLS_MODE=caddy`. Coolify and other proxies also conflict with the panel's own `80/443`.

## Prepare Env

```bash
cd ~/ubuntu-scripts/mistgate
cp env.example .env
nano .env
```

Required values:

```env
MISTGATE_PUBLIC_URL=https://panel.example.com
```

Recommended:

```env
MISTGATE_ACME_EMAIL=admin@example.com
```

The setup script rejects placeholder values, relative paths, an admin host equal to the public host, non-loopback admin listeners, and a public URL with a path, port or query.

## Run

### Base Profile

On the panel server, set the base profile before running `ubuntu/`:

```env
MISTGATE_ROLE=panel
```

in `ubuntu/.env`. The base then opens `80/tcp` and `443/tcp` in UFW; it does **not** install or configure Mistgate itself. After the base, run this module separately.

### Panel Server

```bash
# first login as root, run the base module with MISTGATE_ROLE=panel
ssh root@panel.example.com
cd /root/ubuntu-scripts/ubuntu
cp env.example .env
nano .env                         # MISTGATE_ROLE=panel
bash setup-ubuntu.sh

# ubuntu/ closes root SSH and password auth; reconnect as deploy
ssh -p 10022 deploy@panel.example.com
sudo -i

cd /root/ubuntu-scripts/mistgate
cp env.example .env
nano .env                         # MISTGATE_PUBLIC_URL, MISTGATE_ACME_EMAIL
bash setup-mistgate.sh
bash check-setup.sh
```

The setup script:

* detects an existing Mistgate unit with the same data directory and repairs it in place; refuses a unit that belongs to another data directory or another program
* checks Ubuntu, architecture, systemd, commands, CPU/RAM/disk, DNS and free ports
* resolves the newest release in the configured channel (or the pinned `MISTGATE_VERSION`)
* downloads `mistgate-linux-<arch>`, `SHA256SUMS`, `panel-manifest.json` and its Ed25519 signature
* verifies the checksums, the signed manifest, the expiry, the size and the SHA-256 of the binary
* installs `/usr/local/bin/mistgate`
* runs `mistgate setup` with the selected admin mode
* writes `/etc/systemd/system/mistgate.service` with the upstream hardening profile
* enables and starts the service
* adds `80/tcp`, `443/tcp` (and the agent port in Caddy mode) to UFW when UFW is active
* waits for the panel to answer and prints the admin URL and the one-time setup link

At the end, open the setup link as a whole, including everything after `#`. It works once and expires in 30 minutes. Create the owner account with a passkey (recommended) or a password plus an authenticator code.

The admin URL is stored root-only in `/etc/mistgate/admin-url`. Never publish it: it contains the secret path.

### TLS Modes

`MISTGATE_TLS_MODE=acme` (default) is the supported layout. The panel listens on `:443`, obtains and renews Let's Encrypt certificates with TLS-ALPN-01, and uses port 80 for HTTP-01 and the HTTP-to-HTTPS redirect.

`MISTGATE_TLS_MODE=files` serves your own certificate and key:

```env
MISTGATE_TLS_MODE=files
MISTGATE_TLS_CERT=/etc/ssl/mistgate/fullchain.pem
MISTGATE_TLS_KEY=/etc/ssl/mistgate/privkey.pem
```

The panel re-reads the files when they change, so an external renewal does not need a restart. Keep the key root-only. If the admin uses a secret host, the certificate must cover that host.

`MISTGATE_TLS_MODE=caddy` runs the panel on `127.0.0.1:8080` behind the repository's Caddy module and moves the agent endpoint to a separate TLS listener:

```env
MISTGATE_TLS_MODE=caddy
MISTGATE_AGENT_PORT=8443
```

Caddy must proxy the public host to `127.0.0.1:8080` and must **not** proxy `8443`: node agents connect there and pin the panel CA. This mode is a compromise for hosts where something else owns `443`; prefer the default.

### Admin Modes

`MISTGATE_ADMIN_MODE=path` (default) keeps the admin under `https://panel.example.com/<24 random characters>/`.

`MISTGATE_ADMIN_MODE=host` serves the admin on a separate secret host:

```env
MISTGATE_ADMIN_MODE=host
MISTGATE_ADMIN_HOST=admin-k7q2.example.com
```

The host needs its own DNS record. In `acme` mode the setup script adds it to the certificate names automatically; Let's Encrypt will publish it in Certificate Transparency logs. Use a wildcard certificate with `MISTGATE_TLS_MODE=files` if the host name itself must stay secret.

`MISTGATE_ADMIN_MODE=listen` binds the admin to loopback only:

```env
MISTGATE_ADMIN_MODE=listen
MISTGATE_ADMIN_LISTEN=127.0.0.1:8081
```

Reach it through an SSH tunnel:

```bash
ssh -N -p 10022 -L 8081:127.0.0.1:8081 deploy@panel.example.com
```

Then open `http://localhost:8081/`. Passkeys are bound to the exact admin address stored by `mistgate setup`; changing the address later is not supported without a new data directory.

### Decoy Site

The built-in "Coming soon" page is identical on every installation and therefore recognizable. The module prepares a real directory and connects it to the panel:

```env
MISTGATE_DECOY_DIR=/srv/mistgate-decoy
```

On the first run the directory is created, and if it is empty, one of the five starter sites from `mistgate/decoy-sites/` is copied into it. Choose one explicitly, or let the panel hostname pick:

```env
MISTGATE_DECOY_SITE=auto
# rybalka | palatki | gazirovka | bakery | veloservice
```

The starters are small fictional sites:

| Name | Theme |
| --- | --- |
| `rybalka` | fishing shop and lake trips |
| `palatki` | tents and camping gear |
| `gazirovka` | a small project about sugar in drinks |
| `bakery` | a neighbourhood bakery |
| `veloservice` | bicycle repair |

They are starting points, not production decoys. Replace the files or edit the texts before sharing the address; the same starter on many installations is as recognizable as the built-in page. When setup installs a starter it prints a warning, and `check-setup.sh` keeps warning while the `starter-site:` comment remains.

After installation just run one command with your site directory:

```bash
sudo mistgate-decoy /root/my-site
```

That validates the site, backs up the old directory, copies the files, fixes permissions and leaves the panel serving the new pages without a restart. If the site is on your laptop, upload and install it in one line:

```bash
scp -r ./my-site deploy@panel.example.com:/tmp/my-site && ssh -p 10022 deploy@panel.example.com 'sudo mistgate-decoy /tmp/my-site'
```

To use another starter:

```bash
sudo mistgate-decoy --list
sudo mistgate-decoy rybalka
```

The old directory is kept as `/srv/mistgate-decoy.bak.<timestamp>`; the command prints it. To roll back:

```bash
sudo mistgate-decoy /srv/mistgate-decoy.bak.<timestamp>
```

The setup script never overwrites an existing site on its own. A non-empty directory without `index.html`, a symlink anywhere in the tree, or unreadable files stops the helper before it touches the target.

Only adding or removing `MISTGATE_DECOY_DIR` itself needs a rerun of `setup-mistgate.sh`; replacing the files does not.

The directory needs `index.html`; optional `404.html`, `429.html` and `robots.txt` replace the built-ins. It must be outside `/home` and `/root` (the service has `ProtectHome=yes`). If `robots.txt` is absent, the panel serves one that blocks known AI crawlers.

The same directory is used for nodes: with a valid panel decoy site, a new node can use **Сайт панели** and receive a copy of these files. That is why the 2 MiB / 4096 file limits and the no-symlink rule matter. A larger directory still works for the panel itself, but nodes will not be offered it.

Do not use a public template or the same texts on several installations: the point is to look like an ordinary small site. The upstream guide also warns against VPN, proxy, tunnel, server, hosting or Mistgate words anywhere in the pages.

Verify from your own machine:

```bash
curl -si https://panel.example.com/ | head -n 20
curl -si https://panel.example.com/no-such-page-7f3a | head -n 20
```

The first call should return `200` with your home page; the second should return your `404.html`.

## First Login

1. Open the one-time setup link.
2. Choose a language.
3. Create the owner:
   * **passkey** — fingerprint, face, PIN or hardware key; recommended;
   * **password + code** — at least 12 characters plus a TOTP authenticator.
4. Add the first node, or look around first.

The login name accepts 3-64 characters from `a-z 0-9 . _ @ -`. Five wrong passwords in an hour lock that login for 15 minutes. If the phone or passkey is lost, use `mistgate auth reset-login` on the server.

## Node Servers

A node is an ordinary Linux server, not a Docker host. Requirements:

* Ubuntu 22.04+ or Debian 12+, amd64 or arm64, systemd
* root access for installation
* public IPv4; clients connect to the node address (domain or IP)
* `nft` (`apt-get install -y nftables`) — on cloud Debian 13 images it is missing
* `/dev/net/tun` for AmneziaWG userspace and WARP (enable TUN in the provider panel on OpenVZ/LXC)
* NTP synchronization
* no other VPN panel, Xray, old WireGuard interface or conflicting NAT rules

A node does not need Docker, Caddy, a control port, or an inbound SSH rule kept open after installation.

### With `ubuntu/` Profiles

The `ubuntu/` module sets `PermitRootLogin no`, `PasswordAuthentication no` and a custom `PORT_SSH` (default `10022`). Set its Mistgate profile so the base opens the right ports:

```env
MISTGATE_ROLE=node
```

The base then opens `80/tcp` and `443/tcp` in UFW. Do not add those rules by hand.

**Panel SSH auto-install.** This needs the panel's public key in `USER_NAME`'s `authorized_keys` and passwordless sudo for that user, because root SSH stays disabled:

1. Install the panel first and copy its key from **Nodes → Add node → Ключ панели → Скопировать ключ**.
2. Put it in `ubuntu/.env`:
   ```env
   MISTGATE_ROLE=node
   MISTGATE_PANEL_SSH_PUB=ssh-ed25519 AAAA... mistgate-panel
   MISTGATE_PANEL_SSH_NOPASSWD=true
   ```
3. Run `bash setup-ubuntu.sh`. It adds the key to `USER_NAME` and writes a `visudo`-validated `/etc/sudoers.d/90-mistgate-panel` (`USER_NAME ALL=(ALL) NOPASSWD:ALL`).
4. In the panel wizard use SSH port `PORT_SSH`, login `USER_NAME`, method **Ключ панели**.

`NOPASSWD:ALL` is broader than the agent needs; accept it only if you want the panel to manage this server over SSH. The panel then keeps a saved SSH access to the node.

**Manual one-time install (safer, no passwordless sudo).** The agent only needs outbound TCP to the panel:

1. Set `MISTGATE_ROLE=node`, leave `MISTGATE_PANEL_SSH_NOPASSWD=false`.
2. Run `bash setup-ubuntu.sh`. The node profile installs `nftables` and opens `80/443`.
3. Hysteria2 UDP port rules are added by the agent itself when a profile is applied. Do not pre-open `443/udp` with an unmarked rule unless you plan to manage it yourself; the agent never modifies or removes someone else's rule.
4. In the panel open **Nodes → Add node → Получить команду для ручной установки**, fill in the name, country and public address, and copy the command.
5. On the node, copy the agent from the panel and run the command as root. With `ubuntu/`, root SSH is closed, so run the copy **on the panel** and log in as the deploy user on the node:
   ```bash
   # on the panel
   scp -P 10022 /var/lib/mistgate/dist/mistgate-node-linux-amd64 deploy@node.example.com:/tmp/mistgate-node

   # on the node
   ssh -p 10022 deploy@node.example.com
   sudo install -m 0755 /tmp/mistgate-node /root/mistgate-node
   sudo /root/mistgate-node enroll --panel panel.example.com:443 --sni '<secret>' \
     --ca-sha256 '<fingerprint>' --token '<one-time-token>'
   sudo /root/mistgate-node install
   ```
   The panel window prints the exact values and a ready command. The token is one-time and expires after an hour. Replace `amd64` with `arm64` when the node is ARM.

The panel's installer itself opens `80/tcp`, `443/tcp` and `443/udp` in an active UFW (or the same in active firewalld zones), installs `nftables` when missing, transfers the signed agent, enrolls it with a one-time token over stdin, writes the `mistgate-node` unit and waits up to two minutes for the connection.

### After the Node Connects

The node appears in **Nodes** with status **Работает**. Add a profile to it (**Добавить профиль на …**), then create users and groups. Until a node has at least one profile, users do not receive it.

The agent manages only its own objects: its nftables tables, its marked UFW rules, its `mgawg*`/`mgwarp` interfaces, `/etc/sysctl.d/90-mistgate.conf`, `/etc/systemd/journald.conf.d/90-mistgate.conf` and its own state directory. It never removes unmarked firewall rules or other people's tables.

### Removing a Node

Use **Сервер → Опасная зона → Вывести из флота** in the panel. The panel revokes the certificate and tells a connected agent to stop its servers and clean up. A node that is offline keeps running with its last applied state until you clean it manually; the panel displays the exact commands. The generic cleanup sequence is:

```bash
systemctl disable --now mistgate-node
rm -f /etc/systemd/system/mistgate-node.service
systemctl daemon-reload
rm -f /usr/local/bin/mistgate-node /usr/local/bin/mistgate-node.prev /usr/local/bin/mistgate-node.new /root/mistgate-node
rm -rf /var/lib/mistgate-node
nft delete table inet mistgate_node 2>/dev/null || true
rm -f /etc/sysctl.d/90-mistgate.conf /etc/systemd/journald.conf.d/90-mistgate.conf
systemctl restart systemd-journald
ufw delete allow 80/tcp 2>/dev/null || true
ufw delete allow 443/tcp 2>/dev/null || true
```

Do not remove the SSH protection rules and the agent binary while the panel still expects the node; retire it in the panel first.

## Verify

```bash
cd ~/ubuntu-scripts/mistgate
bash check-setup.sh
```

The check script is read-only and verifies:

* Ubuntu, architecture and systemd
* the installed binary, version and release-key fingerprint
* the data directory mode, `master.key`, database, ACME state and node package
* the admin URL file permissions
* the unit file, enabled/active state and hardening directives
* expected listeners and the local HTTPS endpoint
* the served certificate and its expiry (or the configured certificate in `files` mode)
* Caddy configuration in `caddy` mode
* UFW rules
* NTP synchronization and DNS
* the root-owned update channel policy

It exits nonzero when a required check fails.

## Updates

### Panel

The panel can update itself from **Обновления** after checking GitHub; it installs only a release signed by its embedded release key and restarts through systemd. The root-owned policy `/etc/mistgate/panel-update-channel` fixes the channel (`stable`, `testing` or `dev`).

For a pinned or scripted update, use:

```bash
cd ~/ubuntu-scripts/mistgate
MISTGATE_UPGRADE_CONFIRMED=true bash update-mistgate.sh
```

The update script verifies the same signature, stops the panel, archives the data directory to `/var/lib/mistgate.panel-update-backup.tar.gz` (mode 0600, contains `master.key`), keeps the old binary as `/usr/local/bin/mistgate.prev`, starts the new one and rolls back automatically if it does not become healthy. A version change requires `MISTGATE_UPGRADE_CONFIRMED=true`; create and verify an off-host backup first.

To reinstall the same signed version:

```bash
MISTGATE_FORCE_UPDATE=true bash update-mistgate.sh
```

### Nodes

Nodes update from the panel: **Обновления → Обновить N нод**, one node, or a schedule. The panel sends a signed agent package; each agent verifies the signature with the key embedded in its own binary and rolls itself back if it does not reconnect and apply the configuration. A node installed from an unsigned custom build does not update itself.

### Operating System

The agent can enable automatic security updates from its doctor (`host enable-security-updates`). This module does not configure unattended upgrades.

## Backup and Restore

Everything the panel knows is in `MISTGATE_DATA_DIR` (`/var/lib/mistgate` by default):

| Path | Contents |
| --- | --- |
| `mistgate.db`, `-wal`, `-shm` | SQLite database; stored secrets are encrypted |
| `master.key` | 32 bytes; decrypts every stored secret and the panel CA |
| `acme/` | Let's Encrypt account and certificates |
| `dist/` | signed node package |

Stop the panel for a consistent copy:

```bash
systemctl stop mistgate
tar czf ~/mistgate-backup-$(date +%F).tgz -C /var/lib mistgate
systemctl start mistgate
chmod 600 ~/mistgate-backup-*.tgz
```

The archive contains `master.key`: anyone with it can read every secret. Store it encrypted and off the panel server.

Restore into a stopped panel by putting the directory back with owner `root`, mode `0700`, then start the service. For encrypted Cloudflare R2 backups, configure **Настройки → Бэкапы** in the panel and keep the age recovery key offline; restore with `mistgate backup restore --identity-file ... --file ... --data-dir ...`.

Losing `master.key` means re-enrolling every node and issuing every user a new subscription link. A new key is not a repair.

## Recovery

All commands work while the panel is running or stopped:

```bash
# Lost phone: new password and authenticator for a login
mistgate auth reset-login alice

# Admin exists only with a passkey: add password login
mistgate auth reset-login alice --admin <admin-id>

# Cloudflare Turnstile blocks everyone
mistgate auth turnstile off

# Lost the admin URL (settings are preserved)
mistgate setup --data-dir /var/lib/mistgate
```

## Logs and Diagnostics

```bash
systemctl status mistgate --no-pager
journalctl -u mistgate -f
journalctl -u mistgate -n 100 --no-pager

cd ~/ubuntu-scripts/mistgate
bash check-setup.sh
```

The panel logs to stderr, which journald collects. A wrong DNS record, a CDN in front of the panel, or a closed `443` is visible as a failed ACME challenge or as node connection errors in the panel events.

## Open Ports

The panel module opens, or expects to be reachable:

* `80/tcp` — ACME HTTP-01 and HTTP-to-HTTPS redirect (unless `MISTGATE_ACME_HTTP` is empty)
* `443/tcp` — decoy site, subscriptions, user pages, admin and the agent endpoint
* `8443/tcp` — only in `MISTGATE_TLS_MODE=caddy`, the dedicated agent TLS listener

UFW is never enabled by this module. It adds rules only when UFW is already active, and it does not change the hosting provider's firewall. Docker is not used, so Docker's NAT bypass does not apply.

Nodes open their own ports through their profiles and the installer:

* `80/tcp`, `443/tcp`, `443/udp` at install time
* each Hysteria2 UDP port and jump range, each VLESS TCP port and each AmneziaWG port as profiles are applied

## Known Conflicts

* **CDN or TLS-terminating proxy in front of the panel.** Not supported: agents pin the panel CA and Let's Encrypt validates on the server. Point DNS directly at the panel.
* **Caddy, Coolify, nginx, Apache, or another VPN panel on `80/443`.** Use a dedicated panel server, or `MISTGATE_TLS_MODE=caddy` with the agent port left alone.
* **Docker on a node.** Not required; a Docker `FORWARD` policy of `DROP` breaks AmneziaWG forwarding. Use a clean host.
* **A node on the panel host.** Hysteria2 and the panel compete for TCP 443. Keep them separate.
* **Changing the admin address or public URL later.** `mistgate setup` stores them once; changing them means a new data directory and re-enrolling every node.

## Uninstall

Retire every node in the panel first, then stop and remove the panel:

```bash
systemctl disable --now mistgate
rm -f /etc/systemd/system/mistgate.service
systemctl daemon-reload
rm -f /usr/local/bin/mistgate /usr/local/bin/mistgate.prev /usr/local/bin/mistgate.failed
```

Do **not** delete `/var/lib/mistgate` until you have an off-host backup: it holds the only panel CA and `master.key`. Delete `/etc/mistgate` only after saving the admin URL and channel policy. UFW rules added by this module remain until you delete them.
