#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
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

ok() { log_line "OK" "$*"; }
warn() { log_line "WARN" "$*"; }
err() { log_line "ERROR" "$*"; }
info() { log_line "INFO" "$*"; }
section() { echo; log_line "SECTION" "$*"; }
fail() { log_line "ERROR" "$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/remnawave-node && bash check-setup.sh"; }

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
  if [[ -n "$ENV_FILE_INPUT" ]]; then
    ENV_FILE="$(resolve_env_path "$ENV_FILE_INPUT")"
    return
  fi

  if [[ -f "$SCRIPT_DIR/.env" ]]; then
    ENV_FILE="$SCRIPT_DIR/.env"
    return
  fi

  ENV_FILE=""
}

reset_env_vars() {
  REMNAWAVE_NODE_INSTALL_DIR=""
  REMNAWAVE_NODE_CERT_DIR=""
  SERVER_DOMAIN=""
  DOMAIN_MAIL=""
  PORT_NODE=""
  PANEL_IP=""
  NODE_SECRET=""
  REMNAWAVE_NODE_IMAGE=""
  DISABLE_IPV6=""
  IPV6_INTERFACE=""
  PORT_ARRAY_INBOUNDS=""
  REMNAWAVE_NODE_SYSTEM_USER=""
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
  reset_env_vars

  if [[ -z "$ENV_FILE" ]]; then
    warn "Environment file not found. Expected: $SCRIPT_DIR/.env"
  elif [[ -f "$ENV_FILE" ]]; then
    info "Loading environment from $ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  else
    warn "Environment file not found: $ENV_FILE"
  fi

  set_paths
  SERVER_DOMAIN="$(strip_protocol "${SERVER_DOMAIN:-}")"
  PORT_NODE="${PORT_NODE:-22222}"
  PANEL_IP="${PANEL_IP:-}"
  DISABLE_IPV6="${DISABLE_IPV6:-true}"
  PORT_ARRAY_INBOUNDS="${PORT_ARRAY_INBOUNDS:-}"
  REMNAWAVE_NODE_SYSTEM_USER="${REMNAWAVE_NODE_SYSTEM_USER:-}"
}

check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    ok "Command found: $1"
  else
    err "Command not found: $1"
  fi
}

