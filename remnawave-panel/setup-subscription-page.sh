#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
ENV_FILE="${ENV_FILE:-}"
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts remnawave-subscription"
CADDY_MANAGED_SUFFIX="# END ubuntu-scripts remnawave-subscription"

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
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/remnawave-panel && bash setup-subscription-page.sh"; }
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

is_example_domain() {
  case "$1" in
    panel.example.com|sub.panel.example.com|example.com|*.example.com) return 0 ;;
    *) return 1 ;;
  esac
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
  SUBSCRIPTION_PAGE_BIND_IP="${SUBSCRIPTION_PAGE_BIND_IP:-127.0.0.1}"
  SUBSCRIPTION_PAGE_PORT="${SUBSCRIPTION_PAGE_PORT:-3010}"
  APP_PORT="${APP_PORT:-3000}"
  CUSTOM_SUB_PREFIX="${CUSTOM_SUB_PREFIX:-}"
  CADDY_AUTH_API_TOKEN="${CADDY_AUTH_API_TOKEN:-}"
  REMNAWAVE_PANEL_CONFIGURE_CADDY="${REMNAWAVE_PANEL_CONFIGURE_CADDY:-true}"
  REMNAWAVE_PANEL_CADDY_OVERWRITE_DOMAIN="${REMNAWAVE_PANEL_CADDY_OVERWRITE_DOMAIN:-ask}"
  REMNAWAVE_PANEL_SYSTEM_USER="${REMNAWAVE_PANEL_SYSTEM_USER:-}"
  REMNAWAVE_PANEL_SYSTEM_PASSWORD="${REMNAWAVE_PANEL_SYSTEM_PASSWORD:-}"
  REMNAWAVE_PANEL_SYSTEM_SSH_PUB="${REMNAWAVE_PANEL_SYSTEM_SSH_PUB:-}"
  CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"

  SUB_PUBLIC_DOMAIN="$SUBSCRIPTION_PAGE_DOMAIN"
  if [[ -n "$CUSTOM_SUB_PREFIX" ]]; then
    SUB_PUBLIC_DOMAIN="$SUB_PUBLIC_DOMAIN/$CUSTOM_SUB_PREFIX"
  fi
}

