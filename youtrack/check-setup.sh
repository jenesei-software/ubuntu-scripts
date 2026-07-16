#!/usr/bin/env bash
# The compact diagnostic predicates are safe because ok/warn/err always return zero.
# shellcheck disable=SC2015
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts youtrack"
ERRORS=0
WARNINGS=0

timestamp() { date '+%F %T'; }
line() { local level="$1"; shift; printf '[%s] %-7s %s\n' "$(timestamp)" "$level" "$*"; }
ok() { line OK "$*"; }
info() { line INFO "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); line WARN "$*"; }
err() { ERRORS=$((ERRORS + 1)); line ERROR "$*"; }
section() { printf '\n'; line SECTION "$*"; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Run as root"; summary; exit 1; }; }

resolve_env_path() { local value="$1"; if [[ "$value" = /* ]]; then printf '%s\n' "$value"; elif [[ -f "$value" ]]; then printf '%s/%s\n' "$(cd -- "$(dirname -- "$value")" && pwd)" "$(basename -- "$value")"; else printf '%s/%s\n' "$SCRIPT_DIR" "$value"; fi; }
load_env() {
  local file
  if [[ -n "$ENV_FILE_INPUT" ]]; then file="$(resolve_env_path "$ENV_FILE_INPUT")"; else file="$SCRIPT_DIR/.env"; fi
  YOUTRACK_URL=""; YOUTRACK_INSTALL_DIR=""; YOUTRACK_BIND_IP=""; YOUTRACK_PORT=""; YOUTRACK_IMAGE=""; YOUTRACK_CONTAINER_NAME=""; YOUTRACK_CONFIGURE_CADDY=""; CADDYFILE=""
  if [[ -f "$file" ]]; then
    info "Loading environment from $file"
    set -a
    # shellcheck disable=SC1090
    source "$file"
    set +a
  else warn "Environment file not found: $file"; fi
  YOUTRACK_INSTALL_DIR="${YOUTRACK_INSTALL_DIR:-/opt/youtrack}"
  YOUTRACK_BIND_IP="${YOUTRACK_BIND_IP:-127.0.0.1}"
  YOUTRACK_PORT="${YOUTRACK_PORT:-8080}"
  YOUTRACK_IMAGE="${YOUTRACK_IMAGE:-jetbrains/youtrack:2026.2.17765}"
  YOUTRACK_CONTAINER_NAME="${YOUTRACK_CONTAINER_NAME:-youtrack}"
  YOUTRACK_CONFIGURE_CADDY="${YOUTRACK_CONFIGURE_CADDY:-true}"
  CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
}
site_host() { local value="${YOUTRACK_URL:-}"; value="${value#http://}"; value="${value#https://}"; printf '%s\n' "${value%%/*}"; }
check_cmd() { command -v "$1" >/dev/null 2>&1 && ok "Command found: $1" || err "Command not found: $1"; }
check_service() { systemctl is-active --quiet "$1" 2>/dev/null && ok "Service $1 is active" || err "Service $1 is not active"; }

check_system() {
  section "Base system"
  check_cmd docker; check_cmd curl; check_cmd ss; check_cmd systemctl
  [[ "$YOUTRACK_CONFIGURE_CADDY" == true ]] && check_cmd caddy
  [[ -r /etc/os-release ]] && grep -q '^VERSION_ID="\?24\.04"\?$' /etc/os-release && ok "Ubuntu 24.04 detected" || err "Ubuntu 24.04 was not detected"
  command -v docker >/dev/null 2>&1 && check_service docker
  docker compose version >/dev/null 2>&1 && ok "Docker Compose plugin is available" || err "Docker Compose plugin is unavailable"
}

check_files() {
  section "Persistent files"
  local dir
  [[ -f "$YOUTRACK_INSTALL_DIR/docker-compose.yml" ]] && ok "Compose file exists" || err "Compose file is missing"
  for dir in data conf logs backups; do
    if [[ -d "$YOUTRACK_INSTALL_DIR/$dir" ]]; then
      ok "Directory exists: $dir"
      [[ "$(stat -c '%u:%g' "$YOUTRACK_INSTALL_DIR/$dir" 2>/dev/null)" == 13001:13001 ]] && ok "Directory ownership is 13001:13001: $dir" || err "Directory ownership must be 13001:13001: $dir"
    else err "Directory is missing: $YOUTRACK_INSTALL_DIR/$dir"; fi
  done
}

check_compose() {
  section "YouTrack container"
  local compose="$YOUTRACK_INSTALL_DIR/docker-compose.yml" state binding
  [[ -f "$compose" ]] || return
  docker compose -f "$compose" config >/dev/null 2>&1 && ok "Compose file is valid" || err "Compose file is invalid"
  state="$(docker inspect --format '{{.State.Status}}' "$YOUTRACK_CONTAINER_NAME" 2>/dev/null || true)"
  [[ "$state" == running ]] && ok "Container is running" || err "Container state is ${state:-missing}"
  binding="$(docker port "$YOUTRACK_CONTAINER_NAME" 8080/tcp 2>/dev/null || true)"
  [[ "$binding" == "${YOUTRACK_BIND_IP}:${YOUTRACK_PORT}" || "$binding" == "[${YOUTRACK_BIND_IP}]:${YOUTRACK_PORT}" ]] && ok "Container is bound to ${YOUTRACK_BIND_IP}:${YOUTRACK_PORT}" || err "Unexpected port binding: ${binding:-none}"
  docker inspect --format '{{.Config.Image}}' "$YOUTRACK_CONTAINER_NAME" 2>/dev/null | grep -Fxq "$YOUTRACK_IMAGE" && ok "Expected image is configured" || err "Container image differs from $YOUTRACK_IMAGE"
}

check_http() {
  section "HTTP"
  local code
  ss -H -ltn "( sport = :$YOUTRACK_PORT )" 2>/dev/null | grep -q . && ok "Local port is listening" || err "Local port is not listening"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 "http://${YOUTRACK_BIND_IP}:${YOUTRACK_PORT}/" 2>/dev/null || true)"
  [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]] && ok "Local YouTrack endpoint returned HTTP $code" || err "Local YouTrack endpoint is unavailable (HTTP ${code:-none})"
  if [[ -n "${YOUTRACK_URL:-}" ]]; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 "$YOUTRACK_URL" 2>/dev/null || true)"
    [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]] && ok "Public YouTrack URL returned HTTP $code" || warn "Public URL is not ready (HTTP ${code:-none}); check DNS and TLS"
  fi
}

check_caddy() {
  section "Caddy"
  [[ "$YOUTRACK_CONFIGURE_CADDY" == true ]] || { info "Caddy integration is disabled"; return; }
  check_service caddy
  [[ -f "$CADDYFILE" ]] || { err "Caddyfile is missing: $CADDYFILE"; return; }
  caddy validate --config "$CADDYFILE" >/dev/null 2>&1 && ok "Caddyfile is valid" || err "Caddyfile validation failed"
  local host; host="$(site_host)"
  [[ -n "$host" ]] || { err "YOUTRACK_URL is empty"; return; }
  grep -Fq "$CADDY_MANAGED_PREFIX $host" "$CADDYFILE" && ok "Managed Caddy block is present" || warn "Managed Caddy marker is absent"
  grep -Eq "reverse_proxy (http://)?(${YOUTRACK_BIND_IP}|localhost):${YOUTRACK_PORT}([[:space:]]|$)" "$CADDYFILE" && ok "Caddy points to the local YouTrack port" || err "Caddy upstream does not match YouTrack"
}

summary() { section "Summary"; line INFO "$ERRORS error(s), $WARNINGS warning(s)"; }
main() { require_root; load_env; check_system; check_files; check_compose; check_http; check_caddy; summary; (( ERRORS == 0 )); }
main "$@"
