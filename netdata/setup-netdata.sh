#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_SOURCE_LIST="/etc/apt/sources.list.d/docker.list"
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts netdata"
CADDY_MANAGED_SUFFIX="# END ubuntu-scripts netdata"

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
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/netdata && bash setup-netdata.sh"; }
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

  fail "Environment file not found. Copy netdata/env.example to netdata/.env or run: cd netdata && cp env.example .env"
}

reset_env_vars() {
  NETDATA_URL=""
  NETDATA_INSTALL_DIR=""
  NETDATA_BIND_IP=""
  NETDATA_PORT=""
  NETDATA_IMAGE=""
  NETDATA_CONTAINER_NAME=""
  NETDATA_HOSTNAME=""
  NETDATA_DISABLE_TELEMETRY=""
  NETDATA_SYSTEM_USER=""
  NETDATA_SYSTEM_PASSWORD=""
  NETDATA_SYSTEM_SSH_PUB=""
  NETDATA_CONFIGURE_CADDY=""
  NETDATA_BASIC_AUTH_ENABLED=""
  NETDATA_BASIC_AUTH_USER=""
  NETDATA_BASIC_AUTH_PASSWORD=""
  NETDATA_CADDY_OVERWRITE_DOMAIN=""
  CADDYFILE=""
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

  NETDATA_INSTALL_DIR="${NETDATA_INSTALL_DIR:-/opt/netdata}"
  NETDATA_BIND_IP="${NETDATA_BIND_IP:-127.0.0.1}"
  NETDATA_PORT="${NETDATA_PORT:-19999}"
  NETDATA_IMAGE="${NETDATA_IMAGE:-netdata/netdata:stable}"
  NETDATA_CONTAINER_NAME="${NETDATA_CONTAINER_NAME:-netdata}"
  NETDATA_HOSTNAME="${NETDATA_HOSTNAME:-server-monitor}"
  NETDATA_DISABLE_TELEMETRY="${NETDATA_DISABLE_TELEMETRY:-true}"
  NETDATA_SYSTEM_USER="${NETDATA_SYSTEM_USER:-}"
  NETDATA_SYSTEM_PASSWORD="${NETDATA_SYSTEM_PASSWORD:-}"
  NETDATA_SYSTEM_SSH_PUB="${NETDATA_SYSTEM_SSH_PUB:-}"
  NETDATA_CONFIGURE_CADDY="${NETDATA_CONFIGURE_CADDY:-true}"
  NETDATA_BASIC_AUTH_ENABLED="${NETDATA_BASIC_AUTH_ENABLED:-true}"
  NETDATA_BASIC_AUTH_USER="${NETDATA_BASIC_AUTH_USER:-admin}"
  NETDATA_CADDY_OVERWRITE_DOMAIN="${NETDATA_CADDY_OVERWRITE_DOMAIN:-ask}"
  CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
}

