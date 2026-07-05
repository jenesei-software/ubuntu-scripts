#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_SOURCE_LIST="/etc/apt/sources.list.d/docker.list"
PANEL_CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts remnawave-panel"
SUBSCRIPTION_CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts remnawave-subscription"

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
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/remnawave-panel && bash check-setup.sh"; }

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
  PANEL_DOMAIN=""
  FRONT_END_DOMAIN=""
  SUBSCRIPTION_PAGE_DOMAIN=""
  SUB_PUBLIC_DOMAIN=""
  REMNAWAVE_PANEL_INSTALL_DIR=""
  REMNAWAVE_PANEL_BIND_IP=""
  REMNAWAVE_PANEL_PORT=""
  REMNAWAVE_METRICS_PORT=""
  SUBSCRIPTION_PAGE_BIND_IP=""
  SUBSCRIPTION_PAGE_PORT=""
  APP_PORT=""
  METRICS_PORT=""
  REMNAWAVE_PANEL_SYSTEM_USER=""
  REMNAWAVE_PANEL_CONFIGURE_CADDY=""
  CADDYFILE=""
}

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
}

set_paths() {
  REMNAWAVE_PANEL_INSTALL_DIR="${REMNAWAVE_PANEL_INSTALL_DIR:-/opt/remnawave}"
  PANEL_DIR="$REMNAWAVE_PANEL_INSTALL_DIR"
  PANEL_COMPOSE_FILE="$PANEL_DIR/docker-compose.yml"
  PANEL_ENV_FILE="$PANEL_DIR/.env"
  SUBSCRIPTION_DIR="$PANEL_DIR/subscription"
  SUBSCRIPTION_COMPOSE_FILE="$SUBSCRIPTION_DIR/docker-compose.yml"
  SUBSCRIPTION_ENV_FILE="$SUBSCRIPTION_DIR/.env"
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
    load_env_file "$ENV_FILE"
  else
    warn "Environment file not found: $ENV_FILE"
  fi

  set_paths
  load_env_file "$PANEL_ENV_FILE"
  set_paths

  PANEL_DOMAIN="$(strip_protocol "${PANEL_DOMAIN:-${FRONT_END_DOMAIN:-}}")"
  SUBSCRIPTION_PAGE_DOMAIN="$(strip_protocol "${SUBSCRIPTION_PAGE_DOMAIN:-}")"
  REMNAWAVE_PANEL_BIND_IP="${REMNAWAVE_PANEL_BIND_IP:-127.0.0.1}"
  REMNAWAVE_PANEL_PORT="${REMNAWAVE_PANEL_PORT:-${APP_PORT:-3000}}"
  REMNAWAVE_METRICS_PORT="${REMNAWAVE_METRICS_PORT:-${METRICS_PORT:-3001}}"
  SUBSCRIPTION_PAGE_BIND_IP="${SUBSCRIPTION_PAGE_BIND_IP:-127.0.0.1}"
  SUBSCRIPTION_PAGE_PORT="${SUBSCRIPTION_PAGE_PORT:-3010}"
  APP_PORT="${APP_PORT:-3000}"
  METRICS_PORT="${METRICS_PORT:-3001}"
  REMNAWAVE_PANEL_SYSTEM_USER="${REMNAWAVE_PANEL_SYSTEM_USER:-}"
  REMNAWAVE_PANEL_CONFIGURE_CADDY="${REMNAWAVE_PANEL_CONFIGURE_CADDY:-true}"
  CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
}

subscription_expected() {
  [[ -n "${SUBSCRIPTION_PAGE_DOMAIN:-}" || -f "$SUBSCRIPTION_COMPOSE_FILE" ]]
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
  [[ -n "${REMNAWAVE_PANEL_SYSTEM_USER:-}" ]]
}