require_vars() {
  local missing=()
  for var in PANEL_DOMAIN SUBSCRIPTION_PAGE_DOMAIN REMNAWAVE_API_TOKEN; do
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
  is_example_domain "$PANEL_DOMAIN" && fail "PANEL_DOMAIN still contains an example hostname: $PANEL_DOMAIN"
  is_example_domain "$SUBSCRIPTION_PAGE_DOMAIN" && fail "SUBSCRIPTION_PAGE_DOMAIN still contains an example hostname: $SUBSCRIPTION_PAGE_DOMAIN"
  [[ "$PANEL_DOMAIN" =~ ^[^/]+$ ]] || fail "PANEL_DOMAIN must be a domain without path"
  [[ "$SUBSCRIPTION_PAGE_DOMAIN" =~ ^[^/]+$ ]] || fail "SUBSCRIPTION_PAGE_DOMAIN must be a domain without path"
  [[ "$PANEL_DOMAIN" != "$SUBSCRIPTION_PAGE_DOMAIN" ]] || fail "SUBSCRIPTION_PAGE_DOMAIN must be different from PANEL_DOMAIN"
  [[ "$SUBSCRIPTION_PAGE_BIND_IP" =~ ^[A-Za-z0-9_.:-]+$ ]] || fail "SUBSCRIPTION_PAGE_BIND_IP contains unsupported characters"
  validate_port SUBSCRIPTION_PAGE_PORT "$SUBSCRIPTION_PAGE_PORT"
  validate_port APP_PORT "$APP_PORT"
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

run_in_dir() {
  local dir="$1"
  shift
  if service_user_enabled; then
    runuser -u "$REMNAWAVE_PANEL_SYSTEM_USER" -- env HOME="$(service_user_home)" bash -c 'cd "$1" && shift && "$@"' _ "$dir" "$@"
  else
    (cd "$dir" && "$@")
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

caddy_block_points_to_subscription() {
  local block="$1"
  local upstream="${SUBSCRIPTION_PAGE_BIND_IP}:${SUBSCRIPTION_PAGE_PORT}"

  grep -Fq "reverse_proxy $upstream" <<< "$block" && return 0
  grep -Fq "reverse_proxy http://$upstream" <<< "$block" && return 0
  [[ "$SUBSCRIPTION_PAGE_BIND_IP" == "127.0.0.1" ]] && grep -Fq "reverse_proxy localhost:$SUBSCRIPTION_PAGE_PORT" <<< "$block" && return 0
  [[ "$SUBSCRIPTION_PAGE_BIND_IP" == "127.0.0.1" ]] && grep -Fq "reverse_proxy http://localhost:$SUBSCRIPTION_PAGE_PORT" <<< "$block" && return 0
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

  printf 'Caddy domain %s already exists and points somewhere else. Replace it with Remnawave Subscription Page? [y/N] ' "$host"
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
  begin_marker="$CADDY_MANAGED_PREFIX $SUBSCRIPTION_PAGE_DOMAIN"
  [[ -f "$CADDYFILE" ]] || return 0

  if grep -Fq "$begin_marker" "$CADDYFILE"; then
    log "Managed Caddy block already exists for $SUBSCRIPTION_PAGE_DOMAIN and will be updated"
    return
  fi

  block="$(caddy_block_for_host "$SUBSCRIPTION_PAGE_DOMAIN")"
  [[ -z "$block" ]] && return

  if caddy_block_points_to_subscription "$block"; then
    log "Caddy already routes $SUBSCRIPTION_PAGE_DOMAIN to subscription upstream ${SUBSCRIPTION_PAGE_BIND_IP}:${SUBSCRIPTION_PAGE_PORT}; keeping existing block"
    REMNAWAVE_SUBSCRIPTION_CADDY_ALREADY_CONFIGURED=true
    return
  fi

  if confirm_caddy_overwrite "$SUBSCRIPTION_PAGE_DOMAIN"; then
    log "Caddy block for $SUBSCRIPTION_PAGE_DOMAIN will be replaced with Remnawave Subscription Page reverse proxy"
    REMNAWAVE_SUBSCRIPTION_CADDY_REPLACE_EXISTING_BLOCK=true
    return
  fi

  fail "Caddyfile already contains an unmanaged block for $SUBSCRIPTION_PAGE_DOMAIN. Setup stopped without replacing it."
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

chown_panel_dir_if_needed() {
  service_user_enabled || return 0
  [[ -d "$PANEL_DIR" ]] || return 0
  chown -R "$REMNAWAVE_PANEL_SYSTEM_USER:" "$PANEL_DIR"
}

require_panel_setup() {
  [[ -f "$PANEL_COMPOSE_FILE" ]] || fail "Panel compose file not found: $PANEL_COMPOSE_FILE. Run setup-remnawave-panel.sh first."
  [[ -f "$PANEL_ENV_FILE" ]] || fail "Panel env file not found: $PANEL_ENV_FILE. Run setup-remnawave-panel.sh first."
}

install_base_packages() {
  log "Installing base packages required for Remnawave Subscription Page"
  export DEBIAN_FRONTEND=noninteractive
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a

  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install ca-certificates curl
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

configure_panel_sub_public_domain() {
  log "Updating SUB_PUBLIC_DOMAIN in $PANEL_ENV_FILE"
  set_env_value SUB_PUBLIC_DOMAIN "$SUB_PUBLIC_DOMAIN" "$PANEL_ENV_FILE"
}

prepare_subscription_files() {
  log "Writing bundled subscription page files"
  install -d -m 0755 "$SUBSCRIPTION_DIR"

  cat > "$SUBSCRIPTION_COMPOSE_FILE" <<YAML
services:
  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    env_file:
      - .env
    ports:
      - "${SUBSCRIPTION_PAGE_BIND_IP}:${SUBSCRIPTION_PAGE_PORT}:${SUBSCRIPTION_PAGE_PORT}"
    networks:
      - remnawave-network

networks:
  remnawave-network:
    external: true
YAML

  cat > "$SUBSCRIPTION_ENV_FILE" <<EOF
APP_PORT=${SUBSCRIPTION_PAGE_PORT}
REMNAWAVE_PANEL_URL=http://remnawave:${APP_PORT}
REMNAWAVE_API_TOKEN=${REMNAWAVE_API_TOKEN}
CUSTOM_SUB_PREFIX=${CUSTOM_SUB_PREFIX}
CADDY_AUTH_API_TOKEN=${CADDY_AUTH_API_TOKEN}
EOF

  chown_panel_dir_if_needed
}

validate_compose() {
  log "Validating subscription page Docker Compose config"
  run_in_dir "$SUBSCRIPTION_DIR" docker compose config >/dev/null
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

restart_panel_container() {
  log "Recreating Remnawave panel container to apply SUB_PUBLIC_DOMAIN"
  chown_panel_dir_if_needed
  run_in_dir "$PANEL_DIR" docker compose up -d remnawave-db remnawave-redis
  run_in_dir "$PANEL_DIR" docker compose up -d --force-recreate remnawave

  wait_for_container remnawave-db 120
  wait_for_container remnawave-redis 120
  wait_for_container remnawave 180
}

start_subscription_stack() {
  log "Starting bundled subscription page container"
  chown_panel_dir_if_needed
  run_in_dir "$SUBSCRIPTION_DIR" docker compose up -d
  wait_for_container remnawave-subscription-page 120
}

managed_caddy_block() {
  cat <<EOF
$CADDY_MANAGED_PREFIX $SUBSCRIPTION_PAGE_DOMAIN
$SUBSCRIPTION_PAGE_DOMAIN {
    encode zstd gzip
    reverse_proxy ${SUBSCRIPTION_PAGE_BIND_IP}:${SUBSCRIPTION_PAGE_PORT}
}
$CADDY_MANAGED_SUFFIX $SUBSCRIPTION_PAGE_DOMAIN
EOF
}

replace_managed_caddy_block() {
  local tmp_file block_file
  tmp_file="$(mktemp)"
  block_file="$(mktemp)"
  managed_caddy_block > "$block_file"

  awk -v begin="$CADDY_MANAGED_PREFIX $SUBSCRIPTION_PAGE_DOMAIN" -v end="$CADDY_MANAGED_SUFFIX $SUBSCRIPTION_PAGE_DOMAIN" -v block_file="$block_file" '
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

remove_stale_managed_caddy_blocks() {
  local tmp_file
  tmp_file="$(mktemp)"

  awk -v prefix="$CADDY_MANAGED_PREFIX " -v suffix="$CADDY_MANAGED_SUFFIX " -v current="$SUBSCRIPTION_PAGE_DOMAIN" '
    index($0, prefix) == 1 {
      host = substr($0, length(prefix) + 1)
      if (host != current) {
        skip = 1
        next
      }
    }
    skip && index($0, suffix) == 1 {
      skip = 0
      next
    }
    !skip { print }
  ' "$CADDYFILE" > "$tmp_file"

  cp "$tmp_file" "$CADDYFILE"
  rm -f "$tmp_file"
}

configure_caddy() {
  [[ "$REMNAWAVE_PANEL_CONFIGURE_CADDY" == "true" ]] || {
    log "Skipping Caddy configuration because REMNAWAVE_PANEL_CONFIGURE_CADDY=false"
    return
  }
  [[ "${REMNAWAVE_SUBSCRIPTION_CADDY_ALREADY_CONFIGURED:-false}" != "true" ]] || return 0

  local backup_file=""
  log "Configuring Caddy for $SUBSCRIPTION_PAGE_DOMAIN -> ${SUBSCRIPTION_PAGE_BIND_IP}:${SUBSCRIPTION_PAGE_PORT}"

  install -d -m 0755 "$(dirname -- "$CADDYFILE")"
  if [[ -f "$CADDYFILE" ]]; then
    backup_file="${CADDYFILE}.bak.$(date +%s)"
    cp "$CADDYFILE" "$backup_file"
  else
    touch "$CADDYFILE"
  fi

  # A previous run may have installed a managed block for an old or example
  # hostname. Keep only the block matching the currently configured domain.
  remove_stale_managed_caddy_blocks

  if grep -Fq "$CADDY_MANAGED_PREFIX $SUBSCRIPTION_PAGE_DOMAIN" "$CADDYFILE"; then
    replace_managed_caddy_block
  else
    if [[ "${REMNAWAVE_SUBSCRIPTION_CADDY_REPLACE_EXISTING_BLOCK:-false}" == "true" ]]; then
      remove_caddy_block_for_host "$SUBSCRIPTION_PAGE_DOMAIN"
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

verify_local_subscription_endpoint() {
  local status_code

  status_code="$(curl -sS -o /dev/null -w '%{http_code}' "http://${SUBSCRIPTION_PAGE_BIND_IP}:${SUBSCRIPTION_PAGE_PORT}/" || true)"
  if [[ "$status_code" =~ ^[234][0-9][0-9]$ ]]; then
    log "Local subscription page endpoint is reachable with HTTP status $status_code"
  else
    fail "Subscription page endpoint on ${SUBSCRIPTION_PAGE_BIND_IP}:${SUBSCRIPTION_PAGE_PORT} is not reachable"
  fi
}

main() {
  require_root
  load_env
  require_vars
  validate_env
  preflight_caddy
  install_base_packages
  require_cmd curl
  require_cmd docker
  create_or_update_service_user
  require_panel_setup
  configure_panel_sub_public_domain
  prepare_subscription_files
  validate_compose
  restart_panel_container
  start_subscription_stack
  configure_caddy
  verify_local_subscription_endpoint

  log "Bundled subscription page is deployed"
  log "Subscription page domain: https://$SUBSCRIPTION_PAGE_DOMAIN"
  log "Subscription public domain in panel env: $SUB_PUBLIC_DOMAIN"
}

main "$@"
