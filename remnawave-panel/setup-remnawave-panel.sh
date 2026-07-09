#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
ENV_FILE="${ENV_FILE:-}"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_SOURCE_LIST="/etc/apt/sources.list.d/docker.list"
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts remnawave-panel"
CADDY_MANAGED_SUFFIX="# END ubuntu-scripts remnawave-panel"
PANEL_COMPOSE_URL="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml"
PANEL_ENV_URL="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample"

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
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/remnawave-panel && bash setup-remnawave-panel.sh"; }
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

  fail "Environment file not found. Copy remnawave-panel/env.example to remnawave-panel/.env or run: cd remnawave-panel && cp env.example .env"
}

set_panel_paths() {
  REMNAWAVE_PANEL_INSTALL_DIR="${REMNAWAVE_PANEL_INSTALL_DIR:-/opt/remnawave}"
  PANEL_DIR="$REMNAWAVE_PANEL_INSTALL_DIR"
  COMPOSE_FILE="$PANEL_DIR/docker-compose.yml"
  DEPLOY_ENV_FILE="$PANEL_DIR/.env"
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

  set_panel_paths
  PANEL_DOMAIN="$(strip_protocol "${PANEL_DOMAIN:-}")"
  SUBSCRIPTION_PAGE_DOMAIN="$(strip_protocol "${SUBSCRIPTION_PAGE_DOMAIN:-}")"
  REMNAWAVE_PANEL_BIND_IP="${REMNAWAVE_PANEL_BIND_IP:-127.0.0.1}"
  REMNAWAVE_PANEL_PORT="${REMNAWAVE_PANEL_PORT:-3000}"
  REMNAWAVE_METRICS_PORT="${REMNAWAVE_METRICS_PORT:-3001}"
  APP_PORT="${APP_PORT:-3000}"
  METRICS_PORT="${METRICS_PORT:-3001}"
  API_INSTANCES="${API_INSTANCES:-1}"
  IS_DOCS_ENABLED="${IS_DOCS_ENABLED:-false}"
  SWAGGER_PATH="${SWAGGER_PATH:-/docs}"
  SCALAR_PATH="${SCALAR_PATH:-/scalar}"
  METRICS_USER="${METRICS_USER:-admin}"
  POSTGRES_USER="${POSTGRES_USER:-postgres}"
  POSTGRES_DB="${POSTGRES_DB:-postgres}"
  CUSTOM_SUB_PREFIX="${CUSTOM_SUB_PREFIX:-}"
  REMNAWAVE_PANEL_CONFIGURE_CADDY="${REMNAWAVE_PANEL_CONFIGURE_CADDY:-true}"
  REMNAWAVE_PANEL_CADDY_OVERWRITE_DOMAIN="${REMNAWAVE_PANEL_CADDY_OVERWRITE_DOMAIN:-ask}"
  REMNAWAVE_PANEL_SYSTEM_USER="${REMNAWAVE_PANEL_SYSTEM_USER:-}"
  REMNAWAVE_PANEL_SYSTEM_PASSWORD="${REMNAWAVE_PANEL_SYSTEM_PASSWORD:-}"
  REMNAWAVE_PANEL_SYSTEM_SSH_PUB="${REMNAWAVE_PANEL_SYSTEM_SSH_PUB:-}"
  CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"

  if [[ -z "${SUB_PUBLIC_DOMAIN:-}" && -n "$SUBSCRIPTION_PAGE_DOMAIN" ]]; then
    SUB_PUBLIC_DOMAIN="$SUBSCRIPTION_PAGE_DOMAIN"
    if [[ -n "$CUSTOM_SUB_PREFIX" ]]; then
      SUB_PUBLIC_DOMAIN="$SUB_PUBLIC_DOMAIN/$CUSTOM_SUB_PREFIX"
    fi
  fi
  SUB_PUBLIC_DOMAIN="${SUB_PUBLIC_DOMAIN:-$PANEL_DOMAIN/api/sub}"
}

