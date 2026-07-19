#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
ENV_FILE="${ENV_FILE:-}"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_SOURCE_LIST="/etc/apt/sources.list.d/docker.list"
IPV6_DISABLE_SYSCTL_FILE="/etc/sysctl.d/99-remnawave-node-disable-ipv6.conf"
IPV6_ENABLE_SYSCTL_FILE="/etc/sysctl.d/99-remnawave-node-enable-ipv6.conf"
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
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/remnawave-node && bash setup-remnawave-node.sh"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"; }

on_error() {
  local exit_code=$?
  local line_no="${BASH_LINENO[0]:-${LINENO}}"
  local command="${BASH_COMMAND:-unknown}"
  log_line "ERROR" "Setup failed at line $line_no: $command (exit $exit_code)" >&2
}
trap on_error ERR

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
    candidate_base="$(basename -- "$SCRIPT_DIR/$candidate")"
    printf '%s/%s\n' "$candidate_dir" "$candidate_base"
  else
    printf '%s/%s\n' "$SCRIPT_DIR" "$candidate"
  fi
}

resolve_env_file() {
  if [[ -n "$ENV_FILE" ]]; then
    ENV_FILE="$(resolve_env_path "$ENV_FILE")"
    return
  fi
  if [[ -n "$ENV_FILE_INPUT" ]]; then
    ENV_FILE="$(resolve_env_path "$ENV_FILE_INPUT")"
    return
  fi
  if [[ -f "$SCRIPT_DIR/.env" ]]; then
    ENV_FILE="$SCRIPT_DIR/.env"
    return
  fi

  fail "Environment file not found. Copy remnawave-node/env.example to remnawave-node/.env or run: cd remnawave-node && cp env.example .env"
}

set_paths() {
  REMNAWAVE_NODE_INSTALL_DIR="${REMNAWAVE_NODE_INSTALL_DIR:-/opt/remnanode}"
  REMNAWAVE_NODE_CERT_DIR="${REMNAWAVE_NODE_CERT_DIR:-/etc/ssl/remnawave-node}"
  COMPOSE_DIR="$REMNAWAVE_NODE_INSTALL_DIR"
  CERT_DIR="$REMNAWAVE_NODE_CERT_DIR"
  COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
}

strip_protocol() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  printf '%s\n' "$value"
}

