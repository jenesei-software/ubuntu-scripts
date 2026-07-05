#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
NODE_KEYRING="/etc/apt/keyrings/nodesource.gpg"
NODE_SOURCE_LIST="/etc/apt/sources.list.d/nodesource.list"
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts ghost"

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
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/ghost && bash check-setup.sh"; }

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
  GHOST_SYSTEM_USER=""
  GHOST_SYSTEM_PASSWORD=""
  GHOST_SYSTEM_SSH_PUB=""
  GHOST_URL=""
  GHOST_INSTALL_DIR=""
  GHOST_PORT=""
  GHOST_BIND_IP=""
  GHOST_STAFF_DEVICE_VERIFICATION=""
  GHOST_DB_NAME=""
  GHOST_DB_USER=""
  GHOST_DB_PASSWORD=""
  GHOST_NODE_MAJOR=""
  GHOST_CONFIGURE_CADDY=""
  GHOST_CADDY_OVERWRITE_DOMAIN=""
  CADDYFILE=""
  MYSQL_ADMIN_USER=""
  MYSQL_ADMIN_PASSWORD=""
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

  GHOST_INSTALL_DIR="${GHOST_INSTALL_DIR:-/var/www/ghost}"
  GHOST_PORT="${GHOST_PORT:-2368}"
  GHOST_BIND_IP="${GHOST_BIND_IP:-127.0.0.1}"
  GHOST_STAFF_DEVICE_VERIFICATION="${GHOST_STAFF_DEVICE_VERIFICATION:-false}"
  GHOST_DB_NAME="${GHOST_DB_NAME:-ghost_prod}"
  GHOST_DB_USER="${GHOST_DB_USER:-ghost}"
  GHOST_NODE_MAJOR="${GHOST_NODE_MAJOR:-22}"
  GHOST_CONFIGURE_CADDY="${GHOST_CONFIGURE_CADDY:-true}"
  GHOST_CADDY_OVERWRITE_DOMAIN="${GHOST_CADDY_OVERWRITE_DOMAIN:-ask}"
  CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
  MYSQL_ADMIN_USER="${MYSQL_ADMIN_USER:-root}"
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

ghost_host() {
  local value="$GHOST_URL"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  printf '%s\n' "$value"
}

mysql_admin() {
  if [[ -n "${MYSQL_ADMIN_PASSWORD:-}" ]]; then
    mysql -u "$MYSQL_ADMIN_USER" -p"$MYSQL_ADMIN_PASSWORD"
  else
    mysql -u "$MYSQL_ADMIN_USER"
  fi
}

ufw_has_tcp_port() {
  local port="$1"
  ufw status | grep -Eq "(^|[[:space:]])${port}/tcp([[:space:]]|$)"
}

check_system() {
  section "Base system"
  check_cmd node
  check_cmd npm
  check_cmd ghost
  check_cmd mysql
  check_cmd systemctl
  check_cmd caddy
  check_cmd ufw
  check_cmd ss

  if command -v node >/dev/null 2>&1; then
    info "Node version: $(node --version)"
  fi
  if command -v ghost >/dev/null 2>&1; then
    info "Ghost-CLI version: $(ghost --version)"
  fi
}

check_system_user() {
  section "Ghost system user"
  if [[ -z "${GHOST_SYSTEM_USER:-}" ]]; then
    warn "GHOST_SYSTEM_USER is not set"
    return
  fi

  if id "$GHOST_SYSTEM_USER" >/dev/null 2>&1; then
    ok "System user exists: $GHOST_SYSTEM_USER"
  else
    err "System user does not exist: $GHOST_SYSTEM_USER"
    return
  fi

  if id -nG "$GHOST_SYSTEM_USER" | tr ' ' '\n' | grep -qx sudo; then
    ok "System user is in sudo group"
  else
    warn "System user is not in sudo group"
  fi

  if [[ -f "/etc/sudoers.d/90-ubuntu-scripts-ghost-$GHOST_SYSTEM_USER" ]]; then
    ok "Passwordless sudo drop-in exists for Ghost system user"
  else
    warn "Passwordless sudo drop-in is missing for Ghost system user"
  fi
}

