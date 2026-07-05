#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_SOURCE_LIST="/etc/apt/sources.list.d/docker.list"
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts supabase"

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
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/supabase && bash check-setup.sh"; }

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
  SUPABASE_URL=""
  SUPABASE_INSTALL_DIR=""
  SUPABASE_BIND_IP=""
  SUPABASE_KONG_HTTP_PORT=""
  SUPABASE_KONG_HTTPS_PORT=""
  SUPABASE_DB_BIND_IP=""
  SUPABASE_POSTGRES_PORT=""
  SUPABASE_POOLER_TRANSACTION_PORT=""
  SUPABASE_SYSTEM_USER=""
  SUPABASE_SYSTEM_PASSWORD=""
  SUPABASE_SYSTEM_SSH_PUB=""
  SUPABASE_CONFIGURE_CADDY=""
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

  SUPABASE_INSTALL_DIR="${SUPABASE_INSTALL_DIR:-/opt/supabase}"
  SUPABASE_BIND_IP="${SUPABASE_BIND_IP:-127.0.0.1}"
  SUPABASE_KONG_HTTP_PORT="${SUPABASE_KONG_HTTP_PORT:-8000}"
  SUPABASE_KONG_HTTPS_PORT="${SUPABASE_KONG_HTTPS_PORT:-8443}"
  SUPABASE_DB_BIND_IP="${SUPABASE_DB_BIND_IP:-127.0.0.1}"
  SUPABASE_POSTGRES_PORT="${SUPABASE_POSTGRES_PORT:-5432}"
  SUPABASE_POOLER_TRANSACTION_PORT="${SUPABASE_POOLER_TRANSACTION_PORT:-6543}"
  SUPABASE_SYSTEM_USER="${SUPABASE_SYSTEM_USER:-}"
  SUPABASE_CONFIGURE_CADDY="${SUPABASE_CONFIGURE_CADDY:-true}"
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
  [[ -n "${SUPABASE_SYSTEM_USER:-}" ]]
}

check_service_user() {
  section "Service user"
  if ! service_user_enabled; then
    info "SUPABASE_SYSTEM_USER is empty; Docker Compose operations are run as root"
    return
  fi

  if id "$SUPABASE_SYSTEM_USER" >/dev/null 2>&1; then
    ok "Service user exists: $SUPABASE_SYSTEM_USER"
  else
    err "Service user is missing: $SUPABASE_SYSTEM_USER"
    return
  fi

  id -nG "$SUPABASE_SYSTEM_USER" | tr ' ' '\n' | grep -qx docker && ok "Service user is in docker group" || err "Service user is not in docker group"
  [[ -d "$SUPABASE_INSTALL_DIR" ]] && [[ "$(stat -c '%U' "$SUPABASE_INSTALL_DIR")" == "$SUPABASE_SYSTEM_USER" ]] && ok "Install directory is owned by $SUPABASE_SYSTEM_USER" || warn "Install directory is not owned by $SUPABASE_SYSTEM_USER"

  if runuser -u "$SUPABASE_SYSTEM_USER" -- docker info >/dev/null 2>&1; then
    ok "Service user can access Docker"
  else
    err "Service user cannot access Docker"
  fi
}

