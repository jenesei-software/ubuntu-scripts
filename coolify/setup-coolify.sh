#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
INSTALLER_URL="https://cdn.coollabs.io/coolify/install.sh"
COOLIFY_DATA_DIR="/data/coolify"
INSTALLER_FILE=""

LOG_COLOR='\033[1;36m'
LOG_RESET='\033[0m'

timestamp() { date '+%F %T'; }
log_line() {
  local level="$1"
  shift
  printf '%b[%s] %-7s%b %s\n' "$LOG_COLOR" "$(timestamp)" "$level" "$LOG_RESET" "$*"
}

log() { log_line "INFO" "$*"; }
warn() { log_line "WARN" "$*"; }
fail() { log_line "ERROR" "$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/coolify && bash setup-coolify.sh"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"; }

cleanup() {
  if [[ -n "$INSTALLER_FILE" && -f "$INSTALLER_FILE" ]]; then
    rm -f -- "$INSTALLER_FILE"
  fi
}
trap cleanup EXIT

on_error() {
  local exit_code=$?
  local line_no="${BASH_LINENO[0]:-${LINENO}}"
  local command="${BASH_COMMAND:-unknown}"
  log_line "ERROR" "Setup failed at line $line_no: $command (exit $exit_code)" >&2
}
trap on_error ERR

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

  fail "Environment file not found. Copy coolify/env.example to coolify/.env or run: cd coolify && cp env.example .env"
}

reset_env_vars() {
  COOLIFY_VERSION=""
  AUTOUPDATE=""
  REGISTRY_URL=""
  DOCKER_ADDRESS_POOL_BASE=""
  DOCKER_ADDRESS_POOL_SIZE=""
  DOCKER_POOL_FORCE_OVERRIDE=""
  ROOT_USERNAME=""
  ROOT_USER_EMAIL=""
  ROOT_USER_PASSWORD=""
  COOLIFY_ALLOW_PROXY_PORT_CONFLICTS=""
  COOLIFY_CONFIGURE_UFW=""
  COOLIFY_ALLOW_LOW_RESOURCES=""
}