check_service_user() {
  section "Service user"
  if ! service_user_enabled; then
    info "REMNAWAVE_PANEL_SYSTEM_USER is empty; Docker Compose operations are run as root"
    return
  fi

  if id "$REMNAWAVE_PANEL_SYSTEM_USER" >/dev/null 2>&1; then
    ok "Service user exists: $REMNAWAVE_PANEL_SYSTEM_USER"
  else
    err "Service user is missing: $REMNAWAVE_PANEL_SYSTEM_USER"
    return
  fi

  id -nG "$REMNAWAVE_PANEL_SYSTEM_USER" | tr ' ' '\n' | grep -qx docker && ok "Service user is in docker group" || err "Service user is not in docker group"
  [[ -d "$PANEL_DIR" ]] && [[ "$(stat -c '%U' "$PANEL_DIR")" == "$REMNAWAVE_PANEL_SYSTEM_USER" ]] && ok "Install directory is owned by $REMNAWAVE_PANEL_SYSTEM_USER" || warn "Install directory is not owned by $REMNAWAVE_PANEL_SYSTEM_USER"

  if runuser -u "$REMNAWAVE_PANEL_SYSTEM_USER" -- docker info >/dev/null 2>&1; then
    ok "Service user can access Docker"
  else
    err "Service user cannot access Docker"
  fi
}

ufw_has_tcp_port() {
  local port="$1"
  ufw status | grep -Eq "(^|[[:space:]])${port}/tcp([[:space:]]|$)"
}

