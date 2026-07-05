#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
IPV6_DISABLE_SYSCTL_FILE="/etc/sysctl.d/99-ubuntu-setup-disable-ipv6.conf"
IPV6_ENABLE_SYSCTL_FILE="/etc/sysctl.d/99-ubuntu-setup-enable-ipv6.conf"
UFW_DEFAULTS_FILE="/etc/default/ufw"

LOG_COLOR='\033[1;36m'
LOG_RESET='\033[0m'

timestamp() { date '+%F %T'; }
log_line() {
  local level="$1"
  shift
  printf '%b[%s] %-7s%b %s\n' "$LOG_COLOR" "$(timestamp)" "$level" "$LOG_RESET" "$*"
}

log() { log_line "INFO" "$*"; }
fail() { log_line "ERROR" "$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/ubuntu && bash setup-ubuntu.sh"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"; }

resolve_env_path() {
  local candidate="$1"
  local candidate_dir
  local candidate_base

  if [[ "$candidate" = /* ]]; then
    printf '%s\n' "$candidate"
  elif [[ -f "$candidate" ]]; then
    candidate_dir="$(cd -- "$(dirname -- "$candidate")" && pwd)"
    candidate_base="$(basename -- "$candidate")"
    printf '%s/%s\n' "$candidate_dir" "$candidate_base"
  elif [[ -f "$SCRIPT_DIR/$candidate" ]]; then
    candidate_dir="$(cd -- "$(dirname -- "$SCRIPT_DIR/$candidate")" && pwd)"
    candidate_base="$(basename -- "$candidate")"
    printf '%s/%s\n' "$candidate_dir" "$candidate_base"
  else
    printf '%s/%s\n' "$SCRIPT_DIR" "$candidate"
  fi
}

resolve_env_file() {
  if [[ -n "$ENV_FILE_INPUT" ]]; then
    ENV_FILE="$(resolve_env_path "$ENV_FILE_INPUT")"
    return
  fi

  if [[ -f "$SCRIPT_DIR/.env" ]]; then
    ENV_FILE="$SCRIPT_DIR/.env"
    return
  fi

  fail "Environment file not found. Copy ubuntu/env.example to ubuntu/.env or run: cd ubuntu && cp env.example .env"
}

reset_env_vars() {
  ROOT_PASSWORD=""
  USER_NAME=""
  USER_PASSWORD=""
  PORT_SSH=""
  SSH_PUB=""
  SERVER_IP_V4=""
  SERVER_NAME=""
  DISABLE_IPV6=""
  IPV6_INTERFACE=""
}

load_env() {
  resolve_env_file
  [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
  log "Loading environment from $ENV_FILE"
  reset_env_vars
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

require_vars() {
  local missing=()
  for var in ROOT_PASSWORD USER_NAME USER_PASSWORD PORT_SSH SSH_PUB SERVER_NAME; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  if (( ${#missing[@]} > 0 )); then
    fail "Missing required variables in $ENV_FILE: ${missing[*]}"
  fi
}

validate_port() {
  [[ "$PORT_SSH" =~ ^[0-9]+$ ]] || fail "PORT_SSH must be numeric"
  (( PORT_SSH >= 10001 && PORT_SSH <= 65535 )) || fail "PORT_SSH must be between 10001 and 65535"
}

validate_bool() {
  local value="$1"
  [[ "$value" == "true" || "$value" == "false" ]] || fail "Boolean value must be true or false"
}

ensure_ufw_ipv6_enabled() {
  if [[ ! -f "$UFW_DEFAULTS_FILE" ]]; then
    log "UFW defaults file not found, skipping UFW IPv6 setting"
    return
  fi

  if grep -qE '^IPV6=' "$UFW_DEFAULTS_FILE"; then
    sed -i -E 's/^IPV6=.*/IPV6=yes/' "$UFW_DEFAULTS_FILE"
  else
    printf '\nIPV6=yes\n' >> "$UFW_DEFAULTS_FILE"
  fi
}

resolve_ipv6_interface() {
  if [[ -n "${IPV6_INTERFACE:-}" ]]; then
    printf '%s\n' "$IPV6_INTERFACE"
    return
  fi

  local iface
  iface="$(ip -o -6 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | sed -n '1p' || true)"
  if [[ -z "$iface" ]]; then
    iface="$(ip -o -4 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | sed -n '1p' || true)"
  fi
  if [[ -z "$iface" && -d /sys/class/net/eth0 ]]; then
    iface="eth0"
  fi

  [[ -n "$iface" ]] || fail "Could not detect network interface for IPv6. Set IPV6_INTERFACE in .env."
  printf '%s\n' "$iface"
}

ipv6_enable_settings() {
  local iface="$1"
  printf '%s\n' \
    "net.ipv6.conf.all.disable_ipv6=0" \
    "net.ipv6.conf.default.disable_ipv6=0" \
    "net.ipv6.conf.lo.disable_ipv6=0" \
    "net.ipv6.conf.${iface}.disable_ipv6=0" \
    "net.ipv6.conf.${iface}.accept_ra=2" \
    "net.ipv6.conf.all.forwarding=1" \
    "net.ipv6.conf.all.addr_gen_mode=0" \
    "net.ipv6.conf.${iface}.use_tempaddr=0"
}

apply_ipv6_enable_settings() {
  local iface="$1"
  local setting expected pair

  while IFS= read -r pair; do
    setting="${pair%%=*}"
    expected="${pair#*=}"
    sysctl -w "$setting=$expected" >/dev/null || fail "Failed to set $setting=$expected"
  done < <(ipv6_enable_settings "$iface")
}

ipv6_disable_settings() {
  printf '%s\n' \
    "net.ipv6.conf.all.disable_ipv6=1" \
    "net.ipv6.conf.default.disable_ipv6=1" \
    "net.ipv6.conf.lo.disable_ipv6=1"
}

apply_ipv6_disable_settings() {
  local setting expected pair

  while IFS= read -r pair; do
    setting="${pair%%=*}"
    expected="${pair#*=}"
    sysctl -w "$setting=$expected" >/dev/null || fail "Failed to set $setting=$expected"
  done < <(ipv6_disable_settings)
}

verify_ipv6_disable_settings() {
  local setting expected pair value

  while IFS= read -r pair; do
    setting="${pair%%=*}"
    expected="${pair#*=}"
    value="$(sysctl -n "$setting" 2>/dev/null || echo unknown)"
    [[ "$value" == "$expected" ]] || fail "Failed to verify $setting=$expected, current value is $value"
  done < <(ipv6_disable_settings)
}

verify_ipv6_enable_settings() {
  local iface="$1"
  local setting expected pair value

  while IFS= read -r pair; do
    setting="${pair%%=*}"
    expected="${pair#*=}"
    value="$(sysctl -n "$setting" 2>/dev/null || echo unknown)"
    [[ "$value" == "$expected" ]] || fail "Failed to verify $setting=$expected, current value is $value"
  done < <(ipv6_enable_settings "$iface")
}

disable_ipv6() {
  log "Disabling IPv6 on the host because DISABLE_IPV6=true"
  if [[ ! -d /proc/sys/net/ipv6 ]]; then
    log "IPv6 kernel support is not active, nothing to disable"
    return
  fi

  rm -f "$IPV6_ENABLE_SYSCTL_FILE"
  cat > "$IPV6_DISABLE_SYSCTL_FILE" <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

  sysctl --system >/dev/null || true
  apply_ipv6_disable_settings
  verify_ipv6_disable_settings

  log "IPv6 has been disabled"
}

restart_network_for_ipv6() {
  local restarted=false

  if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    log "Restarting systemd-networkd to apply IPv6 settings"
    systemctl restart systemd-networkd || log "Could not restart systemd-networkd"
    restarted=true
  fi

  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    log "Restarting NetworkManager to apply IPv6 settings"
    systemctl restart NetworkManager || log "Could not restart NetworkManager"
    restarted=true
  fi

  if [[ "$restarted" == "false" ]]; then
    log "No supported network service is active, skipping network restart"
  fi
}

enable_ipv6() {
  local iface

  log "Enabling IPv6 on the host because DISABLE_IPV6=false"
  iface="$(resolve_ipv6_interface)"
  log "Using IPv6 network interface: $iface"

  rm -f "$IPV6_DISABLE_SYSCTL_FILE"
  cat > "$IPV6_ENABLE_SYSCTL_FILE" <<EOF
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.${iface}.disable_ipv6 = 0
net.ipv6.conf.${iface}.accept_ra = 2
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.all.addr_gen_mode = 0
net.ipv6.conf.${iface}.use_tempaddr = 0
EOF

  ensure_ufw_ipv6_enabled
  sysctl --system >/dev/null || true

  apply_ipv6_enable_settings "$iface"
  restart_network_for_ipv6
  apply_ipv6_enable_settings "$iface"
  verify_ipv6_enable_settings "$iface"

  [[ -f /proc/net/if_inet6 ]] || fail "IPv6 kernel support is not active. Check kernel boot parameters such as ipv6.disable=1"

  log "IPv6 has been enabled"
}

check_ipv6_status() {
  local ipv6_all ipv6_default

  ipv6_all="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo unknown)"
  ipv6_default="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo unknown)"

  if [[ "$DISABLE_IPV6" == "true" ]]; then
    if [[ "$ipv6_all" == "1" && "$ipv6_default" == "1" ]]; then
      log "IPv6 is already disabled on this server"
    else
      log "IPv6 is currently enabled and will be disabled because DISABLE_IPV6=true in .env"
    fi
  else
    if [[ "$ipv6_all" == "1" && "$ipv6_default" == "1" ]]; then
      log "IPv6 is disabled on this server and will be enabled because DISABLE_IPV6=false in .env"
    else
      log "IPv6 is enabled and will be kept enabled because DISABLE_IPV6=false in .env"
    fi
  fi
}

create_or_update_user() {
  if id "$USER_NAME" >/dev/null 2>&1; then
    log "User already exists: $USER_NAME"
  else
    log "Creating user: $USER_NAME"
    adduser --disabled-password --gecos "" "$USER_NAME"
  fi

  echo "$USER_NAME:$USER_PASSWORD" | chpasswd
  usermod -aG sudo "$USER_NAME"
}

setup_ssh_key() {
  local ssh_dir="/home/$USER_NAME/.ssh"
  local auth_keys="$ssh_dir/authorized_keys"

  mkdir -p "$ssh_dir"
  touch "$auth_keys"
  chmod 700 "$ssh_dir"
  chmod 600 "$auth_keys"
  chown -R "$USER_NAME:$USER_NAME" "$ssh_dir"

  if ! grep -Fqx "$SSH_PUB" "$auth_keys"; then
    log "Adding SSH public key for $USER_NAME"
    printf '%s\n' "$SSH_PUB" >> "$auth_keys"
  else
    log "SSH public key is already present"
  fi
}

configure_ssh() {
  local sshd_config="/etc/ssh/sshd_config"
  local sshd_dropin_dir="/etc/ssh/sshd_config.d"
  local sshd_dropin_file="$sshd_dropin_dir/99-ubuntu-setup.conf"

  cp "$sshd_config" "${sshd_config}.bak.$(date +%s)"

  sed -i -E "s/^#?Port .*/Port $PORT_SSH/" "$sshd_config"
  sed -i -E "s/^#?PermitRootLogin .*/PermitRootLogin no/" "$sshd_config"

  if grep -qE '^#?PasswordAuthentication ' "$sshd_config"; then
    sed -i -E 's/^#?PasswordAuthentication .*/PasswordAuthentication no/' "$sshd_config"
  else
    printf '\nPasswordAuthentication no\n' >> "$sshd_config"
  fi

  if grep -qE '^#?PermitEmptyPasswords ' "$sshd_config"; then
    sed -i -E 's/^#?PermitEmptyPasswords .*/PermitEmptyPasswords no/' "$sshd_config"
  else
    printf 'PermitEmptyPasswords no\n' >> "$sshd_config"
  fi

  install -d -m 0755 "$sshd_dropin_dir"
  cat > "$sshd_dropin_file" <<EOF
Port $PORT_SSH
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
EOF

  install -d -m 0755 /run/sshd
  sshd -t

  if systemctl list-unit-files --type=socket | grep -q '^ssh.socket'; then
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/ssh.socket.d/override.conf || true
    systemctl daemon-reload
  fi

  systemctl enable ssh >/dev/null 2>&1 || true
  systemctl restart sshd 2>/dev/null || systemctl restart ssh

  if ss -tln "( sport = :$PORT_SSH )" | grep -q LISTEN; then
    log "SSHD is listening on the new port: $PORT_SSH"
  else
    fail "SSHD is not listening on port $PORT_SSH after restart"
  fi
}

install_packages() {
  log "Updating the system and installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a
  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    upgrade
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install nano fail2ban ufw less ca-certificates curl openssl gnupg
}

configure_hostname() {
  log "Setting hostname: $SERVER_NAME"
  hostnamectl set-hostname "$SERVER_NAME"
}

configure_root_password() {
  log "Updating root password"
  echo "root:$ROOT_PASSWORD" | chpasswd
}

configure_ufw() {
  log "Configuring UFW"
  ufw allow "$PORT_SSH/tcp"
  ufw --force enable
  ufw reload
}

ensure_fail2ban() {
  systemctl enable fail2ban
  systemctl restart fail2ban
}

main() {
  require_root
  require_cmd sed
  require_cmd grep
  require_cmd ss
  load_env
  require_vars
  validate_port

  if [[ -n "${DISABLE_IPV6:-}" ]]; then
    require_cmd sysctl
    validate_bool "$DISABLE_IPV6"
    check_ipv6_status
  fi

  configure_hostname
  configure_root_password
  create_or_update_user
  setup_ssh_key
  install_packages
  if [[ "${DISABLE_IPV6:-}" == "true" ]]; then
    disable_ipv6
  elif [[ "${DISABLE_IPV6:-}" == "false" ]]; then
    enable_ipv6
  fi
  configure_ufw
  configure_ssh
  ensure_fail2ban

  local connect_host="${SERVER_IP_V4:-<SERVER_IP>}"
  log "Done. Test the new SSH login with: ssh $USER_NAME@$connect_host -p $PORT_SSH"
  log "Keep the current root session open until the new SSH session works in a separate terminal"
}

main "$@"
