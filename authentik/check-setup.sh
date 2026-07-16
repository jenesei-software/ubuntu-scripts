#!/usr/bin/env bash
# The compact diagnostic predicates are safe because ok/warn/err always return zero.
# shellcheck disable=SC2015
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts authentik"
ERRORS=0
WARNINGS=0
timestamp() { date '+%F %T'; }
line() { local level="$1"; shift; printf '[%s] %-7s %s\n' "$(timestamp)" "$level" "$*"; }
ok() { line OK "$*"; }; info() { line INFO "$*"; }; warn() { WARNINGS=$((WARNINGS + 1)); line WARN "$*"; }; err() { ERRORS=$((ERRORS + 1)); line ERROR "$*"; }; section() { printf '\n'; line SECTION "$*"; }
summary() { section "Summary"; line INFO "$ERRORS error(s), $WARNINGS warning(s)"; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Run as root"; summary; exit 1; }; }
resolve_env_path() { local value="$1"; if [[ "$value" = /* ]]; then printf '%s\n' "$value"; elif [[ -f "$value" ]]; then printf '%s/%s\n' "$(cd -- "$(dirname -- "$value")" && pwd)" "$(basename -- "$value")"; else printf '%s/%s\n' "$SCRIPT_DIR" "$value"; fi; }
load_env() {
  local file; if [[ -n "$ENV_FILE_INPUT" ]]; then file="$(resolve_env_path "$ENV_FILE_INPUT")"; else file="$SCRIPT_DIR/.env"; fi
  AUTHENTIK_URL=""; AUTHENTIK_INSTALL_DIR=""; AUTHENTIK_BIND_IP=""; AUTHENTIK_HTTP_PORT=""; AUTHENTIK_HTTPS_PORT=""; AUTHENTIK_VERSION=""; AUTHENTIK_ENABLE_DOCKER_SOCKET=""; AUTHENTIK_CONFIGURE_CADDY=""; CADDYFILE=""
  if [[ -f "$file" ]]; then
    info "Loading environment from $file"; set -a
    # shellcheck disable=SC1090
    source "$file"
    set +a
  else warn "Environment file not found: $file"; fi
  AUTHENTIK_INSTALL_DIR="${AUTHENTIK_INSTALL_DIR:-/opt/authentik}"; AUTHENTIK_BIND_IP="${AUTHENTIK_BIND_IP:-127.0.0.1}"; AUTHENTIK_HTTP_PORT="${AUTHENTIK_HTTP_PORT:-9000}"; AUTHENTIK_HTTPS_PORT="${AUTHENTIK_HTTPS_PORT:-9443}"
  AUTHENTIK_VERSION="${AUTHENTIK_VERSION:-2026.5.5}"; AUTHENTIK_ENABLE_DOCKER_SOCKET="${AUTHENTIK_ENABLE_DOCKER_SOCKET:-false}"; AUTHENTIK_CONFIGURE_CADDY="${AUTHENTIK_CONFIGURE_CADDY:-true}"; CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
}
site_host() { local value="${AUTHENTIK_URL:-}"; value="${value#https://}"; printf '%s\n' "${value%%/*}"; }
check_cmd() { command -v "$1" >/dev/null 2>&1 && ok "Command found: $1" || err "Command not found: $1"; }
check_service() { systemctl is-active --quiet "$1" 2>/dev/null && ok "Service $1 is active" || err "Service $1 is not active"; }
compose() { (cd "$AUTHENTIK_INSTALL_DIR" && docker compose --env-file .env -f compose.yml "$@"); }

check_system() {
  section "Base system"; check_cmd docker; check_cmd curl; check_cmd ss; check_cmd systemctl
  [[ "$AUTHENTIK_CONFIGURE_CADDY" == true ]] && check_cmd caddy
  [[ -r /etc/os-release ]] && grep -q '^VERSION_ID="\?24\.04"\?$' /etc/os-release && ok "Ubuntu 24.04 detected" || err "Ubuntu 24.04 was not detected"
  command -v docker >/dev/null 2>&1 && check_service docker
  docker compose version >/dev/null 2>&1 && ok "Docker Compose plugin is available" || err "Docker Compose plugin is unavailable"
}

check_files() {
  section "Configuration and secrets"
  [[ -f "$AUTHENTIK_INSTALL_DIR/compose.yml" ]] && ok "Official Compose file exists" || err "Compose file is missing"
  if [[ -f "$AUTHENTIK_INSTALL_DIR/.env" ]]; then
    ok "Runtime environment exists"
    [[ "$(stat -c '%a' "$AUTHENTIK_INSTALL_DIR/.env" 2>/dev/null)" == 600 ]] && ok "Runtime environment mode is 0600" || err "Runtime environment mode must be 0600"
    grep -Eq '^PG_PASS=[0-9a-f]{32,}$' "$AUTHENTIK_INSTALL_DIR/.env" && ok "Postgres secret is present" || err "Postgres secret is missing or invalid"
    grep -Eq '^AUTHENTIK_SECRET_KEY=[0-9a-f]{64,}$' "$AUTHENTIK_INSTALL_DIR/.env" && ok "Authentik secret key is present" || err "Authentik secret key is missing or invalid"
    grep -Eq '^AUTHENTIK_BOOTSTRAP_TOKEN=[0-9a-f]{32,}$' "$AUTHENTIK_INSTALL_DIR/.env" && ok "Bootstrap API token is present" || err "Bootstrap API token is missing or invalid"
  else err "Runtime environment is missing"; fi
  if [[ "$AUTHENTIK_ENABLE_DOCKER_SOCKET" == true ]]; then grep -Fq '/var/run/docker.sock:/var/run/docker.sock' "$AUTHENTIK_INSTALL_DIR/compose.yml" && ok "Docker socket mount is enabled as requested" || err "Docker socket mount is missing"; else ! grep -Fq '/var/run/docker.sock:/var/run/docker.sock' "$AUTHENTIK_INSTALL_DIR/compose.yml" && ok "Docker socket mount is disabled" || err "Docker socket is exposed unexpectedly"; fi
}

check_compose() {
  section "Authentik containers"
  [[ -f "$AUTHENTIK_INSTALL_DIR/compose.yml" && -f "$AUTHENTIK_INSTALL_DIR/.env" ]] || return
  compose config >/dev/null 2>&1 && ok "Compose configuration is valid" || err "Compose configuration is invalid"
  local service id state image
  for service in postgresql server worker; do
    id="$(compose ps -q "$service" 2>/dev/null || true)"; [[ -n "$id" ]] || { err "Container is missing: $service"; continue; }
    state="$(docker inspect --format '{{.State.Status}}' "$id" 2>/dev/null || true)"; [[ "$state" == running ]] && ok "Container is running: $service" || err "Container $service state is ${state:-unknown}"
    if [[ "$service" != postgresql ]]; then image="$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null || true)"; [[ "$image" == "ghcr.io/goauthentik/server:$AUTHENTIK_VERSION" ]] && ok "Expected image is running: $service" || err "Unexpected image for $service: ${image:-none}"; fi
  done
}

check_http() {
  section "HTTP and readiness"
  local code
  ss -H -ltn "( sport = :$AUTHENTIK_HTTP_PORT )" 2>/dev/null | grep -q . && ok "Local HTTP port is listening" || err "Local HTTP port is not listening"
  ss -H -ltn "( sport = :$AUTHENTIK_HTTPS_PORT )" 2>/dev/null | grep -q . && ok "Local HTTPS port is listening" || err "Local HTTPS port is not listening"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 "http://${AUTHENTIK_BIND_IP}:${AUTHENTIK_HTTP_PORT}/-/health/ready/" 2>/dev/null || true)"
  [[ "$code" == 200 ]] && ok "Readiness endpoint returned HTTP 200" || err "Readiness endpoint is unavailable (HTTP ${code:-none})"
  if [[ -n "${AUTHENTIK_URL:-}" ]]; then code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 "$AUTHENTIK_URL" 2>/dev/null || true)"; [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]] && ok "Public Authentik URL returned HTTP $code" || warn "Public URL is not ready (HTTP ${code:-none}); check DNS and TLS"; fi
}

check_caddy() {
  section "Caddy"; [[ "$AUTHENTIK_CONFIGURE_CADDY" == true ]] || { info "Caddy integration is disabled"; return; }
  check_service caddy; [[ -f "$CADDYFILE" ]] || { err "Caddyfile is missing"; return; }
  caddy validate --config "$CADDYFILE" >/dev/null 2>&1 && ok "Caddyfile is valid" || err "Caddyfile validation failed"
  local host; host="$(site_host)"; [[ -n "$host" ]] || { err "AUTHENTIK_URL is empty"; return; }
  grep -Fq "$CADDY_MANAGED_PREFIX $host" "$CADDYFILE" && ok "Managed Caddy block is present" || warn "Managed Caddy marker is absent"
  grep -Eq "reverse_proxy (http://)?(${AUTHENTIK_BIND_IP}|localhost):${AUTHENTIK_HTTP_PORT}([[:space:]]|$)" "$CADDYFILE" && ok "Caddy points to Authentik" || err "Caddy upstream does not match Authentik"
}

check_youtrack_oidc() {
  section "YouTrack OIDC integration"
  local integration="$AUTHENTIK_INSTALL_DIR/integrations/youtrack-oidc.env" discovery issuer body
  [[ -f "$integration" ]] || { info "YouTrack OIDC integration has not been prepared"; return; }
  [[ "$(stat -c '%a' "$integration" 2>/dev/null)" == 600 ]] && ok "OIDC client settings mode is 0600" || err "OIDC client settings mode must be 0600"
  discovery="$(sed -n 's/^YOUTRACK_OIDC_DISCOVERY_URL=//p' "$integration" | tail -n 1)"
  issuer="$(sed -n 's/^YOUTRACK_OIDC_ISSUER=//p' "$integration" | tail -n 1)"
  [[ -n "$discovery" && -n "$issuer" ]] || { err "OIDC discovery URL or issuer is missing"; return; }
  body="$(curl -fsS --connect-timeout 5 --max-time 15 "$discovery" 2>/dev/null || true)"
  [[ -n "$body" ]] && ok "OIDC discovery document is reachable" || { err "OIDC discovery document is unavailable"; return; }
  grep -Fq "\"issuer\": \"$issuer\"" <<< "$body" || grep -Fq "\"issuer\":\"$issuer\"" <<< "$body" && ok "OIDC issuer matches the generated settings" || err "OIDC issuer does not match the generated settings"
}

main() { require_root; load_env; check_system; check_files; check_compose; check_http; check_caddy; check_youtrack_oidc; summary; (( ERRORS == 0 )); }
main "$@"