http_status() {
  local url="$1"
  curl -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true
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

check_files() {
  section "Remnawave Panel files"
  [[ -d "$PANEL_DIR" ]] && ok "Install directory exists: $PANEL_DIR" || { err "Install directory is missing: $PANEL_DIR"; return; }
  [[ -f "$PANEL_COMPOSE_FILE" ]] && ok "Panel compose file exists" || err "Panel compose file is missing"
  [[ -f "$PANEL_ENV_FILE" ]] && ok "Panel .env exists" || err "Panel .env is missing"

  if [[ -f "$PANEL_ENV_FILE" ]]; then
    grep -Eq '^JWT_AUTH_SECRET=' "$PANEL_ENV_FILE" && ok "JWT_AUTH_SECRET is present" || warn "JWT_AUTH_SECRET is missing"
    grep -Eq '^JWT_API_TOKENS_SECRET=' "$PANEL_ENV_FILE" && ok "JWT_API_TOKENS_SECRET is present" || warn "JWT_API_TOKENS_SECRET is missing"
    grep -Eq '^SUB_PUBLIC_DOMAIN=' "$PANEL_ENV_FILE" && ok "SUB_PUBLIC_DOMAIN is present" || warn "SUB_PUBLIC_DOMAIN is missing"
  fi

  if subscription_expected; then
    section "Subscription page files"
    [[ -d "$SUBSCRIPTION_DIR" ]] && ok "Subscription directory exists: $SUBSCRIPTION_DIR" || err "Subscription directory is missing"
    [[ -f "$SUBSCRIPTION_COMPOSE_FILE" ]] && ok "Subscription compose file exists" || err "Subscription compose file is missing"
    [[ -f "$SUBSCRIPTION_ENV_FILE" ]] && ok "Subscription .env exists" || err "Subscription .env is missing"
  fi
}

check_compose() {
  section "Docker Compose"
  [[ -f "$PANEL_COMPOSE_FILE" ]] || { err "Panel compose file is missing: $PANEL_COMPOSE_FILE"; return; }

  if (cd "$PANEL_DIR" && docker compose config >/dev/null 2>&1); then
    ok "Panel compose file is valid"
  else
    err "Panel compose file validation failed"
    (cd "$PANEL_DIR" && docker compose config) || true
  fi

  local container
  for container in remnawave remnawave-db remnawave-redis; do
    docker ps --format '{{.Names}}' | grep -qx "$container" && ok "Container is running: $container" || err "Container is not running: $container"
  done

  if docker network inspect remnawave-network >/dev/null 2>&1; then
    ok "Docker network exists: remnawave-network"
  else
    err "Docker network missing: remnawave-network"
  fi

  (cd "$PANEL_DIR" && docker compose ps) || warn "Could not run panel docker compose ps"

  if subscription_expected; then
    section "Subscription Docker Compose"
    if [[ -f "$SUBSCRIPTION_COMPOSE_FILE" ]]; then
      if (cd "$SUBSCRIPTION_DIR" && docker compose config >/dev/null 2>&1); then
        ok "Subscription compose file is valid"
      else
        err "Subscription compose file validation failed"
        (cd "$SUBSCRIPTION_DIR" && docker compose config) || true
      fi
      (cd "$SUBSCRIPTION_DIR" && docker compose ps) || warn "Could not run subscription docker compose ps"
    fi

    docker ps --format '{{.Names}}' | grep -qx remnawave-subscription-page && ok "Container is running: remnawave-subscription-page" || err "Container is not running: remnawave-subscription-page"
  fi
}

check_listen_port() {
  local name="$1"
  local bind_ip="$2"
  local port="$3"

  if ss -tln "( sport = :$port )" | grep -q LISTEN; then
    ok "$name port is listening: $port"
  else
    err "$name port is not listening: $port"
    return
  fi

  if ss -tln | grep -Fq "${bind_ip}:${port}"; then
    ok "$name binding was detected: ${bind_ip}:${port}"
  else
    warn "$name binding ${bind_ip}:${port} was not detected in ss output"
  fi
}

check_ports() {
  section "Ports and bindings"
  check_listen_port "Panel" "$REMNAWAVE_PANEL_BIND_IP" "$REMNAWAVE_PANEL_PORT"
  check_listen_port "Metrics" "$REMNAWAVE_PANEL_BIND_IP" "$REMNAWAVE_METRICS_PORT"

  if subscription_expected; then
    check_listen_port "Subscription page" "$SUBSCRIPTION_PAGE_BIND_IP" "$SUBSCRIPTION_PAGE_PORT"
  fi
}

check_http() {
  section "Health checks"
  local status_code

  status_code="$(http_status "http://${REMNAWAVE_PANEL_BIND_IP}:${REMNAWAVE_METRICS_PORT}/health")"
  if [[ "$status_code" == "200" ]]; then
    ok "Local Remnawave health endpoint is reachable: HTTP $status_code"
  else
    err "Local Remnawave health endpoint is not reachable: HTTP ${status_code:-000}"
  fi

  if subscription_expected; then
    status_code="$(http_status "http://${SUBSCRIPTION_PAGE_BIND_IP}:${SUBSCRIPTION_PAGE_PORT}/")"
    if [[ "$status_code" =~ ^[234][0-9][0-9]$ ]]; then
      ok "Local subscription page endpoint is reachable: HTTP $status_code"
    else
      warn "Local subscription page endpoint did not return an expected status: HTTP ${status_code:-000}"
    fi
  fi
}

check_caddy_host() {
  local label="$1"
  local host="$2"
  local upstream="$3"
  local managed_prefix="$4"

  [[ -n "$host" ]] || {
    warn "$label domain is not set, skipping Caddy host check"
    return
  }

  grep -Fq "$host" "$CADDYFILE" && ok "Caddyfile contains $label host: $host" || err "Caddyfile does not contain $label host: $host"
  if grep -Fq "reverse_proxy $upstream" "$CADDYFILE" || grep -Fq "reverse_proxy http://$upstream" "$CADDYFILE"; then
    ok "Caddyfile points $label to upstream: $upstream"
  else
    err "Caddyfile does not point $label to upstream: $upstream"
  fi

  if grep -Fq "$managed_prefix $host" "$CADDYFILE"; then
    ok "Managed $label Caddy block is present"
  else
    warn "$label host exists without managed marker, or is managed manually"
  fi
}

check_caddy() {
  section "Caddy"
  if [[ "$REMNAWAVE_PANEL_CONFIGURE_CADDY" != "true" ]]; then
    info "REMNAWAVE_PANEL_CONFIGURE_CADDY=false; skipping Caddy checks"
    return
  fi

  check_service_active caddy
  [[ -f "$CADDYFILE" ]] && ok "Caddyfile exists: $CADDYFILE" || { err "Caddyfile is missing: $CADDYFILE"; return; }

  if command -v caddy >/dev/null 2>&1; then
    caddy validate --config "$CADDYFILE" >/dev/null 2>&1 && ok "Caddyfile is valid" || err "Caddyfile validation failed"
  fi

  check_caddy_host "Remnawave Panel" "$PANEL_DOMAIN" "${REMNAWAVE_PANEL_BIND_IP}:${REMNAWAVE_PANEL_PORT}" "$PANEL_CADDY_MANAGED_PREFIX"

  if subscription_expected; then
    check_caddy_host "Remnawave Subscription Page" "$SUBSCRIPTION_PAGE_DOMAIN" "${SUBSCRIPTION_PAGE_BIND_IP}:${SUBSCRIPTION_PAGE_PORT}" "$SUBSCRIPTION_CADDY_MANAGED_PREFIX"
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
  check_files
  check_compose
  check_ports
  check_http
  check_caddy
  check_ufw
}

main "$@"