load_env() {
  resolve_env_file
  reset_env_vars
  [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"

  log "Loading environment from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  COOLIFY_VERSION="${COOLIFY_VERSION:-}"
  AUTOUPDATE="${AUTOUPDATE:-true}"
  REGISTRY_URL="${REGISTRY_URL:-docker.io}"
  DOCKER_ADDRESS_POOL_BASE="${DOCKER_ADDRESS_POOL_BASE:-10.0.0.0/8}"
  DOCKER_ADDRESS_POOL_SIZE="${DOCKER_ADDRESS_POOL_SIZE:-24}"
  DOCKER_POOL_FORCE_OVERRIDE="${DOCKER_POOL_FORCE_OVERRIDE:-false}"
  ROOT_USERNAME="${ROOT_USERNAME:-}"
  ROOT_USER_EMAIL="${ROOT_USER_EMAIL:-}"
  ROOT_USER_PASSWORD="${ROOT_USER_PASSWORD:-}"
  COOLIFY_ALLOW_PROXY_PORT_CONFLICTS="${COOLIFY_ALLOW_PROXY_PORT_CONFLICTS:-false}"
  COOLIFY_CONFIGURE_UFW="${COOLIFY_CONFIGURE_UFW:-true}"
  COOLIFY_ALLOW_LOW_RESOURCES="${COOLIFY_ALLOW_LOW_RESOURCES:-false}"

  chmod 0600 "$ENV_FILE"
}

validate_bool() {
  local name="$1"
  local value="$2"
  [[ "$value" == "true" || "$value" == "false" ]] || fail "$name must be true or false"
}

validate_ipv4_cidr() {
  local cidr="$1"
  local ip
  local octet
  local prefix
  local prefix_value
  local -a octets

  [[ "$cidr" == */* ]] || return 1
  ip="${cidr%/*}"
  prefix="${cidr#*/}"
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  prefix_value=$((10#$prefix))
  (( prefix_value >= 0 && prefix_value <= 32 )) || return 1

  IFS='.' read -r -a octets <<< "$ip"
  (( ${#octets[@]} == 4 )) || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    [[ "$octet" == "0" || "$octet" != 0* ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
}

validate_env() {
  local credentials_set=0
  local pool_prefix
  local pool_size

  validate_bool AUTOUPDATE "$AUTOUPDATE"
  validate_bool DOCKER_POOL_FORCE_OVERRIDE "$DOCKER_POOL_FORCE_OVERRIDE"
  validate_bool COOLIFY_ALLOW_PROXY_PORT_CONFLICTS "$COOLIFY_ALLOW_PROXY_PORT_CONFLICTS"
  validate_bool COOLIFY_CONFIGURE_UFW "$COOLIFY_CONFIGURE_UFW"
  validate_bool COOLIFY_ALLOW_LOW_RESOURCES "$COOLIFY_ALLOW_LOW_RESOURCES"

  [[ -z "$COOLIFY_VERSION" || "$COOLIFY_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "COOLIFY_VERSION contains unsupported characters"
  [[ -n "$REGISTRY_URL" && ! "$REGISTRY_URL" =~ [[:space:]] ]] || fail "REGISTRY_URL must be non-empty and contain no whitespace"
  [[ "$REGISTRY_URL" != *://* && "$REGISTRY_URL" != */ ]] || fail "REGISTRY_URL must be a registry host without a scheme or trailing slash"
  validate_ipv4_cidr "$DOCKER_ADDRESS_POOL_BASE" || fail "DOCKER_ADDRESS_POOL_BASE must be a valid IPv4 CIDR"
  [[ "$DOCKER_ADDRESS_POOL_SIZE" =~ ^[0-9]+$ ]] || fail "DOCKER_ADDRESS_POOL_SIZE must be an integer"
  pool_size=$((10#$DOCKER_ADDRESS_POOL_SIZE))
  (( pool_size >= 16 && pool_size <= 28 )) || fail "DOCKER_ADDRESS_POOL_SIZE must be between 16 and 28"
  pool_prefix=$((10#${DOCKER_ADDRESS_POOL_BASE#*/}))
  (( pool_size >= pool_prefix )) || fail "DOCKER_ADDRESS_POOL_SIZE cannot be smaller than the base CIDR prefix"

  [[ -n "$ROOT_USERNAME" ]] && credentials_set=$((credentials_set + 1))
  [[ -n "$ROOT_USER_EMAIL" ]] && credentials_set=$((credentials_set + 1))
  [[ -n "$ROOT_USER_PASSWORD" ]] && credentials_set=$((credentials_set + 1))
  (( credentials_set == 0 || credentials_set == 3 )) || fail "Set ROOT_USERNAME, ROOT_USER_EMAIL, and ROOT_USER_PASSWORD together, or leave all three empty"

  if (( credentials_set == 3 )); then
    [[ "$ROOT_USERNAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "ROOT_USERNAME contains unsupported characters"
    [[ "$ROOT_USER_EMAIL" == *@* && ! "$ROOT_USER_EMAIL" =~ [[:space:]] ]] || fail "ROOT_USER_EMAIL must look like an email address"
    (( ${#ROOT_USER_PASSWORD} >= 12 )) || fail "ROOT_USER_PASSWORD must contain at least 12 characters"
    [[ "${ROOT_USER_PASSWORD,,}" != *change_me* ]] || fail "Replace the placeholder ROOT_USER_PASSWORD"
    [[ "$ROOT_USER_EMAIL$ROOT_USER_PASSWORD" != *"|"* \
      && "$ROOT_USER_EMAIL$ROOT_USER_PASSWORD" != *"&"* \
      && "$ROOT_USER_EMAIL$ROOT_USER_PASSWORD" != *$'\\'* ]] \
      || fail "ROOT_USER_EMAIL and ROOT_USER_PASSWORD cannot contain |, &, or backslash because the official installer cannot safely persist them"
    [[ "$ROOT_USER_PASSWORD" != *$'\n'* && "$ROOT_USER_PASSWORD" != *$'\r'* ]] || fail "ROOT_USER_PASSWORD must be one line"
  fi
}

check_platform() {
  local architecture

  [[ -r /etc/os-release ]] || fail "/etc/os-release is missing"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || fail "This repository targets Ubuntu 24.04; detected ${PRETTY_NAME:-unknown}"

  architecture="$(uname -m)"
  [[ "$architecture" == "x86_64" || "$architecture" == "aarch64" ]] || fail "Coolify requires amd64 or arm64; detected $architecture"
}

is_existing_installation() {
  [[ -f "$COOLIFY_DATA_DIR/source/.env" && -f "$COOLIFY_DATA_DIR/source/docker-compose.yml" ]]
}

runtime_port() {
  local default_port="$2"
  local key="$1"
  local port=""

  if [[ -r "$COOLIFY_DATA_DIR/source/.env" ]]; then
    port="$(sed -n "s/^${key}=//p" "$COOLIFY_DATA_DIR/source/.env" | tail -n 1)"
  fi
  port="${port:-$default_port}"
  if [[ ! "$port" =~ ^[1-9][0-9]*$ ]] || (( 10#$port > 65535 )); then
    fail "Invalid $key in $COOLIFY_DATA_DIR/source/.env: $port"
  fi
  printf '%s\n' "$port"
}

check_resources() {
  local available_kb
  local cpu_count
  local memory_kb
  local required_available_kb
  local total_kb
  local -a problems=()

  cpu_count="$(nproc)"
  memory_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  read -r total_kb available_kb < <(df -Pk / | awk 'NR == 2 {print $2, $4}')

  if is_existing_installation; then
    required_available_kb=$((5 * 1024 * 1024))
    (( available_kb >= required_available_kb )) || problems+=("at least 5 GB free disk space is required for an upgrade")
  else
    (( cpu_count >= 2 )) || problems+=("at least 2 CPU cores are required")
    (( memory_kb >= 2 * 1024 * 1024 )) || problems+=("at least 2 GB RAM is required")
    (( total_kb >= 30 * 1024 * 1024 )) || problems+=("the root filesystem must be at least 30 GB")
    (( available_kb >= 30 * 1024 * 1024 )) || problems+=("at least 30 GB free disk space is required")
  fi

  log "Resources: ${cpu_count} CPU, $((memory_kb / 1024 / 1024)) GB RAM, $((available_kb / 1024 / 1024)) GB free on /"
  if (( ${#problems[@]} > 0 )); then
    printf ' - %s\n' "${problems[@]}" >&2
    [[ "$COOLIFY_ALLOW_LOW_RESOURCES" == "true" ]] || fail "Resource preflight failed. Use COOLIFY_ALLOW_LOW_RESOURCES=true only for a disposable test server."
    warn "Continuing with insufficient resources because COOLIFY_ALLOW_LOW_RESOURCES=true"
  fi
}

install_prerequisites() {
  local -a missing=()
  local command

  for command in curl ss sha256sum; do
    command -v "$command" >/dev/null 2>&1 || missing+=("$command")
  done

  if (( ${#missing[@]} == 0 )); then
    return
  fi

  log "Installing prerequisites: ca-certificates curl coreutils iproute2"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install ca-certificates curl coreutils iproute2
}

listener_for_port() {
  local port="$1"
  ss -H -ltnp "( sport = :$port )" 2>/dev/null || true
}

check_port_conflicts() {
  local listener
  local port

  if is_existing_installation; then
    log "Existing Coolify installation detected; occupied Coolify ports are expected"
    return
  fi

  for port in 8000 6001 6002; do
    listener="$(listener_for_port "$port")"
    [[ -z "$listener" ]] || fail "Port $port is already occupied: $listener"
  done

  for port in 80 443; do
    listener="$(listener_for_port "$port")"
    if [[ -n "$listener" ]]; then
      if [[ "$COOLIFY_ALLOW_PROXY_PORT_CONFLICTS" == "true" ]]; then
        warn "Port $port is already occupied; the default Coolify proxy will not be able to bind it: $listener"
      else
        fail "Port $port is already occupied. Stop the existing proxy or set COOLIFY_ALLOW_PROXY_PORT_CONFLICTS=true for an intentional custom-proxy setup: $listener"
      fi
    fi
  done
}

check_docker_installation() {
  if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
    fail "Docker installed through Snap is unsupported by Coolify. Remove it with: snap remove docker"
  fi

  if is_existing_installation; then
    require_cmd docker
    docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable"
  fi
}

configure_ufw() {
  local port
  local -a ports

  [[ "$COOLIFY_CONFIGURE_UFW" == "true" ]] || {
    log "Skipping UFW rules because COOLIFY_CONFIGURE_UFW=false"
    return
  }

  if ! command -v ufw >/dev/null 2>&1; then
    log "Installing UFW without enabling it"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install ufw
  fi

  log "Adding Coolify UFW rules; provider-firewall rules are still required"
  ports=(80 443 "$(runtime_port APP_PORT 8000)" "$(runtime_port SOKETI_PORT 6001)" 6002)
  for port in "${ports[@]}"; do
    ufw allow "$port/tcp"
  done
  ufw reload >/dev/null 2>&1 || true
}

download_installer() {
  INSTALLER_FILE="$(mktemp /tmp/coolify-install.XXXXXX.sh)"
  chmod 0700 "$INSTALLER_FILE"

  log "Downloading the official installer from $INSTALLER_URL"
  curl --proto '=https' --tlsv1.2 --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 \
    "$INSTALLER_URL" -o "$INSTALLER_FILE"

  [[ -s "$INSTALLER_FILE" ]] || fail "Downloaded installer is empty"
  head -n 1 "$INSTALLER_FILE" | grep -Eq '^#!/bin/bash([[:space:]]|$)' || fail "Downloaded file does not have the expected Bash shebang"
  grep -Fq 'github.com/coollabsio/coolify' "$INSTALLER_FILE" || fail "Downloaded file does not identify the official Coolify source"
  grep -Fq 'Coolify Installation' "$INSTALLER_FILE" || fail "Downloaded file does not look like the Coolify installer"
  log "Installer SHA-256: $(sha256sum "$INSTALLER_FILE" | awk '{print $1}')"
}

run_installer() {
  export AUTOUPDATE REGISTRY_URL DOCKER_ADDRESS_POOL_BASE DOCKER_ADDRESS_POOL_SIZE
  export DOCKER_POOL_FORCE_OVERRIDE ROOT_USERNAME ROOT_USER_EMAIL ROOT_USER_PASSWORD

  if [[ -n "$COOLIFY_VERSION" ]]; then
    log "Running the official Coolify installer for version $COOLIFY_VERSION"
    bash "$INSTALLER_FILE" "$COOLIFY_VERSION"
  else
    log "Running the official Coolify installer for the current stable version"
    bash "$INSTALLER_FILE"
  fi
}

verify_installation() {
  local app_port
  local container
  local status

  require_cmd docker
  for container in coolify coolify-db coolify-redis coolify-realtime; do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
    [[ "$status" == "healthy" || "$status" == "running" ]] || fail "Container is not ready: $container ($status)"
    log "Container is ready: $container ($status)"
  done

  app_port="$(runtime_port APP_PORT 8000)"
  curl --fail --silent --show-error --connect-timeout 5 --max-time 15 "http://127.0.0.1:${app_port}/api/health" >/dev/null \
    || fail "Coolify health endpoint is not reachable on http://127.0.0.1:${app_port}/api/health"
}

main() {
  require_root
  require_cmd apt-get
  load_env
  validate_env
  check_platform
  check_resources
  install_prerequisites
  check_port_conflicts
  check_docker_installation
  configure_ufw
  download_installer
  run_installer
  verify_installation

  log "Coolify is ready on http://<SERVER_IP>:$(runtime_port APP_PORT 8000)"
  if [[ -z "$ROOT_USERNAME" ]]; then
    warn "Create the first administrator immediately; the unclaimed registration page grants control of the server."
  else
    log "The predefined administrator was passed to the official installer."
  fi
  log "Run diagnostics: cd ~/ubuntu-scripts/coolify && bash check-setup.sh"
}

main "$@"
