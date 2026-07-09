#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
NODE_KEYRING="/etc/apt/keyrings/nodesource.gpg"
NODE_SOURCE_LIST="/etc/apt/sources.list.d/nodesource.list"
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts ghost"
CADDY_MANAGED_SUFFIX="# END ubuntu-scripts ghost"

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
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/ghost && bash setup-ghost.sh"; }

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

  fail "Environment file not found. Copy ghost/env.example to ghost/.env or run: cd ghost && cp env.example .env"
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
  [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
  log "Loading environment from $ENV_FILE"
  reset_env_vars
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

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

require_vars() {
  local missing=()
  for var in GHOST_SYSTEM_USER GHOST_SYSTEM_PASSWORD GHOST_URL GHOST_DB_PASSWORD; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  if (( ${#missing[@]} > 0 )); then
    fail "Missing required variables in $ENV_FILE: ${missing[*]}"
  fi
}

validate_bool() {
  local value="$1"
  [[ "$value" == "true" || "$value" == "false" ]] || fail "Boolean value must be true or false"
}

validate_identifier() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[A-Za-z0-9_]+$ ]] || fail "$name must contain only letters, digits, and underscores"
}

validate_system_user() {
  [[ "$GHOST_SYSTEM_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail "GHOST_SYSTEM_USER must be a valid Linux user name"
  [[ "$GHOST_SYSTEM_USER" != "root" ]] || fail "GHOST_SYSTEM_USER must not be root"
  [[ "$GHOST_SYSTEM_USER" != "ghost" ]] || fail "GHOST_SYSTEM_USER must not be ghost"
}

validate_env() {
  validate_system_user
  [[ "$GHOST_URL" =~ ^https?://[^/]+/?$ ]] || fail "GHOST_URL must be a full site URL, for example https://example.com"
  [[ "$GHOST_PORT" =~ ^[0-9]+$ ]] || fail "GHOST_PORT must be numeric"
  (( GHOST_PORT >= 1024 && GHOST_PORT <= 65535 )) || fail "GHOST_PORT must be between 1024 and 65535"
  [[ "$GHOST_NODE_MAJOR" =~ ^[0-9]+$ ]] || fail "GHOST_NODE_MAJOR must be numeric"
  validate_bool "$GHOST_STAFF_DEVICE_VERIFICATION"
  validate_bool "$GHOST_CONFIGURE_CADDY"
  [[ "$GHOST_CADDY_OVERWRITE_DOMAIN" == "ask" || "$GHOST_CADDY_OVERWRITE_DOMAIN" == "true" || "$GHOST_CADDY_OVERWRITE_DOMAIN" == "false" ]] || fail "GHOST_CADDY_OVERWRITE_DOMAIN must be ask, true, or false"
  validate_identifier GHOST_DB_NAME "$GHOST_DB_NAME"
  validate_identifier GHOST_DB_USER "$GHOST_DB_USER"
  [[ "$GHOST_DB_PASSWORD" != *"'"* ]] || fail "GHOST_DB_PASSWORD must not contain a single quote"
  [[ "$GHOST_SYSTEM_PASSWORD" != *"'"* ]] || fail "GHOST_SYSTEM_PASSWORD must not contain a single quote"
  [[ "$MYSQL_ADMIN_PASSWORD" != *"'"* ]] || fail "MYSQL_ADMIN_PASSWORD must not contain a single quote"
}

create_or_update_system_user() {
  local sudoers_file

  if id "$GHOST_SYSTEM_USER" >/dev/null 2>&1; then
    log "System user already exists: $GHOST_SYSTEM_USER"
  else
    log "Creating system user: $GHOST_SYSTEM_USER"
    adduser --disabled-password --gecos "" "$GHOST_SYSTEM_USER"
  fi

  echo "$GHOST_SYSTEM_USER:$GHOST_SYSTEM_PASSWORD" | chpasswd
  getent group sudo >/dev/null 2>&1 || groupadd sudo
  usermod -aG sudo "$GHOST_SYSTEM_USER"

  sudoers_file="/etc/sudoers.d/90-ubuntu-scripts-ghost-$GHOST_SYSTEM_USER"
  log "Allowing passwordless sudo for $GHOST_SYSTEM_USER so Ghost-CLI can configure systemd"
  install -d -m 0755 /etc/sudoers.d
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$GHOST_SYSTEM_USER" > "$sudoers_file"
  chmod 0440 "$sudoers_file"

  if [[ -n "${GHOST_SYSTEM_SSH_PUB:-}" ]]; then
    local ssh_dir auth_keys
    ssh_dir="/home/$GHOST_SYSTEM_USER/.ssh"
    auth_keys="$ssh_dir/authorized_keys"

    install -d -m 0700 -o "$GHOST_SYSTEM_USER" -g "$GHOST_SYSTEM_USER" "$ssh_dir"
    touch "$auth_keys"
    chmod 0600 "$auth_keys"
    chown "$GHOST_SYSTEM_USER:$GHOST_SYSTEM_USER" "$auth_keys"

    if ! grep -Fqx "$GHOST_SYSTEM_SSH_PUB" "$auth_keys"; then
      log "Adding SSH public key for $GHOST_SYSTEM_USER"
      printf '%s\n' "$GHOST_SYSTEM_SSH_PUB" >> "$auth_keys"
      chown "$GHOST_SYSTEM_USER:$GHOST_SYSTEM_USER" "$auth_keys"
    else
      log "SSH public key is already present for $GHOST_SYSTEM_USER"
    fi
  fi
}

ghost_host() {
  local value="$GHOST_URL"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  printf '%s\n' "$value"
}

caddy_block_for_host() {
  local host="$1"
  [[ -f "$CADDYFILE" ]] || return 0

  awk -v host="$host" '
    function count_char(value, char, i, total) {
      total = 0
      for (i = 1; i <= length(value); i++) {
        if (substr(value, i, 1) == char) total++
      }
      return total
    }
    {
      original = $0
      trimmed = original
      gsub(/^[ \t]+|[ \t]+$/, "", trimmed)
      if (!in_block && trimmed ~ /\{$/) {
        labels = trimmed
        sub(/[ \t]*\{$/, "", labels)
        gsub(/[ \t]/, "", labels)
        n = split(labels, parts, ",")
        for (i = 1; i <= n; i++) {
          if (parts[i] == host) {
            in_block = 1
            break
          }
        }
      }
      if (in_block) {
        print original
        depth += count_char(original, "{") - count_char(original, "}")
        if (depth <= 0) exit
        next
      }
    }
  ' "$CADDYFILE"
}

caddy_block_points_to_ghost() {
  local block="$1"
  local upstream="${GHOST_BIND_IP}:${GHOST_PORT}"

  grep -Fq "reverse_proxy $upstream" <<< "$block" && return 0
  grep -Fq "reverse_proxy http://$upstream" <<< "$block" && return 0
  [[ "$GHOST_BIND_IP" == "127.0.0.1" ]] && grep -Fq "reverse_proxy localhost:$GHOST_PORT" <<< "$block" && return 0
  [[ "$GHOST_BIND_IP" == "127.0.0.1" ]] && grep -Fq "reverse_proxy http://localhost:$GHOST_PORT" <<< "$block" && return 0
  return 1
}

confirm_caddy_overwrite() {
  local host="$1"
  local answer

  case "$GHOST_CADDY_OVERWRITE_DOMAIN" in
    true)
      log "Caddy domain $host is occupied and will be replaced because GHOST_CADDY_OVERWRITE_DOMAIN=true"
      return 0
      ;;
    false)
      return 1
      ;;
  esac

  printf 'Caddy domain %s already exists and points somewhere else. Replace it with Ghost? [y/N] ' "$host"
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES|Yes)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

preflight_caddy() {
  [[ "$GHOST_CONFIGURE_CADDY" == "true" ]] || return 0

  require_cmd caddy
  local host block begin_marker
  host="$(ghost_host)"
  begin_marker="$CADDY_MANAGED_PREFIX $host"

  [[ -f "$CADDYFILE" ]] || return 0

  if grep -Fq "$begin_marker" "$CADDYFILE"; then
    log "Managed Caddy block already exists for $host and will be updated"
    return
  fi

  block="$(caddy_block_for_host "$host")"
  [[ -z "$block" ]] && return

  if caddy_block_points_to_ghost "$block"; then
    log "Caddy already routes $host to Ghost upstream ${GHOST_BIND_IP}:${GHOST_PORT}; keeping existing block"
    GHOST_CADDY_ALREADY_CONFIGURED=true
    return
  fi

  if confirm_caddy_overwrite "$host"; then
    log "Caddy block for $host will be replaced with Ghost reverse proxy"
    GHOST_CADDY_REPLACE_EXISTING_BLOCK=true
    return
  fi

  fail "Caddyfile already contains an unmanaged block for $host. Setup stopped without replacing it."
}

install_packages() {
  log "Installing Node.js, MySQL, and Ghost dependencies"
  export DEBIAN_FRONTEND=noninteractive
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a

  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install ca-certificates curl gnupg mysql-server sudo

  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
    | gpg --batch --yes --dearmor -o "$NODE_KEYRING"
  chmod 0644 "$NODE_KEYRING"

  printf 'deb [signed-by=%s] https://deb.nodesource.com/node_%s.x nodistro main\n' "$NODE_KEYRING" "$GHOST_NODE_MAJOR" \
    > "$NODE_SOURCE_LIST"
  chmod 0644 "$NODE_SOURCE_LIST"

  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install nodejs

  npm install ghost-cli@latest -g
}

mysql_admin() {
  if [[ -n "${MYSQL_ADMIN_PASSWORD:-}" ]]; then
    mysql -u "$MYSQL_ADMIN_USER" -p"$MYSQL_ADMIN_PASSWORD"
  else
    mysql -u "$MYSQL_ADMIN_USER"
  fi
}

setup_database() {
  log "Creating Ghost MySQL database and user"
  mysql_admin <<SQL
CREATE DATABASE IF NOT EXISTS \`$GHOST_DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$GHOST_DB_USER'@'localhost' IDENTIFIED BY '$GHOST_DB_PASSWORD';
ALTER USER '$GHOST_DB_USER'@'localhost' IDENTIFIED BY '$GHOST_DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$GHOST_DB_NAME\`.* TO '$GHOST_DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
}

ensure_install_dir() {
  log "Preparing Ghost install directory: $GHOST_INSTALL_DIR"
  mkdir -p "$GHOST_INSTALL_DIR"
  chown "$GHOST_SYSTEM_USER:$GHOST_SYSTEM_USER" "$GHOST_INSTALL_DIR"
  chmod 775 "$GHOST_INSTALL_DIR"
}

restart_ghost() {
  sudo -H -u "$GHOST_SYSTEM_USER" env GHOST_INSTALL_DIR="$GHOST_INSTALL_DIR" bash -lc 'cd "$GHOST_INSTALL_DIR" && (ghost restart || ghost start)'
}

install_or_start_ghost() {
  if [[ -d "$GHOST_INSTALL_DIR/current" || -f "$GHOST_INSTALL_DIR/config.production.json" ]]; then
    log "Existing Ghost install detected, skipping install"
    restart_ghost
    return
  fi

  log "Installing Ghost at $GHOST_INSTALL_DIR"
  sudo -H -u "$GHOST_SYSTEM_USER" env \
    GHOST_INSTALL_DIR="$GHOST_INSTALL_DIR" \
    GHOST_URL="$GHOST_URL" \
    GHOST_PORT="$GHOST_PORT" \
    GHOST_BIND_IP="$GHOST_BIND_IP" \
    GHOST_DB_USER="$GHOST_DB_USER" \
    GHOST_DB_PASSWORD="$GHOST_DB_PASSWORD" \
    GHOST_DB_NAME="$GHOST_DB_NAME" \
    bash -lc '
    cd "$GHOST_INSTALL_DIR"
    ghost install \
      --no-prompt \
      --url "$GHOST_URL" \
      --port "$GHOST_PORT" \
      --ip "$GHOST_BIND_IP" \
      --db mysql \
      --dbhost localhost \
      --dbuser "$GHOST_DB_USER" \
      --dbpass "$GHOST_DB_PASSWORD" \
      --dbname "$GHOST_DB_NAME" \
      --no-setup-mysql \
      --no-setup-nginx \
      --no-setup-ssl
  '
}

configure_ghost_security() {
  local config_file="$GHOST_INSTALL_DIR/config.production.json"
  [[ -f "$config_file" ]] || fail "Ghost production config is missing: $config_file"

  log "Setting Ghost security.staffDeviceVerification=$GHOST_STAFF_DEVICE_VERIFICATION"
  GHOST_STAFF_DEVICE_VERIFICATION="$GHOST_STAFF_DEVICE_VERIFICATION" node - "$config_file" <<'NODE'
const fs = require('fs');

const configPath = process.argv[2];
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const enabled = process.env.GHOST_STAFF_DEVICE_VERIFICATION === 'true';

if (!config.security || typeof config.security !== 'object' || Array.isArray(config.security)) {
  config.security = {};
}

config.security.staffDeviceVerification = enabled;
fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
NODE

  restart_ghost
}

managed_caddy_block() {
  local host="$1"
  cat <<EOF
$CADDY_MANAGED_PREFIX $host
$host {
    encode zstd gzip
    reverse_proxy ${GHOST_BIND_IP}:${GHOST_PORT}
}
$CADDY_MANAGED_SUFFIX $host
EOF
}

replace_managed_caddy_block() {
  local host="$1"
  local tmp_file block_file
  tmp_file="$(mktemp)"
  block_file="$(mktemp)"
  managed_caddy_block "$host" > "$block_file"

  awk -v begin="$CADDY_MANAGED_PREFIX $host" -v end="$CADDY_MANAGED_SUFFIX $host" -v block_file="$block_file" '
    $0 == begin {
      while ((getline line < block_file) > 0) print line
      close(block_file)
      skip = 1
      next
    }
    skip && $0 == end {
      skip = 0
      next
    }
    !skip { print }
  ' "$CADDYFILE" > "$tmp_file"

  cp "$tmp_file" "$CADDYFILE"
  rm -f "$tmp_file" "$block_file"
}

remove_caddy_block_for_host() {
  local host="$1"
  local tmp_file
  tmp_file="$(mktemp)"

  awk -v host="$host" '
    function count_char(value, char, i, total) {
      total = 0
      for (i = 1; i <= length(value); i++) {
        if (substr(value, i, 1) == char) total++
      }
      return total
    }
    {
      original = $0
      line = $0
      gsub(/^[ \t]+|[ \t]+$/, "", line)

      if (!skip && line ~ /\{$/) {
        labels = line
        sub(/[ \t]*\{$/, "", labels)
        gsub(/[ \t]/, "", labels)
        n = split(labels, parts, ",")
        for (i = 1; i <= n; i++) {
          if (parts[i] == host) {
            skip = 1
            depth = count_char(original, "{") - count_char(original, "}")
            if (depth <= 0) skip = 0
            next
          }
        }
      }

      if (skip) {
        depth += count_char(original, "{") - count_char(original, "}")
        if (depth <= 0) skip = 0
        next
      }

      if (!skip) print original
    }
  ' "$CADDYFILE" > "$tmp_file"

  cp "$tmp_file" "$CADDYFILE"
  rm -f "$tmp_file"
}

configure_caddy() {
  [[ "$GHOST_CONFIGURE_CADDY" == "true" ]] || {
    log "Skipping Caddy configuration because GHOST_CONFIGURE_CADDY=false"
    return
  }
  [[ "${GHOST_CADDY_ALREADY_CONFIGURED:-false}" != "true" ]] || return 0

  local host
  local backup_file=""
  host="$(ghost_host)"
  log "Configuring Caddy for $host -> ${GHOST_BIND_IP}:${GHOST_PORT}"

  install -d -m 0755 "$(dirname -- "$CADDYFILE")"
  if [[ -f "$CADDYFILE" ]]; then
    backup_file="${CADDYFILE}.bak.$(date +%s)"
    cp "$CADDYFILE" "$backup_file"
  else
    touch "$CADDYFILE"
  fi

  if grep -Fq "$CADDY_MANAGED_PREFIX $host" "$CADDYFILE"; then
    replace_managed_caddy_block "$host"
  else
    if [[ "${GHOST_CADDY_REPLACE_EXISTING_BLOCK:-false}" == "true" ]]; then
      remove_caddy_block_for_host "$host"
    fi
    managed_caddy_block "$host" | tee -a "$CADDYFILE" >/dev/null
  fi

  if ! caddy validate --config "$CADDYFILE"; then
    if [[ -n "$backup_file" ]]; then
      cp "$backup_file" "$CADDYFILE"
      fail "Caddy validation failed. Restored backup: $backup_file"
    fi
    rm -f "$CADDYFILE"
    fail "Caddy validation failed. Removed newly created Caddyfile."
  fi

  systemctl reload caddy 2>/dev/null || systemctl restart caddy
}

main() {
  require_root
  load_env
  require_vars
  validate_env
  preflight_caddy
  install_packages
  create_or_update_system_user
  setup_database
  ensure_install_dir
  install_or_start_ghost
  configure_ghost_security
  configure_caddy

  log "Done. Ghost URL: $GHOST_URL"
  log "Admin setup: ${GHOST_URL%/}/ghost"
}

main "$@"
