#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_SOURCE_LIST="/etc/apt/sources.list.d/docker.list"
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts umami"

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
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/umami && bash check-setup.sh"; }

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
  UMAMI_URL=""
  UMAMI_INSTALL_DIR=""
  UMAMI_BIND_IP=""
  UMAMI_PORT=""
  UMAMI_IMAGE=""
  UMAMI_CONTAINER_NAME=""
  UMAMI_DB_CONTAINER_NAME=""
  POSTGRES_IMAGE=""
  UMAMI_DB_NAME=""
  UMAMI_DB_USER=""
  UMAMI_DB_PASSWORD=""
  UMAMI_APP_SECRET=""
  UMAMI_DISABLE_TELEMETRY=""
  UMAMI_SYSTEM_USER=""
  UMAMI_SYSTEM_PASSWORD=""
  UMAMI_SYSTEM_SSH_PUB=""
  UMAMI_CONFIGURE_CADDY=""
  UMAMI_CADDY_OVERWRITE_DOMAIN=""
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

  UMAMI_INSTALL_DIR="${UMAMI_INSTALL_DIR:-/opt/umami}"
  UMAMI_BIND_IP="${UMAMI_BIND_IP:-127.0.0.1}"
  UMAMI_PORT="${UMAMI_PORT:-3000}"
  UMAMI_CONTAINER_NAME="${UMAMI_CONTAINER_NAME:-umami}"
  UMAMI_DB_CONTAINER_NAME="${UMAMI_DB_CONTAINER_NAME:-umami-db}"
  UMAMI_SYSTEM_USER="${UMAMI_SYSTEM_USER:-}"
  UMAMI_CONFIGURE_CADDY="${UMAMI_CONFIGURE_CADDY:-true}"
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
  [[ -n "${UMAMI_SYSTEM_USER:-}" ]]
}

check_service_user() {
  section "Service user"
  if ! service_user_enabled; then
    info "UMAMI_SYSTEM_USER is empty; Docker Compose operations are run as root"
    return
  fi

  if id "$UMAMI_SYSTEM_USER" >/dev/null 2>&1; then
    ok "Service user exists: $UMAMI_SYSTEM_USER"
  else
    err "Service user is missing: $UMAMI_SYSTEM_USER"
    return
  fi

  id -nG "$UMAMI_SYSTEM_USER" | tr ' ' '\n' | grep -qx docker && ok "Service user is in docker group" || err "Service user is not in docker group"
  [[ -d "$UMAMI_INSTALL_DIR" ]] && [[ "$(stat -c '%U' "$UMAMI_INSTALL_DIR")" == "$UMAMI_SYSTEM_USER" ]] && ok "Install directory is owned by $UMAMI_SYSTEM_USER" || warn "Install directory is not owned by $UMAMI_SYSTEM_USER"

  if runuser -u "$UMAMI_SYSTEM_USER" -- docker info >/dev/null 2>&1; then
    ok "Service user can access Docker"
  else
    err "Service user cannot access Docker"
  fi
}

umami_host() {
  local value="$UMAMI_URL"
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
  local compose_file="$UMAMI_INSTALL_DIR/docker-compose.yml"

  [[ -f "$compose_file" ]] && ok "Compose file exists: $compose_file" || { err "Compose file is missing: $compose_file"; return; }

  if docker compose -f "$compose_file" config >/dev/null 2>&1; then
    ok "Compose file is valid"
  else
    err "Compose file validation failed"
    docker compose -f "$compose_file" config || true
  fi

  docker ps --format '{{.Names}}' | grep -qx "$UMAMI_CONTAINER_NAME" && ok "Umami container is running: $UMAMI_CONTAINER_NAME" || err "Umami container is not running: $UMAMI_CONTAINER_NAME"
  docker ps --format '{{.Names}}' | grep -qx "$UMAMI_DB_CONTAINER_NAME" && ok "Postgres container is running: $UMAMI_DB_CONTAINER_NAME" || err "Postgres container is not running: $UMAMI_DB_CONTAINER_NAME"

  (cd "$UMAMI_INSTALL_DIR" && docker compose ps) || warn "Could not run docker compose ps"
}

check_umami() {
  section "Umami"
  if ss -tln "( sport = :$UMAMI_PORT )" | grep -q LISTEN; then
    ok "Umami port is listening: $UMAMI_PORT"
  else
    err "Umami port is not listening: $UMAMI_PORT"
  fi

  if curl -fsS "http://$UMAMI_BIND_IP:$UMAMI_PORT/api/heartbeat" >/dev/null 2>&1; then
    ok "Umami heartbeat is reachable"
  else
    warn "Umami heartbeat is not reachable yet"
  fi
}

check_caddy() {
  section "Caddy"
  if [[ "$UMAMI_CONFIGURE_CADDY" != "true" ]]; then
    info "UMAMI_CONFIGURE_CADDY=false; skipping Caddy checks"
    return
  fi

  check_service_active caddy
  [[ -f "$CADDYFILE" ]] && ok "Caddyfile exists: $CADDYFILE" || { err "Caddyfile is missing: $CADDYFILE"; return; }

  if command -v caddy >/dev/null 2>&1; then
    caddy validate --config "$CADDYFILE" >/dev/null 2>&1 && ok "Caddyfile is valid" || err "Caddyfile validation failed"
  fi

  if [[ -n "${UMAMI_URL:-}" ]]; then
    local host upstream
    host="$(umami_host)"
    upstream="${UMAMI_BIND_IP}:${UMAMI_PORT}"

    grep -Fq "$host" "$CADDYFILE" && ok "Caddyfile contains Umami host: $host" || err "Caddyfile does not contain Umami host: $host"
    if grep -Fq "reverse_proxy $upstream" "$CADDYFILE" || grep -Fq "reverse_proxy http://$upstream" "$CADDYFILE"; then
      ok "Caddyfile points to Umami upstream: $upstream"
    else
      err "Caddyfile does not point to Umami upstream: $upstream"
    fi

    if grep -Fq "$CADDY_MANAGED_PREFIX $host" "$CADDYFILE"; then
      ok "Managed Umami Caddy block is present"
    else
      warn "Umami host exists without managed marker, or is managed manually"
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
  check_umami
  check_caddy
  check_ufw
}

main "$@"