check_repositories() {
  section "Repositories"
  [[ -f "$NODE_KEYRING" ]] && ok "NodeSource keyring is present" || warn "NodeSource keyring is missing: $NODE_KEYRING"
  [[ -f "$NODE_SOURCE_LIST" ]] && ok "NodeSource apt source is present" || warn "NodeSource apt source is missing: $NODE_SOURCE_LIST"
}

check_mysql() {
  section "MySQL"
  check_service_active mysql

  if mysql_admin >/dev/null 2>&1 <<SQL
USE \`$GHOST_DB_NAME\`;
SELECT 1;
SQL
  then
    ok "Ghost database exists and is readable: $GHOST_DB_NAME"
  else
    err "Could not read Ghost database: $GHOST_DB_NAME"
  fi
}

check_ghost() {
  section "Ghost"
  local config_file="$GHOST_INSTALL_DIR/config.production.json"

  if [[ -d "$GHOST_INSTALL_DIR" ]]; then
    ok "Ghost install directory exists: $GHOST_INSTALL_DIR"
  else
    err "Ghost install directory is missing: $GHOST_INSTALL_DIR"
    return
  fi

  [[ -d "$GHOST_INSTALL_DIR/current" ]] && ok "Ghost current symlink/directory exists" || err "Ghost current directory is missing"
  [[ -f "$config_file" ]] && ok "Ghost production config exists" || warn "Ghost production config is missing"

  if [[ -f "$config_file" ]] && command -v node >/dev/null 2>&1; then
    local staff_device_verification
    staff_device_verification="$(node - "$config_file" <<'NODE'
const fs = require('fs');

try {
  const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const value = config.security && config.security.staffDeviceVerification;
  if (value === true || value === false) {
    console.log(String(value));
  } else {
    console.log('unset');
  }
} catch (error) {
  console.log('invalid');
}
NODE
)"
    if [[ "$staff_device_verification" == "$GHOST_STAFF_DEVICE_VERIFICATION" ]]; then
      ok "Ghost staffDeviceVerification=$staff_device_verification"
    else
      warn "Ghost staffDeviceVerification=$staff_device_verification, expected $GHOST_STAFF_DEVICE_VERIFICATION"
    fi
  fi

  if command -v ghost >/dev/null 2>&1; then
    (cd "$GHOST_INSTALL_DIR" && ghost status) || warn "ghost status reported a problem"
  fi

  if ss -tln "( sport = :$GHOST_PORT )" | grep -q LISTEN; then
    ok "Ghost port is listening: $GHOST_PORT"
  else
    err "Ghost port is not listening: $GHOST_PORT"
  fi
}

check_caddy() {
  section "Caddy"
  if [[ "$GHOST_CONFIGURE_CADDY" != "true" ]]; then
    info "GHOST_CONFIGURE_CADDY=false; skipping Caddy checks"
    return
  fi

  check_service_active caddy
  [[ -f "$CADDYFILE" ]] && ok "Caddyfile exists: $CADDYFILE" || { err "Caddyfile is missing: $CADDYFILE"; return; }

  if command -v caddy >/dev/null 2>&1; then
    caddy validate --config "$CADDYFILE" >/dev/null 2>&1 && ok "Caddyfile is valid" || err "Caddyfile validation failed"
  fi

  if [[ -n "${GHOST_URL:-}" ]]; then
    local host upstream
    host="$(ghost_host)"
    upstream="${GHOST_BIND_IP}:${GHOST_PORT}"

    grep -Fq "$host" "$CADDYFILE" && ok "Caddyfile contains Ghost host: $host" || err "Caddyfile does not contain Ghost host: $host"
    if grep -Fq "reverse_proxy $upstream" "$CADDYFILE" || grep -Fq "reverse_proxy http://$upstream" "$CADDYFILE"; then
      ok "Caddyfile points to Ghost upstream: $upstream"
    else
      err "Caddyfile does not point to Ghost upstream: $upstream"
    fi

    if grep -Fq "$CADDY_MANAGED_PREFIX $host" "$CADDYFILE"; then
      ok "Managed Ghost Caddy block is present"
    else
      warn "Ghost host exists without managed marker, or is managed manually"
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
  check_system_user
  check_repositories
  check_mysql
  check_ghost
  check_caddy
  check_ufw
}

main "$@"
