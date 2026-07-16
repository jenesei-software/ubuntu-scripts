#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
COOLIFY_DATA_DIR="/data/coolify"
ERROR_COUNT=0
WARNING_COUNT=0

LOG_COLOR='\033[1;36m'
LOG_RESET='\033[0m'

timestamp() { date '+%F %T'; }
log_line() {
  local level="$1"
  shift
  printf '%b[%s] %-7s%b %s\n' "$LOG_COLOR" "$(timestamp)" "$level" "$LOG_RESET" "$*"
}

ok() { log_line "OK" "$*"; }
info() { log_line "INFO" "$*"; }
warn() { WARNING_COUNT=$((WARNING_COUNT + 1)); log_line "WARN" "$*"; }
err() { ERROR_COUNT=$((ERROR_COUNT + 1)); log_line "ERROR" "$*"; }
section() { echo; log_line "SECTION" "$*"; }
fail() { log_line "ERROR" "$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/coolify && bash check-setup.sh"; }

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
  elif [[ -f "$SCRIPT_DIR/.env" ]]; then
    ENV_FILE="$SCRIPT_DIR/.env"
  else
    ENV_FILE=""
  fi
}

load_env() {
  resolve_env_file
  COOLIFY_CONFIGURE_UFW="true"

  if [[ -z "$ENV_FILE" ]]; then
    warn "Environment file not found; using diagnostic defaults"
    return
  fi
  [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"

  info "Loading environment from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  COOLIFY_CONFIGURE_UFW="${COOLIFY_CONFIGURE_UFW:-true}"
}

check_system() {
  local available_kb
  local architecture
  local cpu_count
  local memory_kb

  section "System"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
      ok "Operating system: ${PRETTY_NAME:-Ubuntu 24.04}"
    else
      err "Expected Ubuntu 24.04, detected ${PRETTY_NAME:-unknown}"
    fi
  else
    err "/etc/os-release is missing"
  fi

  architecture="$(uname -m)"
  if [[ "$architecture" == "x86_64" || "$architecture" == "aarch64" ]]; then
    ok "Architecture: $architecture"
  else
    err "Unsupported architecture: $architecture"
  fi

  cpu_count="$(nproc)"
  memory_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  available_kb="$(df -Pk / | awk 'NR == 2 {print $4}')"
  if (( cpu_count >= 2 )); then
    ok "CPU cores: $cpu_count"
  else
    err "CPU cores: $cpu_count; need at least 2"
  fi
  if (( memory_kb >= 2 * 1024 * 1024 )); then
    ok "RAM: $((memory_kb / 1024 / 1024)) GB"
  else
    err "RAM: $((memory_kb / 1024 / 1024)) GB; need at least 2 GB"
  fi
  if (( available_kb >= 5 * 1024 * 1024 )); then
    ok "Free disk space: $((available_kb / 1024 / 1024)) GB"
  else
    err "Free disk space: $((available_kb / 1024 / 1024)) GB; keep at least 5 GB free for operation and upgrades"
  fi
}

check_commands() {
  local command

  section "Commands"
  for command in curl docker ssh sshd ss; do
    if command -v "$command" >/dev/null 2>&1; then
      ok "Command is available: $command"
    else
      err "Command not found: $command"
    fi
  done

  if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
    err "Docker installed through Snap is unsupported by Coolify"
  fi
}

check_docker() {
  local major_version

  section "Docker"
  command -v docker >/dev/null 2>&1 || { err "Docker is not installed"; return; }
  info "Docker client: $(docker --version 2>/dev/null || printf 'unknown')"

  if docker info >/dev/null 2>&1; then
    ok "Docker daemon is reachable"
  else
    err "Docker daemon is not reachable"
    return
  fi

  major_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1)"
  if [[ "$major_version" =~ ^[0-9]+$ ]] && (( major_version >= 24 )); then
    ok "Docker server version is supported: $(docker version --format '{{.Server.Version}}')"
  else
    err "Coolify requires Docker 24 or newer; detected ${major_version:-unknown}"
  fi

  if docker compose version >/dev/null 2>&1; then
    ok "Docker Compose plugin is available"
  else
    err "Docker Compose plugin is missing"
  fi
  if docker network inspect coolify >/dev/null 2>&1; then
    ok "Docker network exists: coolify"
  else
    err "Docker network is missing: coolify"
  fi
}

check_files() {
  local file
  local key
  local mode
  local owner

  section "Files"
  if [[ -d "$COOLIFY_DATA_DIR" ]]; then
    ok "Data directory exists: $COOLIFY_DATA_DIR"
  else
    err "Data directory is missing: $COOLIFY_DATA_DIR"
    return
  fi

  for file in \
    "$COOLIFY_DATA_DIR/source/.env" \
    "$COOLIFY_DATA_DIR/source/docker-compose.yml" \
    "$COOLIFY_DATA_DIR/source/docker-compose.prod.yml" \
    "$COOLIFY_DATA_DIR/source/upgrade.sh"; do
    if [[ -s "$file" ]]; then
      ok "Required file exists: $file"
    else
      err "Required file is missing or empty: $file"
    fi
  done

  owner="$(stat -c '%u:%g' "$COOLIFY_DATA_DIR" 2>/dev/null || true)"
  mode="$(stat -c '%a' "$COOLIFY_DATA_DIR" 2>/dev/null || true)"
  if [[ "$owner" == "9999:0" ]]; then
    ok "Data directory owner is 9999:root"
  else
    warn "Unexpected data directory owner: ${owner:-unknown}"
  fi
  if [[ "$mode" == "700" ]]; then
    ok "Data directory mode is 700"
  else
    warn "Unexpected data directory mode: ${mode:-unknown}"
  fi

  if [[ -s "$COOLIFY_DATA_DIR/source/.env" ]]; then
    for key in APP_KEY DB_PASSWORD REDIS_PASSWORD PUSHER_APP_ID PUSHER_APP_KEY PUSHER_APP_SECRET; do
      if grep -Eq "^${key}=.+$" "$COOLIFY_DATA_DIR/source/.env"; then
        ok "Generated value is present: $key"
      else
        err "Generated value is missing or empty: $key"
      fi
    done
  fi
}