require_vars() {
  local missing=()
  for var in NETDATA_URL; do
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

validate_system_user_env() {
  [[ -z "$NETDATA_SYSTEM_USER" ]] && return
  [[ "$NETDATA_SYSTEM_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail "NETDATA_SYSTEM_USER must be a valid Linux user name"
  [[ "$NETDATA_SYSTEM_USER" != "root" ]] || fail "NETDATA_SYSTEM_USER must not be root"
  [[ "$NETDATA_SYSTEM_PASSWORD" != *:* ]] || fail "NETDATA_SYSTEM_PASSWORD must not contain a colon"
  [[ "$NETDATA_SYSTEM_PASSWORD" != *$'\n'* ]] || fail "NETDATA_SYSTEM_PASSWORD must not contain a newline"
}

validate_env() {
  [[ "$NETDATA_URL" =~ ^https?://[^/]+/?$ ]] || fail "NETDATA_URL must be a full site URL, for example https://server.example.com"
  [[ "$NETDATA_PORT" =~ ^[0-9]+$ ]] || fail "NETDATA_PORT must be numeric"
  (( NETDATA_PORT >= 1024 && NETDATA_PORT <= 65535 )) || fail "NETDATA_PORT must be between 1024 and 65535"
  [[ "$NETDATA_BIND_IP" =~ ^[A-Za-z0-9_.:-]+$ ]] || fail "NETDATA_BIND_IP contains unsupported characters"
  validate_bool "$NETDATA_DISABLE_TELEMETRY"
  validate_bool "$NETDATA_CONFIGURE_CADDY"
  validate_bool "$NETDATA_BASIC_AUTH_ENABLED"
  [[ "$NETDATA_CADDY_OVERWRITE_DOMAIN" == "ask" || "$NETDATA_CADDY_OVERWRITE_DOMAIN" == "true" || "$NETDATA_CADDY_OVERWRITE_DOMAIN" == "false" ]] || fail "NETDATA_CADDY_OVERWRITE_DOMAIN must be ask, true, or false"
  if [[ "$NETDATA_BASIC_AUTH_ENABLED" == "true" ]]; then
    [[ -n "$NETDATA_BASIC_AUTH_USER" ]] || fail "NETDATA_BASIC_AUTH_USER is required when NETDATA_BASIC_AUTH_ENABLED=true"
    [[ -n "$NETDATA_BASIC_AUTH_PASSWORD" ]] || fail "NETDATA_BASIC_AUTH_PASSWORD is required when NETDATA_BASIC_AUTH_ENABLED=true"
    [[ "$NETDATA_BASIC_AUTH_PASSWORD" != "change_me_netdata_password" ]] || fail "Change NETDATA_BASIC_AUTH_PASSWORD in $ENV_FILE before exposing Netdata"
  fi
  validate_system_user_env
}

service_user_enabled() {
  [[ -n "${NETDATA_SYSTEM_USER:-}" ]]
}

service_user_home() {
  local home
  home="$(getent passwd "$NETDATA_SYSTEM_USER" | cut -d: -f6)"
  [[ -n "$home" ]] || home="/home/$NETDATA_SYSTEM_USER"
  printf '%s\n' "$home"
}

run_as_service_user() {
  if service_user_enabled; then
    runuser -u "$NETDATA_SYSTEM_USER" -- env HOME="$(service_user_home)" "$@"
  else
    "$@"
  fi
}

netdata_host() {
  local value="$NETDATA_URL"
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

caddy_block_points_to_netdata() {
  local block="$1"
  local upstream="${NETDATA_BIND_IP}:${NETDATA_PORT}"

  grep -Fq "reverse_proxy $upstream" <<< "$block" && return 0
  grep -Fq "reverse_proxy http://$upstream" <<< "$block" && return 0
  [[ "$NETDATA_BIND_IP" == "127.0.0.1" ]] && grep -Fq "reverse_proxy localhost:$NETDATA_PORT" <<< "$block" && return 0
  [[ "$NETDATA_BIND_IP" == "127.0.0.1" ]] && grep -Fq "reverse_proxy http://localhost:$NETDATA_PORT" <<< "$block" && return 0
  return 1
}

confirm_caddy_overwrite() {
  local host="$1"
  local answer

  case "$NETDATA_CADDY_OVERWRITE_DOMAIN" in
    true)
      log "Caddy domain $host is occupied and will be replaced because NETDATA_CADDY_OVERWRITE_DOMAIN=true"
      return 0
      ;;
    false)
      return 1
      ;;
  esac

  printf 'Caddy domain %s already exists and points somewhere else. Replace it with Netdata? [y/N] ' "$host"
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
  [[ "$NETDATA_CONFIGURE_CADDY" == "true" ]] || return

  require_cmd caddy
  local host block begin_marker
  host="$(netdata_host)"
  begin_marker="$CADDY_MANAGED_PREFIX $host"

  [[ -f "$CADDYFILE" ]] || return

  if grep -Fq "$begin_marker" "$CADDYFILE"; then
    log "Managed Caddy block already exists for $host and will be updated"
    return
  fi

  block="$(caddy_block_for_host "$host")"
  [[ -z "$block" ]] && return

  if caddy_block_points_to_netdata "$block"; then
    log "Caddy already routes $host to Netdata upstream ${NETDATA_BIND_IP}:${NETDATA_PORT}; keeping existing block"
    NETDATA_CADDY_ALREADY_CONFIGURED=true
    return
  fi

  if confirm_caddy_overwrite "$host"; then
    log "Caddy block for $host will be replaced with Netdata reverse proxy"
    NETDATA_CADDY_REPLACE_EXISTING_BLOCK=true
    return
  fi

  fail "Caddyfile already contains an unmanaged block for $host. Setup stopped without replacing it."
}

install_docker() {
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
  service_user_enabled || return
  require_cmd runuser

  local ssh_dir auth_keys

  if id "$NETDATA_SYSTEM_USER" >/dev/null 2>&1; then
    log "Service user already exists: $NETDATA_SYSTEM_USER"
  else
    log "Creating service user: $NETDATA_SYSTEM_USER"
    adduser --disabled-password --gecos "" "$NETDATA_SYSTEM_USER"
  fi

  if [[ -n "$NETDATA_SYSTEM_PASSWORD" ]]; then
    log "Updating password for service user: $NETDATA_SYSTEM_USER"
    printf '%s:%s\n' "$NETDATA_SYSTEM_USER" "$NETDATA_SYSTEM_PASSWORD" | chpasswd
  fi

  getent group docker >/dev/null 2>&1 || groupadd docker
  usermod -aG docker "$NETDATA_SYSTEM_USER"

  if [[ -n "${NETDATA_SYSTEM_SSH_PUB:-}" ]]; then
    ssh_dir="$(service_user_home)/.ssh"
    auth_keys="$ssh_dir/authorized_keys"

    install -d -m 0700 "$ssh_dir"
    chown "$NETDATA_SYSTEM_USER:" "$ssh_dir"
    touch "$auth_keys"
    chmod 0600 "$auth_keys"
    chown "$NETDATA_SYSTEM_USER:" "$auth_keys"

    if ! grep -Fqx "$NETDATA_SYSTEM_SSH_PUB" "$auth_keys"; then
      log "Adding SSH public key for $NETDATA_SYSTEM_USER"
      printf '%s\n' "$NETDATA_SYSTEM_SSH_PUB" >> "$auth_keys"
      chown "$NETDATA_SYSTEM_USER:" "$auth_keys"
    else
      log "SSH public key is already present for $NETDATA_SYSTEM_USER"
    fi
  fi

  if ! run_as_service_user docker info >/dev/null 2>&1; then
    fail "Service user $NETDATA_SYSTEM_USER cannot access Docker. Check docker group membership and Docker socket permissions."
  fi
}

write_compose_file() {
  log "Writing Docker Compose file: $NETDATA_INSTALL_DIR/docker-compose.yml"
  install -d -m 0755 "$NETDATA_INSTALL_DIR"

  local do_not_track="0"
  [[ "$NETDATA_DISABLE_TELEMETRY" == "true" ]] && do_not_track="1"

  cat > "$NETDATA_INSTALL_DIR/docker-compose.yml" <<EOF
services:
  netdata:
    image: $NETDATA_IMAGE
    container_name: $NETDATA_CONTAINER_NAME
    hostname: $NETDATA_HOSTNAME
    pid: host
    restart: unless-stopped
    ports:
      - "$NETDATA_BIND_IP:$NETDATA_PORT:19999"
    cap_add:
      - SYS_PTRACE
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    environment:
      DO_NOT_TRACK: "$do_not_track"
    volumes:
      - netdata-config:/etc/netdata
      - netdata-lib:/var/lib/netdata
      - netdata-cache:/var/cache/netdata
      - /:/host/root:ro,rslave
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /etc/localtime:/etc/localtime:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
      - /var/log:/host/var/log:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro

volumes:
  netdata-config:
  netdata-lib:
  netdata-cache:
EOF

  if service_user_enabled; then
    chown -R "$NETDATA_SYSTEM_USER:" "$NETDATA_INSTALL_DIR"
  fi
}

start_netdata() {
  log "Starting Netdata"
  run_as_service_user docker compose -f "$NETDATA_INSTALL_DIR/docker-compose.yml" pull
  run_as_service_user docker compose -f "$NETDATA_INSTALL_DIR/docker-compose.yml" up -d
}

caddy_basic_auth_block() {
  [[ "$NETDATA_BASIC_AUTH_ENABLED" == "true" ]] || return 0

  local password_hash
  password_hash="$(caddy hash-password --plaintext "$NETDATA_BASIC_AUTH_PASSWORD")"
  cat <<EOF
    basic_auth {
        $NETDATA_BASIC_AUTH_USER $password_hash
    }
EOF
}

managed_caddy_block() {
  local host="$1"
  local auth_block
  auth_block="$(caddy_basic_auth_block)"

  cat <<EOF
$CADDY_MANAGED_PREFIX $host
$host {
    encode zstd gzip
$auth_block
    reverse_proxy ${NETDATA_BIND_IP}:${NETDATA_PORT}
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
  [[ "$NETDATA_CONFIGURE_CADDY" == "true" ]] || {
    log "Skipping Caddy configuration because NETDATA_CONFIGURE_CADDY=false"
    return
  }
  [[ "${NETDATA_CADDY_ALREADY_CONFIGURED:-false}" != "true" ]] || return

  local host
  local backup_file=""
  host="$(netdata_host)"
  log "Configuring Caddy for $host -> ${NETDATA_BIND_IP}:${NETDATA_PORT}"

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
    if [[ "${NETDATA_CADDY_REPLACE_EXISTING_BLOCK:-false}" == "true" ]]; then
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
  install_docker
  create_or_update_service_user
  write_compose_file
  start_netdata
  configure_caddy

  log "Done. Netdata URL: $NETDATA_URL"
  [[ "$NETDATA_BASIC_AUTH_ENABLED" == "true" ]] && log "Caddy basic auth user: $NETDATA_BASIC_AUTH_USER"
}

main "$@"
