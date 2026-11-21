# Ubuntu Module

The `ubuntu/` module prepares a fresh Ubuntu server. It is isolated from other modules and reads only `ubuntu/.env`. `MISTGATE_ROLE` only tunes this base module for Mistgate: it opens the right UFW ports and optionally prepares the SSH login the panel uses. It never installs Mistgate itself.

## Files

```text
ubuntu/
|-- env.example
|-- fix-ssh-password-auth.sh
|-- setup-ubuntu.sh
`-- check-setup.sh
```

## What It Does

`setup-ubuntu.sh`:

* sets the hostname
* changes the `root` password
* creates or updates a secondary user
* adds an SSH public key
* updates system packages
* installs `nano`, `fail2ban`, `ufw`, `less`, `curl`, `openssl`, and `gnupg`
* optionally enables or disables IPv6 through `DISABLE_IPV6`
* changes the SSH port
* disables SSH login for `root`
* enforces public-key SSH authentication and disables password and keyboard-interactive authentication
* opens `PORT_SSH/tcp` in UFW
* enables UFW and `fail2ban`
* with `MISTGATE_ROLE=panel` or `node`, also opens `80/tcp` and `443/tcp`
* with `MISTGATE_ROLE=node`, installs `nftables`, can add the panel public key to `USER_NAME` and optionally grant passwordless sudo for the panel's automatic node installer

`check-setup.sh` checks the Ubuntu setup, the effective SSH configuration reported by `sshd -T`, the SSH listener, UFW status, fail2ban status, and managed IPv6 state. It exits nonzero when a required check fails.

## Requirements

Before you begin, make sure you have:

* a server running **Ubuntu 24.04**
* root access to the server
* a valid SSH public key
* the ability to open `PORT_SSH/tcp` from the internet

## Prepare Env

From the repository root:

```bash
cd ubuntu
cp env.example .env
nano .env
```

Required variables:

```env
ROOT_PASSWORD=
USER_NAME=
USER_PASSWORD=
PORT_SSH=
SSH_PUB=
SERVER_NAME=
```

Optional variables:

```env
SERVER_IP_V4=
DISABLE_IPV6=
IPV6_INTERFACE=

# none | panel | node
MISTGATE_ROLE=none
MISTGATE_PANEL_SSH_PUB=
MISTGATE_PANEL_SSH_NOPASSWD=false
```

Leave `DISABLE_IPV6` empty to keep the current IPv6 state.
Set `DISABLE_IPV6=true` to disable IPv6.
Set `DISABLE_IPV6=false` to enable IPv6 and UFW IPv6 support.

`MISTGATE_ROLE` is explained in [Mistgate Profiles](#mistgate-profiles).

## Run

Connect as `root` first:

```bash
ssh root@YOUR_SERVER_IP
```

Install git and clone the repository:

```bash
apt update && apt install -y git
git clone https://github.com/jenesei-software/ubuntu-scripts.git ubuntu-scripts
cd ~/ubuntu-scripts/ubuntu
cp env.example .env
nano .env
bash setup-ubuntu.sh
```

After the script finishes, keep the current root session open and test a new SSH session:

```bash
ssh USER_NAME@YOUR_SERVER_IP -p PORT_SSH
```

Only close the root session after the new SSH login works.

## Mistgate Profiles

`MISTGATE_ROLE` changes only what this base module configures. It does not read `mistgate/.env` and does not install the panel or the node agent.

### `MISTGATE_ROLE=none`

Default. Only `PORT_SSH/tcp` is open. Nothing else changes.

### `MISTGATE_ROLE=panel`

For the server that will run the Mistgate panel:

* opens `80/tcp` and `443/tcp` in UFW;
* keeps root SSH disabled and password SSH disabled, because the panel setup runs locally through `sudo`;
* does not grant extra sudo.

After the base, install the panel from the `mistgate/` module. The panel detects the already-active UFW and adds its rules idempotently.

### `MISTGATE_ROLE=node`

For a server that will be a Mistgate node:

* opens `80/tcp` and `443/tcp` (the decoy HTTPS site and ACME; Hysteria2 UDP ports are added later by the agent);
* installs `nftables`;
* optionally adds the panel public key to `USER_NAME`'s `authorized_keys`:

```env
MISTGATE_PANEL_SSH_PUB=ssh-ed25519 AAAA... mistgate-panel
```

Copy it from **Nodes → Add node → Ключ панели** in the panel.

Because this module disables root SSH and password SSH, the panel's automatic SSH installer needs a non-root login with passwordless sudo. That is a separate, explicit switch:

```env
MISTGATE_PANEL_SSH_NOPASSWD=true
```

It writes `/etc/sudoers.d/90-mistgate-panel` with `USER_NAME ALL=(ALL) NOPASSWD:ALL`, validated by `visudo`. It requires `MISTGATE_PANEL_SSH_PUB`; without the key the panel still cannot log in. This is a broad privilege grant, not the minimum the agent needs. Leave it `false` and use the panel's manual one-time install command if you do not want the panel to have passwordless root on the node.

In the panel wizard use:

* SSH port: `PORT_SSH`
* login: `USER_NAME`
* method: **Ключ панели**

If `MISTGATE_PANEL_SSH_NOPASSWD=false`, choose the manual install path instead. The base has already opened `80/443`, so the panel's manual command only needs `nftables`:

```bash
sudo apt-get install -y nftables
```

Then add the node in the panel and run the one-time `enroll`/`install` command it prints.

The node profile never opens `443/udp` directly: the panel's installer or the agent opens the exact profile ports and can remove its own rules later.

## Existing Servers: Disable SSH Password Login

An older version of this module might not have disabled SSH password login because its configuration file had the wrong priority. Update the repository and run the repair script; it reads `PORT_SSH`, `USER_NAME`, and `SSH_PUB` from `ubuntu/.env` automatically:

```bash
cd ~/ubuntu-scripts
git pull --ff-only
sudo bash ubuntu/fix-ssh-password-auth.sh
```

Keep the current session open. After the script prints `OK`, confirm a new key-based SSH login before closing the original session.

## Verify

From the repository root:

```bash
cd ~/ubuntu-scripts/ubuntu
bash check-setup.sh
```

## Open Ports

This module opens only:

* `PORT_SSH/tcp`

It does not open Caddy ports. Run the Caddy module separately if you need `80/tcp` and `443/tcp`.

`MISTGATE_ROLE=panel` or `node` additionally opens:

* `80/tcp`
* `443/tcp`

`MISTGATE_ROLE=node` does not open `443/udp`: the panel installer or the agent opens the exact profile ports later.

## Important Notes

* Run this module carefully on a fresh server.
* Check `SSH_PUB` before running the script.
* Password-based SSH login is disabled, so a wrong SSH key can lock you out.
* Keep the root session open until the new SSH session is confirmed.
* Intended target: Ubuntu 24.04.

## Upstream References

* [Ubuntu Server: OpenSSH server](https://documentation.ubuntu.com/server/how-to/security/openssh-server/)
* [OpenSSH `sshd_config(5)`](https://man.openbsd.org/sshd_config)