check_service_active() {
  local service="$1"
  if systemctl is-active --quiet "$service" 2>/dev/null; then
    ok "Service $service: active"
  else
    err "Service $service: NOT active"
  fi
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

run_in_node_dir() {
  if service_user_enabled; then
    runuser -u "$REMNAWAVE_NODE_SYSTEM_USER" -- env HOME="$(service_user_home)" bash -c 'cd "$1" && shift && "$@"' _ "$COMPOSE_DIR" "$@"
  else
    (cd "$COMPOSE_DIR" && "$@")
  fi
}

check_service_user() {
  section "Service user"
  if ! service_user_enabled; then
    info "REMNAWAVE_NODE_SYSTEM_USER is empty; Docker Compose operations are run as root"
    return
  fi

  if id "$REMNAWAVE_NODE_SYSTEM_USER" >/dev/null 2>&1; then
    ok "Service user exists: $REMNAWAVE_NODE_SYSTEM_USER"
  else
    err "Service user is missing: $REMNAWAVE_NODE_SYSTEM_USER"
    return
  fi

  id -nG "$REMNAWAVE_NODE_SYSTEM_USER" | tr ' ' '\n' | grep -qx docker && ok "Service user is in docker group" || err "Service user is not in docker group"
  [[ -d "$COMPOSE_DIR" ]] && [[ "$(stat -c '%U' "$COMPOSE_DIR")" == "$REMNAWAVE_NODE_SYSTEM_USER" ]] && ok "Install directory is owned by $REMNAWAVE_NODE_SYSTEM_USER" || warn "Install directory is not owned by $REMNAWAVE_NODE_SYSTEM_USER"

  if runuser -u "$REMNAWAVE_NODE_SYSTEM_USER" -- env HOME="$(service_user_home)" docker info >/dev/null 2>&1; then
    ok "Service user can access Docker"
  else
    err "Service user cannot access Docker"
  fi
}

resolve_ipv6_interface() {
  if [[ -n "${IPV6_INTERFACE:-}" ]]; then
    printf '%s\n' "$IPV6_INTERFACE"
    return
  fi

  local iface
  if command -v ip >/dev/null 2>&1; then
    iface="$(ip -o -6 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | sed -n '1p' || true)"
    if [[ -z "$iface" ]]; then
      iface="$(ip -o -4 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | sed -n '1p' || true)"
    fi
  fi

  if [[ -z "${iface:-}" && -d /sys/class/net/eth0 ]]; then
    iface="eth0"
  fi

  [[ -n "${iface:-}" ]] || return 1
  printf '%s\n' "$iface"
}

check_sysctl_value() {
  local setting="$1"
  local expected="$2"
  local value

  value="$(sysctl -n "$setting" 2>/dev/null || echo unknown)"
  if [[ "$value" == "$expected" ]]; then
    ok "$setting=$expected"
  else
    err "$setting expected $expected, got $value"
  fi
}

ufw_has_tcp_port() {
  local port="$1"
  ufw status | grep -Eq "(^|[[:space:]])${port}/tcp([[:space:]]|$)"
}

ufw_has_port_protocol() {
  local port="$1"
  local protocol="$2"
  ufw status | grep -Eq "(^|[[:space:]])${port}/${protocol}([[:space:]]|$)"
}

ufw_has_restricted_node_port() {
  local port="$1"
  local source_ip="$2"
  ufw status | awk -v destination="${port}/tcp" -v source="$source_ip" \
    '$1 == destination && $2 == "ALLOW" && $3 == "IN" && $4 == source { found=1 } END { exit !found }'
}

ufw_has_public_node_port() {
  local port="$1"
  ufw status | awk -v destination="${port}/tcp" \
    '$1 == destination && $2 == "ALLOW" && $3 == "IN" && ($4 == "Anywhere" || $4 == "Anywhere(v6)") { found=1 } END { exit !found }'
}

check_system() {
  section "Base system"
  check_cmd docker
  check_cmd systemctl
  check_cmd curl
  check_cmd ip
  check_cmd ss
  check_cmd sysctl
  check_cmd ufw

  check_service_active docker

  if command -v docker >/dev/null 2>&1; then
    info "Docker version: $(docker --version)"
    if docker compose version >/dev/null 2>&1; then
      info "Docker Compose version: $(docker compose version)"
    else
      err "Docker Compose plugin is not available"
    fi
  fi
}

check_repository() {
  section "Docker repository"
  [[ -f "$DOCKER_KEYRING" ]] && ok "Docker keyring is present" || warn "Docker keyring is missing: $DOCKER_KEYRING"
  [[ -f "$DOCKER_SOURCE_LIST" ]] && ok "Docker apt source is present" || warn "Docker apt source is missing: $DOCKER_SOURCE_LIST"
}

check_ipv6() {
  section "IPv6"
  local ipv6_all ipv6_default ipv6_lo
  local iface

  ipv6_all="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo unknown)"
  ipv6_default="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo unknown)"
  ipv6_lo="$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || echo unknown)"

  if [[ "$DISABLE_IPV6" == "true" ]]; then
    if [[ "$ipv6_all" == "1" && "$ipv6_default" == "1" && "$ipv6_lo" == "1" ]]; then
      ok "IPv6 is disabled on the host"
    else
      warn "IPv6 is still enabled on the host, but DISABLE_IPV6=true in .env"
    fi

    [[ -f "$IPV6_DISABLE_SYSCTL_FILE" ]] && ok "IPv6 disable config is present: $IPV6_DISABLE_SYSCTL_FILE" || warn "IPv6 disable config is missing: $IPV6_DISABLE_SYSCTL_FILE"
    return
  fi

  if iface="$(resolve_ipv6_interface)"; then
    ok "IPv6 network interface: $iface"
  else
    err "Could not detect IPv6 network interface. Set IPV6_INTERFACE in .env."
  fi

  check_sysctl_value net.ipv6.conf.all.disable_ipv6 0
  check_sysctl_value net.ipv6.conf.default.disable_ipv6 0
  check_sysctl_value net.ipv6.conf.lo.disable_ipv6 0
  check_sysctl_value net.ipv6.conf.all.forwarding 1
  check_sysctl_value net.ipv6.conf.all.addr_gen_mode 0

  if [[ -n "${iface:-}" ]]; then
    check_sysctl_value "net.ipv6.conf.${iface}.disable_ipv6" 0
    check_sysctl_value "net.ipv6.conf.${iface}.accept_ra" 2
    check_sysctl_value "net.ipv6.conf.${iface}.use_tempaddr" 0
  fi

  [[ -f /proc/net/if_inet6 ]] && ok "IPv6 kernel support is active" || err "IPv6 kernel support is not active. Check kernel boot parameters such as ipv6.disable=1"
  [[ -f "$IPV6_ENABLE_SYSCTL_FILE" ]] && ok "IPv6 enable config is present: $IPV6_ENABLE_SYSCTL_FILE" || err "IPv6 enable config is missing: $IPV6_ENABLE_SYSCTL_FILE"
  [[ -f "$IPV6_DISABLE_SYSCTL_FILE" ]] && err "IPv6 disable config still exists: $IPV6_DISABLE_SYSCTL_FILE" || ok "No Remnawave IPv6 disable config is present"

  if [[ -f "$UFW_DEFAULTS_FILE" ]]; then
    grep -qE '^IPV6=yes$' "$UFW_DEFAULTS_FILE" && ok "UFW IPv6 support is enabled" || err "UFW IPv6 support is not enabled in $UFW_DEFAULTS_FILE"
  else
    warn "UFW defaults file was not found: $UFW_DEFAULTS_FILE"
  fi
}

check_ufw() {
  section "UFW"
  if ! command -v ufw >/dev/null 2>&1; then
    err "Command not found: ufw"
    return
  fi

  if ufw status | grep -q "Status: active"; then
    ok "UFW is active"
  else
    warn "UFW is not active"
  fi

  if [[ -n "${PORT_NODE:-}" ]]; then
    if [[ -z "${PANEL_IP:-}" ]]; then
      err "PANEL_IP is empty; cannot verify that $PORT_NODE/tcp is restricted to the panel"
    elif ufw_has_restricted_node_port "$PORT_NODE" "$PANEL_IP"; then
      ok "Node port is restricted to panel IP: $PANEL_IP -> $PORT_NODE/tcp"
    else
      err "Restricted node rule is missing: $PANEL_IP -> $PORT_NODE/tcp"
    fi
    if ufw_has_public_node_port "$PORT_NODE"; then
      err "Node port is also open publicly and must be restricted: $PORT_NODE/tcp"
    else
      ok "Node port has no public Anywhere rule: $PORT_NODE/tcp"
    fi
  fi

  if [[ -n "$SERVER_DOMAIN" ]]; then
    ufw_has_tcp_port 80 && ok "HTTP port is open in UFW for certificate issuance: 80/tcp" || warn "HTTP port was not found in UFW: 80/tcp"
    ufw_has_tcp_port 443 && ok "HTTPS port is open in UFW: 443/tcp" || warn "HTTPS port was not found in UFW: 443/tcp"
  fi

  if [[ -n "${PORT_ARRAY_INBOUNDS:-}" ]]; then
    local raw_rule rule port protocol
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
        ufw_has_port_protocol "$port" tcp && ok "Inbound port is open: $port/tcp" || warn "Inbound port was not found: $port/tcp"
        ufw_has_port_protocol "$port" udp && ok "Inbound port is open: $port/udp" || warn "Inbound port was not found: $port/udp"
      else
        ufw_has_port_protocol "$port" "$protocol" && ok "Inbound port is open: $port/$protocol" || warn "Inbound port was not found: $port/$protocol"
      fi
    done
  fi
}

check_listening_ports() {
  section "Listening ports"

  if ss -tln "( sport = :$PORT_NODE )" | grep -q LISTEN; then
    ok "Remnawave Node port is listening: $PORT_NODE"
  else
    err "Remnawave Node port is not listening: $PORT_NODE"
  fi

  ss -tulpn || warn "Could not list listening ports with ss"
}

check_certs() {
  section "Certificates"
  if [[ -z "$SERVER_DOMAIN" ]]; then
    info "SERVER_DOMAIN is not set; certificate files are not required"
    return
  fi

  [[ -f "$CERT_DIR/cert.pem" ]] && ok "Found $CERT_DIR/cert.pem" || err "Missing $CERT_DIR/cert.pem"
  [[ -f "$CERT_DIR/key.pem" ]] && ok "Found $CERT_DIR/key.pem" || err "Missing $CERT_DIR/key.pem"
}

check_docker_compose() {
  section "Docker / Remnawave Node"
  local compose_user

  [[ -d "$COMPOSE_DIR" ]] && ok "Install directory exists: $COMPOSE_DIR" || err "Install directory is missing: $COMPOSE_DIR"
  [[ -f "$COMPOSE_FILE" ]] && ok "Compose file exists: $COMPOSE_FILE" || { err "Compose file is missing: $COMPOSE_FILE"; return; }

  if service_user_enabled; then
    compose_user="$REMNAWAVE_NODE_SYSTEM_USER"
  else
    compose_user="root"
  fi

  if run_in_node_dir docker compose config >/dev/null 2>&1; then
    ok "Compose file is valid for Docker Compose user: $compose_user"
  else
    err "Compose file validation failed for Docker Compose user: $compose_user"
    run_in_node_dir docker compose config || true
  fi

  docker ps --format '{{.Names}}' | grep -qx remnanode && ok "Container remnanode is running" || err "Container remnanode is not running"
  if run_in_node_dir docker compose ps --services 2>/dev/null | grep -qx remnanode; then
    ok "Docker Compose sees remnanode as user: $compose_user"
  else
    warn "Docker Compose does not list remnanode as user: $compose_user"
  fi

  if run_in_node_dir docker compose ps; then
    ok "Docker Compose ps works as user: $compose_user"
  else
    warn "Could not run docker compose ps as user: $compose_user"
  fi
}

main() {
  require_root
  load_env
  check_system
  check_service_user
  check_repository
  check_ipv6
  check_ufw
  check_listening_ports
  check_certs
  check_docker_compose
}

main "$@"