load_env() {
  resolve_env_file
  [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
  log "Loading environment from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  set_paths
  SERVER_DOMAIN="$(strip_protocol "${SERVER_DOMAIN:-}")"
  DOMAIN_MAIL="${DOMAIN_MAIL:-}"
  PORT_NODE="${PORT_NODE:-22222}"
  PANEL_IP="${PANEL_IP:-}"
  NODE_SECRET="${NODE_SECRET:-}"
  REMNAWAVE_NODE_IMAGE="${REMNAWAVE_NODE_IMAGE:-remnawave/node:latest}"
  DISABLE_IPV6="${DISABLE_IPV6:-true}"
  IPV6_INTERFACE="${IPV6_INTERFACE:-}"
  PORT_ARRAY_INBOUNDS="${PORT_ARRAY_INBOUNDS:-}"
  REMNAWAVE_NODE_SYSTEM_USER="${REMNAWAVE_NODE_SYSTEM_USER:-}"
  REMNAWAVE_NODE_SYSTEM_PASSWORD="${REMNAWAVE_NODE_SYSTEM_PASSWORD:-}"
  REMNAWAVE_NODE_SYSTEM_SSH_PUB="${REMNAWAVE_NODE_SYSTEM_SSH_PUB:-}"
}

require_vars() {
  local missing=()
  for var in PORT_NODE PANEL_IP NODE_SECRET; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  if [[ -n "$SERVER_DOMAIN" && -z "$DOMAIN_MAIL" ]]; then
    missing+=("DOMAIN_MAIL")
  fi
  if (( ${#missing[@]} > 0 )); then
    fail "Missing required variables in $ENV_FILE: ${missing[*]}"
  fi
}

validate_port_value() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be numeric"
  (( value >= 1 && value <= 65535 )) || fail "$name must be between 1 and 65535"
}

validate_bool() {
  local name="$1"
  local value="$2"
  [[ "$value" == "true" || "$value" == "false" ]] || fail "$name must be true or false"
}

validate_ipv4() {
  local name="$1"
  local value="$2"
  local octet
  local -a octets

  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "$name must be a single IPv4 address"
  IFS='.' read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || fail "$name must be a valid IPv4 address"
  done
}

reject_placeholder() {
  local name="$1"
  local value="$2"
  case "$value" in
    change_me*|changeme*|please_change*)
      fail "$name still contains a placeholder value. Change it in $ENV_FILE before running setup."
      ;;
  esac
}

validate_port_array() {
  local raw_rule rule port protocol
  [[ -z "$PORT_ARRAY_INBOUNDS" ]] && return

  IFS=',' read -r -a rules <<< "$PORT_ARRAY_INBOUNDS"
  for raw_rule in "${rules[@]}"; do
    rule="$(echo "$raw_rule" | xargs)"
    [[ -z "$rule" ]] && continue
    if [[ "$rule" == */* ]]; then
      port="${rule%/*}"
      protocol="${rule##*/}"
    else
      port="$rule"
      protocol="tcp"
    fi
    validate_port_value PORT_ARRAY_INBOUNDS "$port"
    [[ "$protocol" == "tcp" || "$protocol" == "udp" || "$protocol" == "both" ]] \
      || fail "PORT_ARRAY_INBOUNDS protocol must be tcp, udp, or both: $rule"
  done
}

validate_system_user_env() {
  [[ -z "$REMNAWAVE_NODE_SYSTEM_USER" ]] && return
  [[ "$REMNAWAVE_NODE_SYSTEM_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail "REMNAWAVE_NODE_SYSTEM_USER must be a valid Linux user name"
  [[ "$REMNAWAVE_NODE_SYSTEM_USER" != "root" ]] || fail "REMNAWAVE_NODE_SYSTEM_USER must not be root"
  [[ "$REMNAWAVE_NODE_SYSTEM_PASSWORD" != *:* ]] || fail "REMNAWAVE_NODE_SYSTEM_PASSWORD must not contain a colon"
  [[ "$REMNAWAVE_NODE_SYSTEM_PASSWORD" != *$'\n'* ]] || fail "REMNAWAVE_NODE_SYSTEM_PASSWORD must not contain a newline"
}

validate_env() {
  [[ -z "$SERVER_DOMAIN" || "$SERVER_DOMAIN" =~ ^[^/]+$ ]] || fail "SERVER_DOMAIN must be a domain without path"
  validate_port_value PORT_NODE "$PORT_NODE"
  validate_ipv4 PANEL_IP "$PANEL_IP"
  validate_bool DISABLE_IPV6 "$DISABLE_IPV6"
  reject_placeholder NODE_SECRET "$NODE_SECRET"
  validate_port_array
  validate_system_user_env
}

service_user_enabled() {
  [[ -n "${REMNAWAVE_NODE_SYSTEM_USER:-}" ]]
}

service_user_home() {
  local home
  home="$(getent passwd "$REMNAWAVE_NODE_SYSTEM_USER" | cut -d: -f6)"
  [[ -n "$home" ]] || home="/home/$REMNAWAVE_NODE_SYSTEM_USER"
  printf '%s\n' "$home"
}

run_as_service_user() {
  if service_user_enabled; then
    runuser -u "$REMNAWAVE_NODE_SYSTEM_USER" -- env HOME="$(service_user_home)" "$@"
  else
    "$@"
  fi
}

run_in_node_dir() {
  if service_user_enabled; then
    runuser -u "$REMNAWAVE_NODE_SYSTEM_USER" -- env HOME="$(service_user_home)" bash -c 'cd "$1" && shift && "$@"' _ "$COMPOSE_DIR" "$@"
  else
    (cd "$COMPOSE_DIR" && "$@")
  fi
}

install_base_packages() {
  log "Installing base packages required for Remnawave Node"
  export DEBIAN_FRONTEND=noninteractive
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a

  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install ca-certificates curl gnupg iproute2 openssl socat ufw
}

ensure_docker_running() {
  local attempt

  require_cmd systemctl

  log "Ensuring Docker service is enabled and running"
  if ! systemctl enable docker; then
    log "Could not enable Docker service for boot; continuing with runtime readiness check"
  fi

  if ! systemctl start docker; then
    systemctl status docker --no-pager || true
    fail "Failed to start Docker service"
  fi

  for attempt in {1..30}; do
    if docker info >/dev/null 2>&1; then
      log "Docker daemon is ready"
      return
    fi
    sleep 1
  done

  systemctl status docker --no-pager || true
  fail "Docker daemon did not become ready after service start"
}

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker and Docker Compose are already installed"
    ensure_docker_running
    return
  fi

  log "Installing Docker Engine and Docker Compose plugin"
  export DEBIAN_FRONTEND=noninteractive
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a

  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install ca-certificates curl gnupg

  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" \
    | gpg --batch --yes --dearmor -o "$DOCKER_KEYRING"
  chmod 0644 "$DOCKER_KEYRING"

  # shellcheck disable=SC1091
  source /etc/os-release
  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/ubuntu %s stable\n' "$(dpkg --print-architecture)" "$DOCKER_KEYRING" "$VERSION_CODENAME" \
    > "$DOCKER_SOURCE_LIST"
  chmod 0644 "$DOCKER_SOURCE_LIST"

  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  ensure_docker_running
  docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is not available after installation"
}

create_or_update_service_user() {
  service_user_enabled || return 0
  require_cmd runuser

  local ssh_dir auth_keys

  if id "$REMNAWAVE_NODE_SYSTEM_USER" >/dev/null 2>&1; then
    log "Service user already exists: $REMNAWAVE_NODE_SYSTEM_USER"
  else
    log "Creating service user: $REMNAWAVE_NODE_SYSTEM_USER"
    adduser --disabled-password --gecos "" "$REMNAWAVE_NODE_SYSTEM_USER"
  fi

  if [[ -n "$REMNAWAVE_NODE_SYSTEM_PASSWORD" ]]; then
    log "Updating password for service user: $REMNAWAVE_NODE_SYSTEM_USER"
    printf '%s:%s\n' "$REMNAWAVE_NODE_SYSTEM_USER" "$REMNAWAVE_NODE_SYSTEM_PASSWORD" | chpasswd
  fi

  getent group docker >/dev/null 2>&1 || groupadd docker
  usermod -aG docker "$REMNAWAVE_NODE_SYSTEM_USER"

  if [[ -n "${REMNAWAVE_NODE_SYSTEM_SSH_PUB:-}" ]]; then
    ssh_dir="$(service_user_home)/.ssh"
    auth_keys="$ssh_dir/authorized_keys"

    install -d -m 0700 "$ssh_dir"
    chown "$REMNAWAVE_NODE_SYSTEM_USER:" "$ssh_dir"
    touch "$auth_keys"
    chmod 0600 "$auth_keys"
    chown "$REMNAWAVE_NODE_SYSTEM_USER:" "$auth_keys"

    if ! grep -Fqx "$REMNAWAVE_NODE_SYSTEM_SSH_PUB" "$auth_keys"; then
      log "Adding SSH public key for $REMNAWAVE_NODE_SYSTEM_USER"
      printf '%s\n' "$REMNAWAVE_NODE_SYSTEM_SSH_PUB" >> "$auth_keys"
      chown "$REMNAWAVE_NODE_SYSTEM_USER:" "$auth_keys"
    else
      log "SSH public key is already present for $REMNAWAVE_NODE_SYSTEM_USER"
    fi
  fi

  if ! run_as_service_user docker info >/dev/null 2>&1; then
    fail "Service user $REMNAWAVE_NODE_SYSTEM_USER cannot access Docker. Check docker group membership and Docker socket permissions."
  fi
}

disable_ipv6() {
  log "Disabling IPv6 on the host"
  rm -f "$IPV6_ENABLE_SYSCTL_FILE"
  cat > "$IPV6_DISABLE_SYSCTL_FILE" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

  sysctl --system >/dev/null

  [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" == "1" ]] || fail "Failed to disable IPv6 for net.ipv6.conf.all.disable_ipv6"
  [[ "$(sysctl -n net.ipv6.conf.default.disable_ipv6)" == "1" ]] || fail "Failed to disable IPv6 for net.ipv6.conf.default.disable_ipv6"
  [[ "$(sysctl -n net.ipv6.conf.lo.disable_ipv6)" == "1" ]] || fail "Failed to disable IPv6 for net.ipv6.conf.lo.disable_ipv6"

  log "IPv6 has been disabled"
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

  log "Enabling IPv6 on the host"
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

configure_ufw() {
  local raw_rule rule port protocol

  log "Opening Remnawave Node ports in UFW"
  ufw --force delete allow "$PORT_NODE/tcp" >/dev/null 2>&1 || true
  ufw allow from "$PANEL_IP" to any port "$PORT_NODE" proto tcp

  if [[ -n "$SERVER_DOMAIN" ]]; then
    ufw allow "80/tcp"
    ufw allow "443/tcp"
  fi

  if [[ -n "$PORT_ARRAY_INBOUNDS" ]]; then
    IFS=',' read -r -a rules <<< "$PORT_ARRAY_INBOUNDS"
    for raw_rule in "${rules[@]}"; do
      rule="$(echo "$raw_rule" | xargs)"
      [[ -z "$rule" ]] && continue
      if [[ "$rule" == */* ]]; then
        port="${rule%/*}"
        protocol="${rule##*/}"
      else
        port="$rule"
        protocol="tcp"
      fi
      if [[ "$protocol" == "both" ]]; then
        ufw allow "$port/tcp"
        ufw allow "$port/udp"
      else
        ufw allow "$port/$protocol"
      fi
    done
  fi

  ufw reload || true
}

install_acme_if_missing() {
  export HOME="/root"
  export PATH="$HOME/.acme.sh:$PATH"

  if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
    log "acme.sh is already installed"
    return
  fi

  log "Installing acme.sh"
  curl https://get.acme.sh | sh -s email="$DOMAIN_MAIL"
}

issue_certificate() {
  export HOME="/root"
  export PATH="$HOME/.acme.sh:$PATH"

  install -d -m 0755 "$CERT_DIR"

  if [[ -s "$CERT_DIR/cert.pem" && -s "$CERT_DIR/key.pem" ]]; then
    log "Existing Remnawave Node TLS certificate files were found in $CERT_DIR"
    return
  fi

  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt
  "$HOME/.acme.sh/acme.sh" --register-account -m "$DOMAIN_MAIL" || true

  log "Issuing a certificate for $SERVER_DOMAIN with acme.sh standalone mode"
  "$HOME/.acme.sh/acme.sh" --issue -d "$SERVER_DOMAIN" --standalone
  "$HOME/.acme.sh/acme.sh" --install-cert -d "$SERVER_DOMAIN" \
    --key-file "$CERT_DIR/key.pem" \
    --fullchain-file "$CERT_DIR/cert.pem"
}

ensure_certificate() {
  if [[ -n "$SERVER_DOMAIN" ]]; then
    install_acme_if_missing
    issue_certificate
  else
    log "SERVER_DOMAIN is not set; skipping TLS certificate issuance"
  fi
}

chown_node_dir_if_needed() {
  service_user_enabled || return 0
  [[ -d "$COMPOSE_DIR" ]] || return 0
  chown -R "$REMNAWAVE_NODE_SYSTEM_USER:" "$COMPOSE_DIR"
}

write_compose() {
  install -d -m 0755 "$COMPOSE_DIR"
  log "Writing Remnawave Node Docker Compose file: $COMPOSE_FILE"

  cat > "$COMPOSE_FILE" <<YAML
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ${REMNAWAVE_NODE_IMAGE}
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      NODE_PORT: "${PORT_NODE}"
      SECRET_KEY: "${NODE_SECRET}"
YAML

  if [[ -n "$SERVER_DOMAIN" ]]; then
    cat >> "$COMPOSE_FILE" <<YAML
      SSL_CERT: /etc/ssl/remnawave-node/cert.pem
      SSL_KEY: /etc/ssl/remnawave-node/key.pem
    volumes:
      - ${CERT_DIR}:/etc/ssl/remnawave-node:ro
YAML
  fi

  chown_node_dir_if_needed
}

validate_compose() {
  log "Validating Remnawave Node Docker Compose config"
  run_in_node_dir docker compose config >/dev/null
}

wait_for_container() {
  local container="$1"
  local timeout="${2:-120}"
  local elapsed=0
  local status

  while (( elapsed < timeout )); do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
    case "$status" in
      healthy|running)
        log "Container is ready: $container ($status)"
        return 0
        ;;
      unhealthy|exited|dead)
        fail "Container failed: $container ($status)"
        ;;
    esac

    sleep 2
    elapsed=$((elapsed + 2))
  done

  fail "Timed out waiting for container: $container"
}

start_stack() {
  log "Starting Remnawave Node stack"
  chown_node_dir_if_needed
  run_in_node_dir docker compose up -d
  wait_for_container remnanode 120
}

main() {
  require_root
  require_cmd apt-get
  load_env
  require_vars
  validate_env
  install_base_packages
  require_cmd curl
  require_cmd ufw
  require_cmd sysctl
  install_docker_if_missing
  require_cmd docker
  create_or_update_service_user

  if [[ "$DISABLE_IPV6" == "false" ]]; then
    enable_ipv6
  fi

  configure_ufw
  ensure_certificate

  if [[ "$DISABLE_IPV6" == "true" ]]; then
    disable_ipv6
  fi

  write_compose
  validate_compose
  start_stack

  log "Remnawave Node is deployed"
  log "Logs: cd $COMPOSE_DIR && docker compose logs -f"
}

main "$@"
