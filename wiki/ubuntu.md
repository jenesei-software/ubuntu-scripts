# Ubuntu Module

The `ubuntu/` module prepares a fresh Ubuntu server. It is isolated from other modules and reads only `ubuntu/.env` by default.

## Files

```text
ubuntu/
|-- env.example
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
```

Leave `DISABLE_IPV6` empty to keep the current IPv6 state.
Set `DISABLE_IPV6=true` to disable IPv6.
Set `DISABLE_IPV6=false` to enable IPv6 and UFW IPv6 support.

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

## Existing Servers: Disable SSH Password Login

An older version of this module might not have disabled SSH password login because its configuration file had the wrong priority. Keep the current SSH session open and confirm key-only login from a second terminal before continuing:

```bash
ssh -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
  -o PreferredAuthentications=publickey USER_NAME@YOUR_SERVER_IP -p PORT_SSH
```

If key-only login works, paste this entire block into the existing server session:

```bash
sudo env SSH_HARDENING_PORT="${SSH_CONNECTION##* }" bash <<'EOF'
set -Eeuo pipefail

[[ "$SSH_HARDENING_PORT" =~ ^[0-9]+$ ]] || {
  echo "ERROR: could not detect the current SSH port"
  exit 1
}

config_dir=/etc/ssh/sshd_config.d
managed_file="$config_dir/00-ubuntu-setup.conf"
legacy_file="$config_dir/99-ubuntu-setup.conf"
backup_dir="/root/ssh-config-backup-$(date +%Y%m%d%H%M%S)"

install -d -m 0755 "$config_dir"
install -d -m 0700 "$backup_dir"
cp -a /etc/ssh/sshd_config "$backup_dir/"
cp -a "$config_dir" "$backup_dir/"

rollback() {
  rm -f "$managed_file" "$legacy_file"

  if [[ -f "$backup_dir/sshd_config.d/00-ubuntu-setup.conf" ]]; then
    cp -a "$backup_dir/sshd_config.d/00-ubuntu-setup.conf" "$managed_file"
  fi

  if [[ -f "$backup_dir/sshd_config.d/99-ubuntu-setup.conf" ]]; then
    cp -a "$backup_dir/sshd_config.d/99-ubuntu-setup.conf" "$legacy_file"
  fi
}

temp_file="$(mktemp "$config_dir/.00-ubuntu-setup.conf.XXXXXX")"
printf '%s\n' \
  "Port $SSH_HARDENING_PORT" \
  "PermitRootLogin no" \
  "PubkeyAuthentication yes" \
  "PasswordAuthentication no" \
  "KbdInteractiveAuthentication no" \
  "PermitEmptyPasswords no" > "$temp_file"

chmod 0644 "$temp_file"
mv -f "$temp_file" "$managed_file"

if ! sshd -t; then
  echo "ERROR: invalid SSH configuration; rolling back"
  rollback
  exit 1
fi

effective_config="$(sshd -T)"
required_settings=(
  "port $SSH_HARDENING_PORT"
  "permitrootlogin no"
  "pubkeyauthentication yes"
  "passwordauthentication no"
  "kbdinteractiveauthentication no"
  "permitemptypasswords no"
)

for setting in "${required_settings[@]}"; do
  if ! grep -Fqx "$setting" <<< "$effective_config"; then
    echo "ERROR: effective setting not applied: $setting"
    rollback
    exit 1
  fi
done

rm -f "$legacy_file"
systemctl daemon-reload

if ! systemctl restart ssh.service; then
  echo "ERROR: SSH restart failed; rolling back"
  rollback
  systemctl daemon-reload
  systemctl restart ssh.service || true
  exit 1
fi

echo "OK: SSH password login is disabled"
echo "Backup: $backup_dir"
EOF
```

After it prints `OK`, open one more key-only session. Do not close the original session until the new login succeeds.

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

## Important Notes

* Run this module carefully on a fresh server.
* Check `SSH_PUB` before running the script.
* Password-based SSH login is disabled, so a wrong SSH key can lock you out.
* Keep the root session open until the new SSH session is confirmed.
* Intended target: Ubuntu 24.04.

## Upstream References

* [Ubuntu Server: OpenSSH server](https://documentation.ubuntu.com/server/how-to/security/openssh-server/)
* [OpenSSH `sshd_config(5)`](https://man.openbsd.org/sshd_config)