check_compose() {
  section "Docker Compose"
  command -v docker >/dev/null 2>&1 || { err "Docker is unavailable"; return; }
  [[ -s "$COOLIFY_DATA_DIR/source/.env" ]] || { err "Coolify .env is unavailable"; return; }

  if docker compose \
    --env-file "$COOLIFY_DATA_DIR/source/.env" \
    -f "$COOLIFY_DATA_DIR/source/docker-compose.yml" \
    -f "$COOLIFY_DATA_DIR/source/docker-compose.prod.yml" \
    config >/dev/null 2>&1; then
    ok "Coolify Compose configuration is valid"
  else
    err "Coolify Compose configuration is invalid"
  fi
}

check_containers() {
  local container
  local status

  section "Containers"
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    err "Docker daemon is unavailable"
    return
  fi

  for container in coolify coolify-db coolify-redis coolify-realtime; do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
    case "$status" in
      healthy|running) ok "Container is ready: $container ($status)" ;;
      "") err "Container is missing: $container" ;;
      *) err "Container is not ready: $container ($status)" ;;
    esac
  done
}

source_env_value() {
  local key="$1"
  local file="$COOLIFY_DATA_DIR/source/.env"
  [[ -r "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

port_is_listening() {
  local port="$1"
  ss -H -ltn "( sport = :$port )" 2>/dev/null | grep -q .
}

check_network() {
  local app_port
  local port
  local soketi_port

  section "Network"
  command -v ss >/dev/null 2>&1 || { err "ss is unavailable"; return; }
  app_port="$(source_env_value APP_PORT)"
  soketi_port="$(source_env_value SOKETI_PORT)"
  app_port="${app_port:-8000}"
  soketi_port="${soketi_port:-6001}"

  for port in "$app_port" "$soketi_port" 6002; do
    if port_is_listening "$port"; then
      ok "TCP port is listening: $port"
    else
      err "TCP port is not listening: $port"
    fi
  done

  if curl --fail --silent --show-error --connect-timeout 5 --max-time 15 "http://127.0.0.1:${app_port}/api/health" >/dev/null 2>&1; then
    ok "Coolify health endpoint is reachable on port $app_port"
  else
    err "Coolify health endpoint is not reachable on port $app_port"
  fi
}

check_ssh() {
  local permit_root_login

  section "SSH localhost management"
  if [[ -f /root/.ssh/authorized_keys ]]; then
    ok "Root authorized_keys exists"
  else
    err "Root authorized_keys is missing"
  fi
  if [[ -f /root/.ssh/authorized_keys ]] && grep -q 'coolify' /root/.ssh/authorized_keys; then
    ok "Coolify localhost public key is authorized"
  else
    err "Coolify localhost public key is not present in root authorized_keys"
  fi

  if compgen -G "$COOLIFY_DATA_DIR/ssh/keys/id.*@host.docker.internal" >/dev/null; then
    ok "Coolify localhost private key exists"
  else
    err "Coolify localhost private key is missing"
  fi

  if command -v sshd >/dev/null 2>&1; then
    permit_root_login="$(sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" {print $2; exit}')"
    case "$permit_root_login" in
      yes|prohibit-password|without-password) ok "SSH permits root key login: $permit_root_login" ;;
      *) err "SSH does not permit root key login: ${permit_root_login:-unknown}" ;;
    esac
  fi
}

ufw_has_tcp_port() {
  local port="$1"
  ufw status | grep -Eq "(^|[[:space:]])${port}/tcp([[:space:]]|$)"
}

check_firewall() {
  local port

  section "Firewall"
  if [[ "$COOLIFY_CONFIGURE_UFW" != "true" ]]; then
    info "COOLIFY_CONFIGURE_UFW=false; skipping UFW rule checks"
    return
  fi
  if ! command -v ufw >/dev/null 2>&1; then
    err "Command not found: ufw"
    return
  fi

  if ufw status | grep -q 'Status: active'; then
    ok "UFW is active"
  else
    warn "UFW is not active"
  fi
  for port in 80 443 8000 6001 6002; do
    if ufw_has_tcp_port "$port"; then
      ok "UFW rule is present: $port/tcp"
    else
      warn "UFW rule is missing: $port/tcp"
    fi
  done
  warn "Docker-published ports can bypass UFW; verify the provider firewall separately"
}

summary() {
  section "Summary"
  if (( ERROR_COUNT > 0 )); then
    log_line "ERROR" "$ERROR_COUNT error(s), $WARNING_COUNT warning(s)"
    return 1
  fi
  log_line "OK" "No errors, $WARNING_COUNT warning(s)"
}

main() {
  require_root
  load_env
  check_system
  check_commands
  check_docker
  check_files
  check_compose
  check_containers
  check_network
  check_ssh
  check_firewall
  summary
}

main "$@"
