#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
CADDYFILE="/etc/caddy/Caddyfile"
CADDY_KEYRING="/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
CADDY_SOURCE_LIST="/etc/apt/sources.list.d/caddy-stable.list"

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
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/caddy && bash check-setup.sh"; }

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
  CADDY_DOMAIN=""
  CADDY_UPSTREAM=""
  CADDY_EMAIL=""
}

load_env() {
  resolve_env_file
  reset_env_vars
  if [[ -z "$ENV_FILE" ]]; then
    info "Environment file not found; reverse proxy checks will be skipped"
    return
  fi

  if [[ -f "$ENV_FILE" ]]; then
    info "Loading environment from $ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
    CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
  else
    warn "Environment file not found: $ENV_FILE"
  fi
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

ufw_has_tcp_port() {
  local port="$1"
  ufw status | grep -Eq "(^|[[:space:]])${port}/tcp([[:space:]]|$)"
}

check_system() {
  section "Base system"
  check_cmd caddy
  check_cmd systemctl
  check_cmd ufw
  check_cmd ss
  check_cmd curl

  check_service_active caddy
}

check_repository() {
  section "Caddy repository"
  [[ -f "$CADDY_KEYRING" ]] && ok "Caddy keyring is present" || warn "Caddy keyring is missing: $CADDY_KEYRING"
  [[ -f "$CADDY_SOURCE_LIST" ]] && ok "Caddy apt source is present" || warn "Caddy apt source is missing: $CADDY_SOURCE_LIST"

  if command -v caddy >/dev/null 2>&1; then
    info "Caddy version: $(caddy version)"
  fi
}

check_caddyfile() {
  section "Caddyfile"
  if [[ ! -f "$CADDYFILE" ]]; then
    err "Caddyfile is missing: $CADDYFILE"
    return
  fi

  ok "Caddyfile exists: $CADDYFILE"

  if command -v caddy >/dev/null 2>&1; then
    if caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
      ok "Caddyfile is valid"
    else
      err "Caddyfile validation failed"
      caddy validate --config "$CADDYFILE" || true
    fi
  else
    warn "Could not validate Caddyfile because caddy command is missing"
  fi

  if [[ -z "${CADDY_DOMAIN:-}" && -z "${CADDY_UPSTREAM:-}" ]]; then
    info "CADDY_DOMAIN and CADDY_UPSTREAM are empty; skipping reverse proxy checks"
    return
  fi

  if [[ -n "${CADDY_DOMAIN:-}" ]] && grep -Fq "$CADDY_DOMAIN" "$CADDYFILE"; then
    ok "Caddyfile contains CADDY_DOMAIN: $CADDY_DOMAIN"
  else
    err "Caddyfile does not contain CADDY_DOMAIN: ${CADDY_DOMAIN:-<empty>}"
  fi

  if [[ -n "${CADDY_UPSTREAM:-}" ]] && grep -Fq "reverse_proxy $CADDY_UPSTREAM" "$CADDYFILE"; then
    ok "Caddyfile contains reverse proxy upstream: $CADDY_UPSTREAM"
  else
    err "Caddyfile does not contain reverse_proxy ${CADDY_UPSTREAM:-<empty>}"
  fi

  if [[ -n "${CADDY_EMAIL:-}" ]] && grep -Fq "email $CADDY_EMAIL" "$CADDYFILE"; then
    ok "Caddyfile contains CADDY_EMAIL"
  elif [[ -n "${CADDY_EMAIL:-}" ]]; then
    warn "Caddyfile does not contain CADDY_EMAIL: $CADDY_EMAIL"
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
    warn "UFW is not active; HTTP/HTTPS rules are stored but not enforced"
  fi

  if ufw_has_tcp_port 80; then
    ok "HTTP port is open in UFW: 80/tcp"
  else
    warn "HTTP port was not found in UFW: 80/tcp"
  fi

  if ufw_has_tcp_port 443; then
    ok "HTTPS port is open in UFW: 443/tcp"
  else
    warn "HTTPS port was not found in UFW: 443/tcp"
  fi

  echo
  info "All UFW rules:"
  ufw status numbered || true
}

check_listening_ports() {
  section "Listening ports"
  if ! command -v ss >/dev/null 2>&1; then
    err "Command not found: ss"
    return
  fi

  if ss -tln "( sport = :80 )" | grep -q LISTEN; then
    ok "Port 80 is listening"
  else
    warn "Port 80 is not listening"
  fi

  if ss -tln "( sport = :443 )" | grep -q LISTEN; then
    ok "Port 443 is listening"
  else
    warn "Port 443 is not listening"
  fi

  echo
  info "HTTP/HTTPS listeners:"
  ss -tulpn | grep -E ':(80|443)\b' || true
}

main() {
  require_root
  load_env
  check_system
  check_repository
  check_caddyfile
  check_ufw
  check_listening_ports
}

main "$@"
