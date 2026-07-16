#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_SOURCE_LIST="/etc/apt/sources.list.d/docker.list"
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts authentik"
CADDY_MANAGED_SUFFIX="# END ubuntu-scripts authentik"

timestamp() { date '+%F %T'; }
log_line() { local level="$1"; shift; printf '[%s] %-7s %s\n' "$(timestamp)" "$level" "$*"; }
log() { log_line INFO "$*"; }
warn() { log_line WARN "$*"; }
fail() { log_line ERROR "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/authentik && bash setup-authentik.sh"; }
on_error() { local code=$?; log_line ERROR "Setup failed at line ${BASH_LINENO[0]:-${LINENO}}: ${BASH_COMMAND:-unknown} (exit $code)" >&2; }
trap on_error ERR

resolve_env_path() { local value="$1"; if [[ "$value" = /* ]]; then printf '%s\n' "$value"; elif [[ -f "$value" ]]; then printf '%s/%s\n' "$(cd -- "$(dirname -- "$value")" && pwd)" "$(basename -- "$value")"; else printf '%s/%s\n' "$SCRIPT_DIR" "$value"; fi; }
load_env() {
  if [[ -n "$ENV_FILE_INPUT" ]]; then ENV_FILE="$(resolve_env_path "$ENV_FILE_INPUT")"; else ENV_FILE="$SCRIPT_DIR/.env"; fi
  [[ -f "$ENV_FILE" ]] || fail "Environment file not found. Copy authentik/env.example to authentik/.env"
  AUTHENTIK_URL=""; AUTHENTIK_INSTALL_DIR=""; AUTHENTIK_BIND_IP=""; AUTHENTIK_HTTP_PORT=""; AUTHENTIK_HTTPS_PORT=""; AUTHENTIK_VERSION=""; AUTHENTIK_RELEASE_CHANNEL=""
  AUTHENTIK_BOOTSTRAP_EMAIL=""; AUTHENTIK_ERROR_REPORTING=""; AUTHENTIK_ENABLE_DOCKER_SOCKET=""; AUTHENTIK_ALLOW_LOW_RESOURCES=""; AUTHENTIK_UPGRADE_CONFIRMED=""
  AUTHENTIK_CONFIGURE_CADDY=""; AUTHENTIK_CADDY_OVERWRITE_DOMAIN=""; CADDYFILE=""
  log "Loading environment from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  AUTHENTIK_INSTALL_DIR="${AUTHENTIK_INSTALL_DIR:-/opt/authentik}"
  AUTHENTIK_BIND_IP="${AUTHENTIK_BIND_IP:-127.0.0.1}"
  AUTHENTIK_HTTP_PORT="${AUTHENTIK_HTTP_PORT:-9000}"
  AUTHENTIK_HTTPS_PORT="${AUTHENTIK_HTTPS_PORT:-9443}"
  AUTHENTIK_VERSION="${AUTHENTIK_VERSION:-2026.5.5}"
  AUTHENTIK_RELEASE_CHANNEL="${AUTHENTIK_RELEASE_CHANNEL:-2026.5}"
  AUTHENTIK_BOOTSTRAP_EMAIL="${AUTHENTIK_BOOTSTRAP_EMAIL:-}"
  AUTHENTIK_ERROR_REPORTING="${AUTHENTIK_ERROR_REPORTING:-false}"
  AUTHENTIK_ENABLE_DOCKER_SOCKET="${AUTHENTIK_ENABLE_DOCKER_SOCKET:-false}"
  AUTHENTIK_ALLOW_LOW_RESOURCES="${AUTHENTIK_ALLOW_LOW_RESOURCES:-false}"
  AUTHENTIK_UPGRADE_CONFIRMED="${AUTHENTIK_UPGRADE_CONFIRMED:-false}"
  AUTHENTIK_CONFIGURE_CADDY="${AUTHENTIK_CONFIGURE_CADDY:-true}"
  AUTHENTIK_CADDY_OVERWRITE_DOMAIN="${AUTHENTIK_CADDY_OVERWRITE_DOMAIN:-ask}"
  CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
}

validate_bool() { [[ "$2" == true || "$2" == false ]] || fail "$1 must be true or false"; }
site_host() { local value="$AUTHENTIK_URL"; value="${value#https://}"; printf '%s\n' "${value%%/*}"; }
validate_env() {
  [[ "$AUTHENTIK_URL" =~ ^https://[A-Za-z0-9.-]+/?$ ]] || fail "AUTHENTIK_URL must be an HTTPS site URL without a path"
  [[ "$AUTHENTIK_INSTALL_DIR" = /* && "$AUTHENTIK_INSTALL_DIR" != / ]] || fail "AUTHENTIK_INSTALL_DIR must be an absolute non-root path"
  [[ "$AUTHENTIK_BIND_IP" == 127.0.0.1 || "$AUTHENTIK_BIND_IP" == ::1 ]] || fail "AUTHENTIK_BIND_IP must remain a loopback address"
  if [[ ! "$AUTHENTIK_HTTP_PORT" =~ ^[0-9]+$ ]] || (( 10#$AUTHENTIK_HTTP_PORT < 1024 || 10#$AUTHENTIK_HTTP_PORT > 65535 )); then
    fail "AUTHENTIK_HTTP_PORT must be between 1024 and 65535"
  fi
  if [[ ! "$AUTHENTIK_HTTPS_PORT" =~ ^[0-9]+$ ]] || (( 10#$AUTHENTIK_HTTPS_PORT < 1024 || 10#$AUTHENTIK_HTTPS_PORT > 65535 )); then
    fail "AUTHENTIK_HTTPS_PORT must be between 1024 and 65535"
  fi
  [[ "$AUTHENTIK_HTTP_PORT" != "$AUTHENTIK_HTTPS_PORT" ]] || fail "AUTHENTIK_HTTP_PORT and AUTHENTIK_HTTPS_PORT must differ"
  [[ "$AUTHENTIK_VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || fail "AUTHENTIK_VERSION must be an exact version"
  [[ "$AUTHENTIK_RELEASE_CHANNEL" =~ ^[0-9]{4}\.[0-9]+$ && "$AUTHENTIK_VERSION" == "$AUTHENTIK_RELEASE_CHANNEL".* ]] || fail "AUTHENTIK_RELEASE_CHANNEL must match AUTHENTIK_VERSION"
  [[ -z "$AUTHENTIK_BOOTSTRAP_EMAIL" || "$AUTHENTIK_BOOTSTRAP_EMAIL" == *@* ]] || fail "AUTHENTIK_BOOTSTRAP_EMAIL is invalid"
  validate_bool AUTHENTIK_ERROR_REPORTING "$AUTHENTIK_ERROR_REPORTING"
  validate_bool AUTHENTIK_ENABLE_DOCKER_SOCKET "$AUTHENTIK_ENABLE_DOCKER_SOCKET"
  validate_bool AUTHENTIK_ALLOW_LOW_RESOURCES "$AUTHENTIK_ALLOW_LOW_RESOURCES"
  validate_bool AUTHENTIK_UPGRADE_CONFIRMED "$AUTHENTIK_UPGRADE_CONFIRMED"
  validate_bool AUTHENTIK_CONFIGURE_CADDY "$AUTHENTIK_CONFIGURE_CADDY"
  [[ "$AUTHENTIK_CADDY_OVERWRITE_DOMAIN" == ask || "$AUTHENTIK_CADDY_OVERWRITE_DOMAIN" == true || "$AUTHENTIK_CADDY_OVERWRITE_DOMAIN" == false ]] || fail "AUTHENTIK_CADDY_OVERWRITE_DOMAIN must be ask, true, or false"
}

check_platform_and_resources() {
  [[ -r /etc/os-release ]] || fail "/etc/os-release is missing"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || fail "This repository targets Ubuntu 24.04; detected ${PRETTY_NAME:-unknown}"
  local cpu memory_kb; local -a problems=()
  cpu="$(nproc)"; memory_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  (( cpu >= 2 )) || problems+=("at least 2 CPU cores are required")
  (( memory_kb >= 2 * 1024 * 1024 )) || problems+=("at least 2 GB RAM is required")
  log "Resources: ${cpu} CPU, $((memory_kb / 1024 / 1024)) GB RAM"
  if (( ${#problems[@]} )); then printf ' - %s\n' "${problems[@]}" >&2; [[ "$AUTHENTIK_ALLOW_LOW_RESOURCES" == true ]] || fail "Resource preflight failed"; warn "Continuing because AUTHENTIK_ALLOW_LOW_RESOURCES=true"; fi
}

install_docker_and_tools() {
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    log "Installing Docker Engine and Docker Compose plugin from Docker's official repository"
    export DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 NEEDRESTART_MODE=a
    apt-get update; apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install ca-certificates curl gnupg openssl iproute2
    install -d -m 0755 /etc/apt/keyrings
    curl --proto '=https' --tlsv1.2 -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --dearmor -o "$DOCKER_KEYRING"
    chmod 0644 "$DOCKER_KEYRING"
    # shellcheck disable=SC1091
    source /etc/os-release
    printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/ubuntu %s stable\n' "$(dpkg --print-architecture)" "$DOCKER_KEYRING" "$VERSION_CODENAME" > "$DOCKER_SOURCE_LIST"
    apt-get update; apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    local -a packages=(); command -v curl >/dev/null 2>&1 || packages+=(curl); command -v openssl >/dev/null 2>&1 || packages+=(openssl); command -v ss >/dev/null 2>&1 || packages+=(iproute2)
    if (( ${#packages[@]} )); then apt-get update; apt-get install -y "${packages[@]}"; fi
  fi
  systemctl enable --now docker
}

runtime_value() { local key="$1" file="$AUTHENTIK_INSTALL_DIR/.env"; [[ -f "$file" ]] || return 0; sed -n "s/^${key}=//p" "$file" | tail -n 1; }
write_runtime_env() {
  local pg_pass secret token tmp runtime="$AUTHENTIK_INSTALL_DIR/.env"
  pg_pass="$(runtime_value PG_PASS)"; secret="$(runtime_value AUTHENTIK_SECRET_KEY)"; token="$(runtime_value AUTHENTIK_BOOTSTRAP_TOKEN)"
  [[ -n "$pg_pass" ]] || pg_pass="$(openssl rand -hex 32)"
  [[ -n "$secret" ]] || secret="$(openssl rand -hex 64)"
  [[ -n "$token" ]] || token="$(openssl rand -hex 32)"
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
COMPOSE_PROJECT_NAME=authentik
AUTHENTIK_IMAGE=ghcr.io/goauthentik/server
AUTHENTIK_TAG=$AUTHENTIK_VERSION
COMPOSE_PORT_HTTP=$AUTHENTIK_BIND_IP:$AUTHENTIK_HTTP_PORT
COMPOSE_PORT_HTTPS=$AUTHENTIK_BIND_IP:$AUTHENTIK_HTTPS_PORT
PG_PASS=$pg_pass
AUTHENTIK_SECRET_KEY=$secret
AUTHENTIK_ERROR_REPORTING__ENABLED=$AUTHENTIK_ERROR_REPORTING
AUTHENTIK_BOOTSTRAP_TOKEN=$token
AUTHENTIK_BOOTSTRAP_EMAIL=$AUTHENTIK_BOOTSTRAP_EMAIL
EOF
  if [[ -f "$runtime" ]] && ! cmp -s "$tmp" "$runtime"; then cp -a "$runtime" "${runtime}.bak.$(date +%s)"; fi
  install -m 0600 "$tmp" "$runtime"; rm -f "$tmp"
}

download_compose() {
  local url tmp target="$AUTHENTIK_INSTALL_DIR/compose.yml"
  url="https://goauthentik.io/version/${AUTHENTIK_RELEASE_CHANNEL}/lifecycle/container/compose.yml"
  tmp="$AUTHENTIK_INSTALL_DIR/.compose.download.$$"
  log "Downloading official Authentik Compose definition for $AUTHENTIK_RELEASE_CHANNEL"
  curl --proto '=https' --tlsv1.2 --fail --show-error --silent --location --retry 3 --connect-timeout 15 --max-time 120 "$url" -o "$tmp"
  grep -Fq 'ghcr.io/goauthentik/server' "$tmp" || fail "Downloaded file does not reference the official Authentik image"
  if ! grep -Eq '^[[:space:]]+server:' "$tmp" || ! grep -Eq '^[[:space:]]+worker:' "$tmp" || ! grep -Eq '^[[:space:]]+postgresql:' "$tmp"; then
    fail "Downloaded Compose file is missing required services"
  fi
  if [[ "$AUTHENTIK_ENABLE_DOCKER_SOCKET" == false ]]; then
    sed -i '\|/var/run/docker.sock:/var/run/docker.sock|d' "$tmp"
    warn "Docker socket mount is disabled; automatic Docker outpost management will be unavailable"
  fi
  (cd "$AUTHENTIK_INSTALL_DIR" && docker compose --env-file .env -f "$(basename -- "$tmp")" config >/dev/null) || fail "Downloaded Compose file is invalid"
  if [[ -f "$target" ]] && ! cmp -s "$tmp" "$target"; then cp -a "$target" "${target}.bak.$(date +%s)"; fi
  install -m 0644 "$tmp" "$target"; rm -f "$tmp"
}

existing_server_owns_port() {
  local port="$1" id
  [[ -f "$AUTHENTIK_INSTALL_DIR/compose.yml" ]] || return 1
  # shellcheck disable=SC2015
  id="$(cd "$AUTHENTIK_INSTALL_DIR" && docker compose --env-file .env -f compose.yml ps -q server 2>/dev/null || true)"
  [[ -n "$id" ]] || return 1
  docker inspect --format '{{range $p, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostIp .HostPort}}{{end}}{{end}}' "$id" 2>/dev/null | awk -v ip="$AUTHENTIK_BIND_IP" -v port="$port" '$1 == ip && $2 == port {found=1} END {exit !found}'
}
check_ports() {
  local port
  for port in "$AUTHENTIK_HTTP_PORT" "$AUTHENTIK_HTTPS_PORT"; do
    if ss -H -ltn "( sport = :$port )" | grep -q . && ! existing_server_owns_port "$port"; then
      fail "Port $port is already occupied by another service"
    fi
  done
}

preflight_upgrade() {
  local id current_image desired_image="ghcr.io/goauthentik/server:$AUTHENTIK_VERSION"
  # shellcheck disable=SC2015
  id="$(cd "$AUTHENTIK_INSTALL_DIR" && docker compose --env-file .env -f compose.yml ps -q server 2>/dev/null || true)"
  [[ -n "$id" ]] || return 0
  current_image="$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null || true)"
  [[ -n "$current_image" && "$current_image" != "$desired_image" ]] || return 0
  if [[ "$AUTHENTIK_UPGRADE_CONFIRMED" != true ]]; then
    fail "Authentik image change detected: $current_image -> $desired_image. Create and verify database/configuration backups, then set AUTHENTIK_UPGRADE_CONFIRMED=true for the upgrade run."
  fi
  warn "Proceeding with the confirmed Authentik upgrade: $current_image -> $desired_image"
}

caddy_block_for_host() {
  local host="$1"; [[ -f "$CADDYFILE" ]] || return 0
  awk -v host="$host" 'function nchar(s,c,i,n){for(i=1;i<=length(s);i++)if(substr(s,i,1)==c)n++;return n}{line=$0;trim=line;gsub(/^[ \t]+|[ \t]+$/,"",trim);if(!inside&&trim~/\{$/){labels=trim;sub(/[ \t]*\{$/,"",labels);gsub(/[ \t]/,"",labels);count=split(labels,a,",");for(i=1;i<=count;i++)if(a[i]==host){inside=1;depth=0}}if(inside){print line;depth+=nchar(line,"{")-nchar(line,"}");if(depth<=0)exit}}' "$CADDYFILE"
}
preflight_caddy() {
  [[ "$AUTHENTIK_CONFIGURE_CADDY" == true ]] || return 0; require_cmd caddy
  local host block answer; host="$(site_host)"; [[ -f "$CADDYFILE" ]] || return 0
  grep -Fq "$CADDY_MANAGED_PREFIX $host" "$CADDYFILE" && return 0
  block="$(caddy_block_for_host "$host")"; [[ -z "$block" ]] && return 0
  grep -Eq "reverse_proxy (http://)?(${AUTHENTIK_BIND_IP}|localhost):${AUTHENTIK_HTTP_PORT}([[:space:]]|$)" <<< "$block" && { CADDY_KEEP_EXISTING=true; return; }
  case "$AUTHENTIK_CADDY_OVERWRITE_DOMAIN" in
    true) log "The existing Caddy block for $host is approved for replacement" ;;
    false) fail "Caddyfile already contains an unmanaged block for $host" ;;
    ask) printf 'Caddy domain %s already exists. Replace it with Authentik? [y/N] ' "$host"; read -r answer || answer=""; [[ "$answer" =~ ^([yY]|yes|YES)$ ]] || fail "Caddy block was not replaced" ;;
  esac
}
remove_caddy_blocks() {
  local host="$1" output="$2"
  awk -v host="$host" -v begin="$CADDY_MANAGED_PREFIX $host" -v end="$CADDY_MANAGED_SUFFIX $host" 'function nchar(s,c,i,n){for(i=1;i<=length(s);i++)if(substr(s,i,1)==c)n++;return n}$0==begin{managed=1;next}managed{if($0==end)managed=0;next}{line=$0;trim=line;gsub(/^[ \t]+|[ \t]+$/,"",trim);if(!skip&&trim~/\{$/){labels=trim;sub(/[ \t]*\{$/,"",labels);gsub(/[ \t]/,"",labels);count=split(labels,a,",");for(i=1;i<=count;i++)if(a[i]==host){skip=1;depth=nchar(line,"{")-nchar(line,"}");next}}if(skip){depth+=nchar(line,"{")-nchar(line,"}");if(depth<=0)skip=0;next}print}' "$CADDYFILE" > "$output"
}
configure_caddy() {
  [[ "$AUTHENTIK_CONFIGURE_CADDY" == true ]] || return 0
  [[ "${CADDY_KEEP_EXISTING:-false}" != true ]] || { log "Keeping compatible existing Caddy block"; return; }
  local host backup tmp; host="$(site_host)"; tmp="$(mktemp)"
  install -d -m 0755 "$(dirname -- "$CADDYFILE")"; [[ -f "$CADDYFILE" ]] || touch "$CADDYFILE"
  backup="${CADDYFILE}.bak.$(date +%s)"; cp -a "$CADDYFILE" "$backup"
  remove_caddy_blocks "$host" "$tmp"; install -m 0644 "$tmp" "$CADDYFILE"; rm -f "$tmp"
  cat >> "$CADDYFILE" <<EOF

$CADDY_MANAGED_PREFIX $host
$host {
    encode zstd gzip
    reverse_proxy ${AUTHENTIK_BIND_IP}:${AUTHENTIK_HTTP_PORT}
}
$CADDY_MANAGED_SUFFIX $host
EOF
  if ! caddy validate --config "$CADDYFILE"; then cp -a "$backup" "$CADDYFILE"; fail "Caddy validation failed; restored $backup"; fi
  if ! systemctl reload caddy; then cp -a "$backup" "$CADDYFILE"; caddy validate --config "$CADDYFILE" >/dev/null && systemctl reload caddy; fail "Caddy reload failed; restored $backup"; fi
}

start_and_wait() {
  local code
  (cd "$AUTHENTIK_INSTALL_DIR" && docker compose --env-file .env -f compose.yml pull && docker compose --env-file .env -f compose.yml up -d)
  log "Waiting for Authentik startup"
  for _ in {1..90}; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 "http://${AUTHENTIK_BIND_IP}:${AUTHENTIK_HTTP_PORT}/-/health/ready/" || true)"
    [[ "$code" == 200 ]] && { log "Authentik readiness endpoint is healthy"; return; }
    sleep 5
  done
  (cd "$AUTHENTIK_INSTALL_DIR" && docker compose --env-file .env -f compose.yml logs --tail 100 server worker) >&2 || true
  fail "Authentik did not become ready within 7.5 minutes"
}

main() {
  require_root; require_cmd apt-get; load_env; validate_env; check_platform_and_resources; install_docker_and_tools
  install -d -m 0750 "$AUTHENTIK_INSTALL_DIR"; write_runtime_env; download_compose; check_ports; preflight_upgrade; preflight_caddy; start_and_wait; configure_caddy
  log "Authentik is available at $AUTHENTIK_URL"
  warn "On a new install, set the akadmin password at ${AUTHENTIK_URL%/}/if/flow/initial-setup/"
  log "The generated bootstrap API token is stored only in $AUTHENTIK_INSTALL_DIR/.env (mode 0600)"
  log "Run diagnostics: cd ~/ubuntu-scripts/authentik && bash check-setup.sh"
}
main "$@"
