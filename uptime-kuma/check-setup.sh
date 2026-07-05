#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_SOURCE_LIST="/etc/apt/sources.list.d/docker.list"
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts uptime-kuma"

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
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/uptime-kuma && bash check-setup.sh"; }

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

  ENV_FILE=""
}

reset_env_vars() {
  UPTIME_KUMA_URL=""
  UPTIME_KUMA_INSTALL_DIR=""
  UPTIME_KUMA_BIND_IP=""
  UPTIME_KUMA_PORT=""
  UPTIME_KUMA_CONTAINER_NAME=""
  UPTIME_KUMA_SYSTEM_USER=""
  UPTIME_KUMA_SYSTEM_PASSWORD=""
  UPTIME_KUMA_SYSTEM_SSH_PUB=""
  UPTIME_KUMA_CONFIGURE_CADDY=""
  CADDYFILE=""
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

  UPTIME_KUMA_INSTALL_DIR="${UPTIME_KUMA_INSTALL_DIR:-/opt/uptime-kuma}"
  UPTIME_KUMA_BIND_IP="${UPTIME_KUMA_BIND_IP:-127.0.0.1}"
  UPTIME_KUMA_PORT="${UPTIME_KUMA_PORT:-3001}"
  UPTIME_KUMA_CONTAINER_NAME="${UPTIME_KUMA_CONTAINER_NAME:-uptime-kuma}"
  UPTIME_KUMA_SYSTEM_USER="${UPTIME_KUMA_SYSTEM_USER:-}"
  UPTIME_KUMA_CONFIGURE_CADDY="${UPTIME_KUMA_CONFIGURE_CADDY:-true}"
  CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
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
  [[ -n "${UPTIME_KUMA_SYSTEM_USER:-}" ]]
}

check_service_user() {
  section "Service user"
  if ! service_user_enabled; then
    info "UPTIME_KUMA_SYSTEM_USER is empty; Docker Compose operations are run as root"
    return
  fi

  if id "$UPTIME_KUMA_SYSTEM_USER" >/dev/null 2>&1; then
    ok "Service user exists: $UPTIME_KUMA_SYSTEM_USER"
  else
    err "Service user is missing: $UPTIME_KUMA_SYSTEM_USER"
    return
  fi

  id -nG "$UPTIME_KUMA_SYSTEM_USER" | tr ' ' '\n' | grep -qx docker && ok "Service user is in docker group" || err "Service user is not in docker group"
  [[ -d "$UPTIME_KUMA_INSTALL_DIR" ]] && [[ "$(stat -c '%U' "$UPTIME_KUMA_INSTALL_DIR")" == "$UPTIME_KUMA_SYSTEM_USER" ]] && ok "Install directory is owned by $UPTIME_KUMA_SYSTEM_USER" || warn "Install directory is not owned by $UPTIME_KUMA_SYSTEM_USER"

  if runuser -u "$UPTIME_KUMA_SYSTEM_USER" -- docker info >/dev/null 2>&1; then
    ok "Service user can access Docker"
  else
    err "Service user cannot access Docker"
  fi
}

uptime_kuma_host() {
  local value="$UPTIME_KUMA_URL"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  printf '%s\n' "$value"
}

ufw_has_tcp_port() {
  local port="$1"
  ufw status | grep -Eq "(^|[[:space:]])${port}/tcp([[:space:]]|$)"
}

check_system() {
  section "Base system"
  check_cmd docker
  check_cmd systemctl
  check_cmd curl
  check_cmd ss
  check_cmd caddy
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

check_compose() {
  section "Docker Compose"
  local compose_file="$UPTIME_KUMA_INSTALL_DIR/docker-compose.yml"

  [[ -f "$compose_file" ]] && ok "Compose file exists: $compose_file" || { err "Compose file is missing: $compose_file"; return; }

  if docker compose -f "$compose_file" config >/dev/null 2>&1; then
    ok "Compose file is valid"
  else
    err "Compose file validation failed"
    docker compose -f "$compose_file" config || true
  fi

  docker ps --format '{{.Names}}' | grep -qx "$UPTIME_KUMA_CONTAINER_NAME" && ok "Uptime Kuma container is running: $UPTIME_KUMA_CONTAINER_NAME" || err "Uptime Kuma container is not running: $UPTIME_KUMA_CONTAINER_NAME"
  (cd "$UPTIME_KUMA_INSTALL_DIR" && docker compose ps) || warn "Could not run docker compose ps"
}

check_uptime_kuma() {
  section "Uptime Kuma"
  if ss -tln "( sport = :$UPTIME_KUMA_PORT )" | grep -q LISTEN; then
    ok "Uptime Kuma port is listening: $UPTIME_KUMA_PORT"
  else
    err "Uptime Kuma port is not listening: $UPTIME_KUMA_PORT"
  fi

  if curl -fsS "http://$UPTIME_KUMA_BIND_IP:$UPTIME_KUMA_PORT" >/dev/null 2>&1; then
    ok "Uptime Kuma local HTTP endpoint is reachable"
  else
    warn "Uptime Kuma local HTTP endpoint is not reachable yet"
  fi
}

check_caddy() {
  section "Caddy"
  if [[ "$UPTIME_KUMA_CONFIGURE_CADDY" != "true" ]]; then
    info "UPTIME_KUMA_CONFIGURE_CADDY=false; skipping Caddy checks"
    return
  fi

  check_service_active caddy
  [[ -f "$CADDYFILE" ]] && ok "Caddyfile exists: $CADDYFILE" || { err "Caddyfile is missing: $CADDYFILE"; return; }

  if command -v caddy >/dev/null 2>&1; then
    caddy validate --config "$CADDYFILE" >/dev/null 2>&1 && ok "Caddyfile is valid" || err "Caddyfile validation failed"
  fi

  if [[ -n "${UPTIME_KUMA_URL:-}" ]]; then
    local host upstream
    host="$(uptime_kuma_host)"
    upstream="${UPTIME_KUMA_BIND_IP}:${UPTIME_KUMA_PORT}"

    grep -Fq "$host" "$CADDYFILE" && ok "Caddyfile contains Uptime Kuma host: $host" || err "Caddyfile does not contain Uptime Kuma host: $host"
    if grep -Fq "reverse_proxy $upstream" "$CADDYFILE" || grep -Fq "reverse_proxy http://$upstream" "$CADDYFILE"; then
      ok "Caddyfile points to Uptime Kuma upstream: $upstream"
    else
      err "Caddyfile does not point to Uptime Kuma upstream: $upstream"
    fi

    if grep -Fq "$CADDY_MANAGED_PREFIX $host" "$CADDYFILE"; then
      ok "Managed Uptime Kuma Caddy block is present"
    else
      warn "Uptime Kuma host exists without managed marker, or is managed manually"
    fi
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

  ufw_has_tcp_port 80 && ok "HTTP port is open in UFW: 80/tcp" || warn "HTTP port was not found in UFW: 80/tcp"
  ufw_has_tcp_port 443 && ok "HTTPS port is open in UFW: 443/tcp" || warn "HTTPS port was not found in UFW: 443/tcp"
}

main() {
  require_root
  load_env
  check_system
  check_service_user
  check_repository
  check_compose
  check_uptime_kuma
  check_caddy
  check_ufw
}

main "$@"