supabase_host() {
  local value="$SUPABASE_URL"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  printf '%s\n' "$value"
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
  check_cmd git
  check_cmd jq
  check_cmd openssl
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

check_project_files() {
  section "Supabase files"
  [[ -d "$SUPABASE_INSTALL_DIR" ]] && ok "Install directory exists: $SUPABASE_INSTALL_DIR" || { err "Install directory is missing: $SUPABASE_INSTALL_DIR"; return; }
  [[ -f "$SUPABASE_INSTALL_DIR/docker-compose.yml" ]] && ok "Compose file exists" || err "Compose file is missing"
  [[ -f "$SUPABASE_INSTALL_DIR/run.sh" ]] && ok "run.sh exists" || err "run.sh is missing"
  [[ -f "$SUPABASE_INSTALL_DIR/.env" ]] && ok "Supabase .env exists" || err "Supabase .env is missing"
  [[ -d "$SUPABASE_INSTALL_DIR/utils" ]] && ok "Supabase utils directory exists" || err "Supabase utils directory is missing"

  if [[ -f "$SUPABASE_INSTALL_DIR/.env" ]]; then
    grep -Eq '^SUPABASE_PUBLISHABLE_KEY=sb_publishable_' "$SUPABASE_INSTALL_DIR/.env" && ok "Publishable API key is present" || warn "Publishable API key is missing or not generated"
    grep -Eq '^SUPABASE_SECRET_KEY=sb_secret_' "$SUPABASE_INSTALL_DIR/.env" && ok "Secret API key is present" || warn "Secret API key is missing or not generated"
  fi
}

check_compose() {
  section "Docker Compose"
  local compose_file="$SUPABASE_INSTALL_DIR/docker-compose.yml"

  [[ -f "$compose_file" ]] || { err "Compose file is missing: $compose_file"; return; }

  if (cd "$SUPABASE_INSTALL_DIR" && docker compose config >/dev/null 2>&1); then
    ok "Compose file is valid"
  else
    err "Compose file validation failed"
    (cd "$SUPABASE_INSTALL_DIR" && docker compose config) || true
  fi

  local containers=(
    supabase-studio
    supabase-kong
    supabase-auth
    supabase-rest
    realtime-dev.supabase-realtime
    supabase-storage
    supabase-imgproxy
    supabase-meta
    supabase-db
    supabase-pooler
  )

  local container
  for container in "${containers[@]}"; do
    docker ps --format '{{.Names}}' | grep -qx "$container" && ok "Container is running: $container" || err "Container is not running: $container"
  done

  (cd "$SUPABASE_INSTALL_DIR" && docker compose ps) || warn "Could not run docker compose ps"
}

check_supabase() {
  section "Supabase"
  if ss -tln "( sport = :$SUPABASE_KONG_HTTP_PORT )" | grep -q LISTEN; then
    ok "Kong HTTP port is listening: $SUPABASE_KONG_HTTP_PORT"
  else
    err "Kong HTTP port is not listening: $SUPABASE_KONG_HTTP_PORT"
  fi

  local auth_status
  auth_status="$(http_status "http://$SUPABASE_BIND_IP:$SUPABASE_KONG_HTTP_PORT/auth/v1/")"
  case "$auth_status" in
    200|401|404)
      ok "Auth endpoint is reachable through Kong: HTTP $auth_status"
      ;;
    *)
      warn "Auth endpoint did not return an expected status: HTTP ${auth_status:-000}"
      ;;
  esac

  if ss -tln "( sport = :$SUPABASE_POSTGRES_PORT )" | grep -q LISTEN; then
    ok "Supavisor session port is listening: $SUPABASE_POSTGRES_PORT"
  else
    warn "Supavisor session port is not listening: $SUPABASE_POSTGRES_PORT"
  fi

  if ss -tln "( sport = :$SUPABASE_POOLER_TRANSACTION_PORT )" | grep -q LISTEN; then
    ok "Supavisor transaction port is listening: $SUPABASE_POOLER_TRANSACTION_PORT"
  else
    warn "Supavisor transaction port is not listening: $SUPABASE_POOLER_TRANSACTION_PORT"
  fi

  if [[ "$SUPABASE_DB_BIND_IP" == "127.0.0.1" || "$SUPABASE_DB_BIND_IP" == "localhost" || "$SUPABASE_DB_BIND_IP" == "::1" ]]; then
    ok "Supavisor ports are configured for local binding: $SUPABASE_DB_BIND_IP"
  else
    warn "Supavisor ports are not local-only: $SUPABASE_DB_BIND_IP"
  fi
}

check_caddy() {
  section "Caddy"
  if [[ "$SUPABASE_CONFIGURE_CADDY" != "true" ]]; then
    info "SUPABASE_CONFIGURE_CADDY=false; skipping Caddy checks"
    return
  fi

  check_service_active caddy
  [[ -f "$CADDYFILE" ]] && ok "Caddyfile exists: $CADDYFILE" || { err "Caddyfile is missing: $CADDYFILE"; return; }

  if command -v caddy >/dev/null 2>&1; then
    caddy validate --config "$CADDYFILE" >/dev/null 2>&1 && ok "Caddyfile is valid" || err "Caddyfile validation failed"
  fi

  if [[ -n "${SUPABASE_URL:-}" ]]; then
    local host upstream
    host="$(supabase_host)"
    upstream="${SUPABASE_BIND_IP}:${SUPABASE_KONG_HTTP_PORT}"

    grep -Fq "$host" "$CADDYFILE" && ok "Caddyfile contains Supabase host: $host" || err "Caddyfile does not contain Supabase host: $host"
    if grep -Fq "reverse_proxy $upstream" "$CADDYFILE" || grep -Fq "reverse_proxy http://$upstream" "$CADDYFILE"; then
      ok "Caddyfile points to Supabase upstream: $upstream"
    else
      err "Caddyfile does not point to Supabase upstream: $upstream"
    fi

    if grep -Fq "$CADDY_MANAGED_PREFIX $host" "$CADDYFILE"; then
      ok "Managed Supabase Caddy block is present"
    else
      warn "Supabase host exists without managed marker, or is managed manually"
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
  check_project_files
  check_compose
  check_supabase
  check_caddy
  check_ufw
}

main "$@"