require_vars() {
  local missing=()
  for var in PANEL_DOMAIN; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  if (( ${#missing[@]} > 0 )); then
    fail "Missing required variables in $ENV_FILE: ${missing[*]}"
  fi
}

validate_port() {
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

validate_system_user_env() {
  [[ -z "$REMNAWAVE_PANEL_SYSTEM_USER" ]] && return
  [[ "$REMNAWAVE_PANEL_SYSTEM_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail "REMNAWAVE_PANEL_SYSTEM_USER must be a valid Linux user name"
  [[ "$REMNAWAVE_PANEL_SYSTEM_USER" != "root" ]] || fail "REMNAWAVE_PANEL_SYSTEM_USER must not be root"
  [[ "$REMNAWAVE_PANEL_SYSTEM_PASSWORD" != *:* ]] || fail "REMNAWAVE_PANEL_SYSTEM_PASSWORD must not contain a colon"
  [[ "$REMNAWAVE_PANEL_SYSTEM_PASSWORD" != *$'\n'* ]] || fail "REMNAWAVE_PANEL_SYSTEM_PASSWORD must not contain a newline"
}

validate_env() {
  [[ "$PANEL_DOMAIN" =~ ^[^/]+$ ]] || fail "PANEL_DOMAIN must be a domain without path"
  [[ "$REMNAWAVE_PANEL_BIND_IP" =~ ^[A-Za-z0-9_.:-]+$ ]] || fail "REMNAWAVE_PANEL_BIND_IP contains unsupported characters"
  validate_port REMNAWAVE_PANEL_PORT "$REMNAWAVE_PANEL_PORT"
  validate_port REMNAWAVE_METRICS_PORT "$REMNAWAVE_METRICS_PORT"
  validate_port APP_PORT "$APP_PORT"
  validate_port METRICS_PORT "$METRICS_PORT"
  validate_bool IS_DOCS_ENABLED "$IS_DOCS_ENABLED"
  validate_bool REMNAWAVE_PANEL_CONFIGURE_CADDY "$REMNAWAVE_PANEL_CONFIGURE_CADDY"
  [[ "$REMNAWAVE_PANEL_CADDY_OVERWRITE_DOMAIN" == "ask" || "$REMNAWAVE_PANEL_CADDY_OVERWRITE_DOMAIN" == "true" || "$REMNAWAVE_PANEL_CADDY_OVERWRITE_DOMAIN" == "false" ]] || fail "REMNAWAVE_PANEL_CADDY_OVERWRITE_DOMAIN must be ask, true, or false"
  validate_system_user_env
}

service_user_enabled() {
  [[ -n "${REMNAWAVE_PANEL_SYSTEM_USER:-}" ]]
}

service_user_home() {
  local home
  home="$(getent passwd "$REMNAWAVE_PANEL_SYSTEM_USER" | cut -d: -f6)"
  [[ -n "$home" ]] || home="/home/$REMNAWAVE_PANEL_SYSTEM_USER"
  printf '%s\n' "$home"
}

run_as_service_user() {
  if service_user_enabled; then
    runuser -u "$REMNAWAVE_PANEL_SYSTEM_USER" -- env HOME="$(service_user_home)" "$@"
  else
    "$@"
  fi
}

run_in_panel_dir() {
  if service_user_enabled; then
    runuser -u "$REMNAWAVE_PANEL_SYSTEM_USER" -- env HOME="$(service_user_home)" bash -c 'cd "$1" && shift && "$@"' _ "$PANEL_DIR" "$@"
  else
    (cd "$PANEL_DIR" && "$@")
  fi
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
          if (parts[i] == host || parts[i] == "https://" host) {
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

caddy_block_points_to_panel() {
  local block="$1"
  local upstream="${REMNAWAVE_PANEL_BIND_IP}:${REMNAWAVE_PANEL_PORT}"

  grep -Fq "reverse_proxy $upstream" <<< "$block" && return 0
  grep -Fq "reverse_proxy http://$upstream" <<< "$block" && return 0
  [[ "$REMNAWAVE_PANEL_BIND_IP" == "127.0.0.1" ]] && grep -Fq "reverse_proxy localhost:$REMNAWAVE_PANEL_PORT" <<< "$block" && return 0
  [[ "$REMNAWAVE_PANEL_BIND_IP" == "127.0.0.1" ]] && grep -Fq "reverse_proxy http://localhost:$REMNAWAVE_PANEL_PORT" <<< "$block" && return 0
  return 1
}

confirm_caddy_overwrite() {
  local host="$1"
  local answer

  case "$REMNAWAVE_PANEL_CADDY_OVERWRITE_DOMAIN" in
    true)
      log "Caddy domain $host is occupied and will be replaced because REMNAWAVE_PANEL_CADDY_OVERWRITE_DOMAIN=true"
      return 0
      ;;
    false)
      return 1
      ;;
  esac

  printf 'Caddy domain %s already exists and points somewhere else. Replace it with Remnawave Panel? [y/N] ' "$host"
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
  [[ "$REMNAWAVE_PANEL_CONFIGURE_CADDY" == "true" ]] || return 0
  require_cmd caddy

  local block begin_marker
  begin_marker="$CADDY_MANAGED_PREFIX $PANEL_DOMAIN"
  [[ -f "$CADDYFILE" ]] || return 0

  if grep -Fq "$begin_marker" "$CADDYFILE"; then
    log "Managed Caddy block already exists for $PANEL_DOMAIN and will be updated"
    return
  fi

  block="$(caddy_block_for_host "$PANEL_DOMAIN")"
  [[ -z "$block" ]] && return

  if caddy_block_points_to_panel "$block"; then
    log "Caddy already routes $PANEL_DOMAIN to Remnawave Panel upstream ${REMNAWAVE_PANEL_BIND_IP}:${REMNAWAVE_PANEL_PORT}; keeping existing block"
    REMNAWAVE_PANEL_CADDY_ALREADY_CONFIGURED=true
    return
  fi

  if confirm_caddy_overwrite "$PANEL_DOMAIN"; then
    log "Caddy block for $PANEL_DOMAIN will be replaced with Remnawave Panel reverse proxy"
    REMNAWAVE_PANEL_CADDY_REPLACE_EXISTING_BLOCK=true
    return
  fi

  fail "Caddyfile already contains an unmanaged block for $PANEL_DOMAIN. Setup stopped without replacing it."
}

install_base_packages() {
  log "Installing base packages required for Remnawave Panel"
  export DEBIAN_FRONTEND=noninteractive
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a

  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install ca-certificates curl gnupg openssl
}

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker and Docker Compose are already installed"
    systemctl enable --now docker
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

  systemctl enable --now docker
}

create_or_update_service_user() {
  service_user_enabled || return 0
  require_cmd runuser

  local ssh_dir auth_keys

  if id "$REMNAWAVE_PANEL_SYSTEM_USER" >/dev/null 2>&1; then
    log "Service user already exists: $REMNAWAVE_PANEL_SYSTEM_USER"
  else
    log "Creating service user: $REMNAWAVE_PANEL_SYSTEM_USER"
    adduser --disabled-password --gecos "" "$REMNAWAVE_PANEL_SYSTEM_USER"
  fi

  if [[ -n "$REMNAWAVE_PANEL_SYSTEM_PASSWORD" ]]; then
    log "Updating password for service user: $REMNAWAVE_PANEL_SYSTEM_USER"
    printf '%s:%s\n' "$REMNAWAVE_PANEL_SYSTEM_USER" "$REMNAWAVE_PANEL_SYSTEM_PASSWORD" | chpasswd
  fi

  getent group docker >/dev/null 2>&1 || groupadd docker
  usermod -aG docker "$REMNAWAVE_PANEL_SYSTEM_USER"

  if [[ -n "${REMNAWAVE_PANEL_SYSTEM_SSH_PUB:-}" ]]; then
    ssh_dir="$(service_user_home)/.ssh"
    auth_keys="$ssh_dir/authorized_keys"

    install -d -m 0700 "$ssh_dir"
    chown "$REMNAWAVE_PANEL_SYSTEM_USER:" "$ssh_dir"
    touch "$auth_keys"
    chmod 0600 "$auth_keys"
    chown "$REMNAWAVE_PANEL_SYSTEM_USER:" "$auth_keys"

    if ! grep -Fqx "$REMNAWAVE_PANEL_SYSTEM_SSH_PUB" "$auth_keys"; then
      log "Adding SSH public key for $REMNAWAVE_PANEL_SYSTEM_USER"
      printf '%s\n' "$REMNAWAVE_PANEL_SYSTEM_SSH_PUB" >> "$auth_keys"
      chown "$REMNAWAVE_PANEL_SYSTEM_USER:" "$auth_keys"
    else
      log "SSH public key is already present for $REMNAWAVE_PANEL_SYSTEM_USER"
    fi
  fi

  if ! run_as_service_user docker info >/dev/null 2>&1; then
    fail "Service user $REMNAWAVE_PANEL_SYSTEM_USER cannot access Docker. Check docker group membership and Docker socket permissions."
  fi
}

download_if_missing() {
  local url="$1"
  local target="$2"

  if [[ -f "$target" ]]; then
    log "Keeping existing file: $target"
    return
  fi

  log "Downloading $(basename "$target")"
  curl -fsSL "$url" -o "$target"
}

prepare_panel_files() {
  install -d -m 0755 "$PANEL_DIR"
  download_if_missing "$PANEL_COMPOSE_URL" "$COMPOSE_FILE"
  download_if_missing "$PANEL_ENV_URL" "$DEPLOY_ENV_FILE"
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[|&]/\\&/g'
}

set_env_value() {
  local key="$1"
  local value="$2"
  local file="$3"
  local escaped

  escaped="$(escape_sed_replacement "$value")"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

get_env_value() {
  local key="$1"
  local file="$2"

  [[ -f "$file" ]] || return 0
  grep -E "^${key}=" "$file" | head -n 1 | cut -d= -f2- || true
}

ensure_random_hex_if_placeholder() {
  local key="$1"
  local bytes="$2"
  local current

  current="$(get_env_value "$key" "$DEPLOY_ENV_FILE")"
  if [[ -z "$current" || "$current" == "change_me" || "$current" == "admin" ]]; then
    set_env_value "$key" "$(openssl rand -hex "$bytes")" "$DEPLOY_ENV_FILE"
    log "Generated value for $key"
  fi
}

configure_database_env() {
  local postgres_password

  postgres_password="$(get_env_value POSTGRES_PASSWORD "$DEPLOY_ENV_FILE")"
  if [[ -z "$postgres_password" || "$postgres_password" == "postgres" || "$postgres_password" == "change_me" ]]; then
    postgres_password="$(openssl rand -hex 24)"
    log "Generated a new Postgres password"
  else
    log "Keeping existing Postgres password"
  fi

  set_env_value POSTGRES_USER "$POSTGRES_USER" "$DEPLOY_ENV_FILE"
  set_env_value POSTGRES_PASSWORD "$postgres_password" "$DEPLOY_ENV_FILE"
  set_env_value POSTGRES_DB "$POSTGRES_DB" "$DEPLOY_ENV_FILE"
  set_env_value DATABASE_URL "\"postgresql://${POSTGRES_USER}:${postgres_password}@remnawave-db:5432/${POSTGRES_DB}\"" "$DEPLOY_ENV_FILE"
}

configure_panel_env() {
  set_env_value APP_PORT "$APP_PORT" "$DEPLOY_ENV_FILE"
  set_env_value METRICS_PORT "$METRICS_PORT" "$DEPLOY_ENV_FILE"
  set_env_value REMNAWAVE_PANEL_BIND_IP "$REMNAWAVE_PANEL_BIND_IP" "$DEPLOY_ENV_FILE"
  set_env_value REMNAWAVE_PANEL_PORT "$REMNAWAVE_PANEL_PORT" "$DEPLOY_ENV_FILE"
  set_env_value REMNAWAVE_METRICS_PORT "$REMNAWAVE_METRICS_PORT" "$DEPLOY_ENV_FILE"
  set_env_value API_INSTANCES "$API_INSTANCES" "$DEPLOY_ENV_FILE"
  set_env_value PANEL_DOMAIN "$PANEL_DOMAIN" "$DEPLOY_ENV_FILE"
  set_env_value FRONT_END_DOMAIN "$PANEL_DOMAIN" "$DEPLOY_ENV_FILE"
  set_env_value SUB_PUBLIC_DOMAIN "$SUB_PUBLIC_DOMAIN" "$DEPLOY_ENV_FILE"
  set_env_value IS_DOCS_ENABLED "$IS_DOCS_ENABLED" "$DEPLOY_ENV_FILE"
  set_env_value SWAGGER_PATH "$SWAGGER_PATH" "$DEPLOY_ENV_FILE"
  set_env_value SCALAR_PATH "$SCALAR_PATH" "$DEPLOY_ENV_FILE"
  set_env_value METRICS_USER "$METRICS_USER" "$DEPLOY_ENV_FILE"
}

patch_compose_ports() {
  sed -i \
    -e "s|127.0.0.1:3000:\${APP_PORT:-3000}|${REMNAWAVE_PANEL_BIND_IP}:${REMNAWAVE_PANEL_PORT}:\${APP_PORT:-3000}|g" \
    -e "s|127.0.0.1:3001:\${METRICS_PORT:-3001}|${REMNAWAVE_PANEL_BIND_IP}:${REMNAWAVE_METRICS_PORT}:\${METRICS_PORT:-3001}|g" \
    "$COMPOSE_FILE"

  grep -Fq "${REMNAWAVE_PANEL_BIND_IP}:${REMNAWAVE_PANEL_PORT}:\${APP_PORT:-3000}" "$COMPOSE_FILE" || fail "Could not patch panel port binding in $COMPOSE_FILE"
  grep -Fq "${REMNAWAVE_PANEL_BIND_IP}:${REMNAWAVE_METRICS_PORT}:\${METRICS_PORT:-3001}" "$COMPOSE_FILE" || fail "Could not patch metrics port binding in $COMPOSE_FILE"
}

chown_panel_dir_if_needed() {
  service_user_enabled || return 0
  chown -R "$REMNAWAVE_PANEL_SYSTEM_USER:" "$PANEL_DIR"
}

validate_compose() {
  log "Validating Remnawave Panel Docker Compose config"
  chown_panel_dir_if_needed
  run_in_panel_dir docker compose config >/dev/null
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

start_panel_stack() {
  log "Starting Remnawave Panel stack"
  chown_panel_dir_if_needed
  run_in_panel_dir docker compose up -d

  wait_for_container remnawave-db 120
  wait_for_container remnawave-redis 120
  wait_for_container remnawave 180
}

verify_health_endpoint() {
  log "Checking local health endpoint"
  curl -fsS "http://${REMNAWAVE_PANEL_BIND_IP}:${REMNAWAVE_METRICS_PORT}/health" >/dev/null
}

managed_caddy_block() {
  cat <<EOF
$CADDY_MANAGED_PREFIX $PANEL_DOMAIN
$PANEL_DOMAIN {
    encode zstd gzip
    reverse_proxy ${REMNAWAVE_PANEL_BIND_IP}:${REMNAWAVE_PANEL_PORT}
}
$CADDY_MANAGED_SUFFIX $PANEL_DOMAIN
EOF
}

replace_managed_caddy_block() {
  local tmp_file block_file
  tmp_file="$(mktemp)"
  block_file="$(mktemp)"
  managed_caddy_block > "$block_file"

  awk -v begin="$CADDY_MANAGED_PREFIX $PANEL_DOMAIN" -v end="$CADDY_MANAGED_SUFFIX $PANEL_DOMAIN" -v block_file="$block_file" '
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
          if (parts[i] == host || parts[i] == "https://" host) {
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
  [[ "$REMNAWAVE_PANEL_CONFIGURE_CADDY" == "true" ]] || {
    log "Skipping Caddy configuration because REMNAWAVE_PANEL_CONFIGURE_CADDY=false"
    return
  }
  [[ "${REMNAWAVE_PANEL_CADDY_ALREADY_CONFIGURED:-false}" != "true" ]] || return 0

  local backup_file=""
  log "Configuring Caddy for $PANEL_DOMAIN -> ${REMNAWAVE_PANEL_BIND_IP}:${REMNAWAVE_PANEL_PORT}"

  install -d -m 0755 "$(dirname -- "$CADDYFILE")"
  if [[ -f "$CADDYFILE" ]]; then
    backup_file="${CADDYFILE}.bak.$(date +%s)"
    cp "$CADDYFILE" "$backup_file"
  else
    touch "$CADDYFILE"
  fi

  if grep -Fq "$CADDY_MANAGED_PREFIX $PANEL_DOMAIN" "$CADDYFILE"; then
    replace_managed_caddy_block
  else
    if [[ "${REMNAWAVE_PANEL_CADDY_REPLACE_EXISTING_BLOCK:-false}" == "true" ]]; then
      remove_caddy_block_for_host "$PANEL_DOMAIN"
    fi
    managed_caddy_block | tee -a "$CADDYFILE" >/dev/null
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
  install_base_packages
  install_docker_if_missing
  create_or_update_service_user
  require_cmd curl
  require_cmd openssl
  require_cmd docker
  prepare_panel_files
  ensure_random_hex_if_placeholder JWT_AUTH_SECRET 64
  ensure_random_hex_if_placeholder JWT_API_TOKENS_SECRET 64
  ensure_random_hex_if_placeholder METRICS_PASS 64
  ensure_random_hex_if_placeholder WEBHOOK_SECRET_HEADER 32
  configure_database_env
  configure_panel_env
  patch_compose_ports
  validate_compose
  start_panel_stack
  configure_caddy
  verify_health_endpoint

  log "Remnawave Panel is deployed"
  log "Open https://$PANEL_DOMAIN in your browser and create the first super-admin account."
  log "Then create an API token in Remnawave Dashboard -> Settings -> API Tokens."
  log "After that, run: cd ~/ubuntu-scripts/remnawave-panel && bash setup-subscription-page.sh"
}

main "$@"
