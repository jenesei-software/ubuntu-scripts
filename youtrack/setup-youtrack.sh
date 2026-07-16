#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_SOURCE_LIST="/etc/apt/sources.list.d/docker.list"
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts youtrack"
CADDY_MANAGED_SUFFIX="# END ubuntu-scripts youtrack"

LOG_COLOR='\033[1;36m'
LOG_RESET='\033[0m'
timestamp() { date '+%F %T'; }
log_line() { local level="$1"; shift; printf '%b[%s] %-7s%b %s\n' "$LOG_COLOR" "$(timestamp)" "$level" "$LOG_RESET" "$*"; }
log() { log_line INFO "$*"; }
warn() { log_line WARN "$*"; }
fail() { log_line ERROR "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/youtrack && bash setup-youtrack.sh"; }
on_error() { local code=$?; log_line ERROR "Setup failed at line ${BASH_LINENO[0]:-${LINENO}}: ${BASH_COMMAND:-unknown} (exit $code)" >&2; }
trap on_error ERR

resolve_env_path() {
  local candidate="$1"
  if [[ "$candidate" = /* ]]; then printf '%s\n' "$candidate"
  elif [[ -f "$candidate" ]]; then printf '%s/%s\n' "$(cd -- "$(dirname -- "$candidate")" && pwd)" "$(basename -- "$candidate")"
  else printf '%s/%s\n' "$SCRIPT_DIR" "$candidate"; fi
}

load_env() {
  if [[ -n "$ENV_FILE_INPUT" ]]; then ENV_FILE="$(resolve_env_path "$ENV_FILE_INPUT")"; else ENV_FILE="$SCRIPT_DIR/.env"; fi
  [[ -f "$ENV_FILE" ]] || fail "Environment file not found. Copy youtrack/env.example to youtrack/.env"

  YOUTRACK_URL=""; YOUTRACK_INSTALL_DIR=""; YOUTRACK_BIND_IP=""; YOUTRACK_PORT=""
  YOUTRACK_IMAGE=""; YOUTRACK_CONTAINER_NAME=""; YOUTRACK_TIMEZONE=""; YOUTRACK_MIN_FREE_GB=""
  YOUTRACK_ALLOW_LOW_RESOURCES=""; YOUTRACK_UPGRADE_CONFIRMED=""; YOUTRACK_CONFIGURE_CADDY=""; YOUTRACK_CADDY_OVERWRITE_DOMAIN=""; CADDYFILE=""
  log "Loading environment from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  YOUTRACK_INSTALL_DIR="${YOUTRACK_INSTALL_DIR:-/opt/youtrack}"
  YOUTRACK_BIND_IP="${YOUTRACK_BIND_IP:-127.0.0.1}"
  YOUTRACK_PORT="${YOUTRACK_PORT:-8080}"
  YOUTRACK_IMAGE="${YOUTRACK_IMAGE:-jetbrains/youtrack:2026.2.17765}"
  YOUTRACK_CONTAINER_NAME="${YOUTRACK_CONTAINER_NAME:-youtrack}"
  YOUTRACK_TIMEZONE="${YOUTRACK_TIMEZONE:-UTC}"
  YOUTRACK_MIN_FREE_GB="${YOUTRACK_MIN_FREE_GB:-20}"
  YOUTRACK_ALLOW_LOW_RESOURCES="${YOUTRACK_ALLOW_LOW_RESOURCES:-false}"
  YOUTRACK_UPGRADE_CONFIRMED="${YOUTRACK_UPGRADE_CONFIRMED:-false}"
  YOUTRACK_CONFIGURE_CADDY="${YOUTRACK_CONFIGURE_CADDY:-true}"
  YOUTRACK_CADDY_OVERWRITE_DOMAIN="${YOUTRACK_CADDY_OVERWRITE_DOMAIN:-ask}"
  CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
}

validate_bool() { [[ "$2" == true || "$2" == false ]] || fail "$1 must be true or false"; }
site_host() { local value="$YOUTRACK_URL"; value="${value#http://}"; value="${value#https://}"; printf '%s\n' "${value%%/*}"; }

validate_env() {
  [[ "$YOUTRACK_URL" =~ ^https://[A-Za-z0-9.-]+/?$ ]] || fail "YOUTRACK_URL must be an HTTPS site URL without a path"
  [[ "$YOUTRACK_INSTALL_DIR" = /* && "$YOUTRACK_INSTALL_DIR" != / ]] || fail "YOUTRACK_INSTALL_DIR must be an absolute non-root path"
  [[ "$YOUTRACK_BIND_IP" == 127.0.0.1 || "$YOUTRACK_BIND_IP" == ::1 ]] || fail "YOUTRACK_BIND_IP must remain a loopback address"
  if [[ ! "$YOUTRACK_PORT" =~ ^[0-9]+$ ]] || (( 10#$YOUTRACK_PORT < 1024 || 10#$YOUTRACK_PORT > 65535 )); then
    fail "YOUTRACK_PORT must be between 1024 and 65535"
  fi
  [[ "$YOUTRACK_MIN_FREE_GB" =~ ^[0-9]+$ ]] || fail "YOUTRACK_MIN_FREE_GB must be an integer"
  [[ "$YOUTRACK_IMAGE" =~ ^jetbrains/youtrack:[A-Za-z0-9._-]+$ ]] || fail "YOUTRACK_IMAGE must use the official jetbrains/youtrack image with an explicit tag"
  [[ "$YOUTRACK_CONTAINER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]+$ ]] || fail "YOUTRACK_CONTAINER_NAME is invalid"
  validate_bool YOUTRACK_ALLOW_LOW_RESOURCES "$YOUTRACK_ALLOW_LOW_RESOURCES"
  validate_bool YOUTRACK_UPGRADE_CONFIRMED "$YOUTRACK_UPGRADE_CONFIRMED"
  validate_bool YOUTRACK_CONFIGURE_CADDY "$YOUTRACK_CONFIGURE_CADDY"
  [[ "$YOUTRACK_CADDY_OVERWRITE_DOMAIN" == ask || "$YOUTRACK_CADDY_OVERWRITE_DOMAIN" == true || "$YOUTRACK_CADDY_OVERWRITE_DOMAIN" == false ]] || fail "YOUTRACK_CADDY_OVERWRITE_DOMAIN must be ask, true, or false"
}

check_platform_and_resources() {
  [[ -r /etc/os-release ]] || fail "/etc/os-release is missing"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || fail "This repository targets Ubuntu 24.04; detected ${PRETTY_NAME:-unknown}"

  local cpu memory_kb parent available_kb required_kb
  local -a problems=()
  cpu="$(nproc)"; memory_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  parent="$(dirname -- "$YOUTRACK_INSTALL_DIR")"; while [[ ! -d "$parent" && "$parent" != / ]]; do parent="$(dirname -- "$parent")"; done
  available_kb="$(df -Pk "$parent" | awk 'NR == 2 {print $4}')"; required_kb=$((10#$YOUTRACK_MIN_FREE_GB * 1024 * 1024))
  (( cpu >= 2 )) || problems+=("at least 2 CPU cores are recommended")
  (( memory_kb >= 2 * 1024 * 1024 )) || problems+=("at least 2 GB RAM is required")
  (( available_kb >= required_kb )) || problems+=("at least $YOUTRACK_MIN_FREE_GB GB free disk space is required")
  log "Resources: ${cpu} CPU, $((memory_kb / 1024 / 1024)) GB RAM, $((available_kb / 1024 / 1024)) GB free"
  if (( ${#problems[@]} )); then printf ' - %s\n' "${problems[@]}" >&2; [[ "$YOUTRACK_ALLOW_LOW_RESOURCES" == true ]] || fail "Resource preflight failed"; warn "Continuing because YOUTRACK_ALLOW_LOW_RESOURCES=true"; fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then systemctl enable --now docker; return; fi
  log "Installing Docker Engine and Docker Compose plugin from Docker's official repository"
  export DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 NEEDRESTART_MODE=a
  apt-get update
  apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install ca-certificates curl gnupg
  install -d -m 0755 /etc/apt/keyrings
  curl --proto '=https' --tlsv1.2 -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --dearmor -o "$DOCKER_KEYRING"
  chmod 0644 "$DOCKER_KEYRING"
  # shellcheck disable=SC1091
  source /etc/os-release
  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/ubuntu %s stable\n' "$(dpkg --print-architecture)" "$DOCKER_KEYRING" "$VERSION_CODENAME" > "$DOCKER_SOURCE_LIST"
  apt-get update
  apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin curl
  systemctl enable --now docker
}

port_is_owned_by_container() {
  docker inspect --format '{{range $p, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostIp .HostPort}}{{end}}{{end}}' "$YOUTRACK_CONTAINER_NAME" 2>/dev/null | awk -v ip="$YOUTRACK_BIND_IP" -v port="$YOUTRACK_PORT" '$1 == ip && $2 == port {found=1} END {exit !found}'
}

check_port() {
  command -v ss >/dev/null 2>&1 || { apt-get update; apt-get install -y iproute2; }
  if ss -H -ltn "( sport = :$YOUTRACK_PORT )" | grep -q . && ! port_is_owned_by_container; then fail "Port $YOUTRACK_PORT is already occupied by another service"; fi
}

preflight_upgrade() {
  local current_image
  current_image="$(docker inspect --format '{{.Config.Image}}' "$YOUTRACK_CONTAINER_NAME" 2>/dev/null || true)"
  [[ -n "$current_image" && "$current_image" != "$YOUTRACK_IMAGE" ]] || return 0
  if [[ "$YOUTRACK_UPGRADE_CONFIRMED" != true ]]; then
    fail "YouTrack image change detected: $current_image -> $YOUTRACK_IMAGE. Create and verify an off-host backup, then set YOUTRACK_UPGRADE_CONFIRMED=true for the upgrade run."
  fi
  warn "Proceeding with the confirmed YouTrack upgrade: $current_image -> $YOUTRACK_IMAGE"
}

write_compose() {
  local tmp compose="$YOUTRACK_INSTALL_DIR/docker-compose.yml"
  install -d -m 0755 "$YOUTRACK_INSTALL_DIR" "$YOUTRACK_INSTALL_DIR/data" "$YOUTRACK_INSTALL_DIR/conf" "$YOUTRACK_INSTALL_DIR/logs" "$YOUTRACK_INSTALL_DIR/backups"
  chown -R 13001:13001 "$YOUTRACK_INSTALL_DIR/data" "$YOUTRACK_INSTALL_DIR/conf" "$YOUTRACK_INSTALL_DIR/logs" "$YOUTRACK_INSTALL_DIR/backups"
  chmod 0750 "$YOUTRACK_INSTALL_DIR/data" "$YOUTRACK_INSTALL_DIR/conf" "$YOUTRACK_INSTALL_DIR/logs" "$YOUTRACK_INSTALL_DIR/backups"
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
services:
  youtrack:
    image: $YOUTRACK_IMAGE
    container_name: $YOUTRACK_CONTAINER_NAME
    restart: unless-stopped
    stop_grace_period: 2m
    ports:
      - "$YOUTRACK_BIND_IP:$YOUTRACK_PORT:8080"
    environment:
      TZ: "$YOUTRACK_TIMEZONE"
    volumes:
      - "$YOUTRACK_INSTALL_DIR/data:/opt/youtrack/data"
      - "$YOUTRACK_INSTALL_DIR/conf:/opt/youtrack/conf"
      - "$YOUTRACK_INSTALL_DIR/logs:/opt/youtrack/logs"
      - "$YOUTRACK_INSTALL_DIR/backups:/opt/youtrack/backups"
EOF
  docker compose -f "$tmp" config >/dev/null || fail "Generated Docker Compose file is invalid"
  if [[ -f "$compose" ]] && ! cmp -s "$tmp" "$compose"; then cp -a "$compose" "${compose}.bak.$(date +%s)"; fi
  install -m 0644 "$tmp" "$compose"; rm -f "$tmp"
}

caddy_block_for_host() {
  local host="$1"; [[ -f "$CADDYFILE" ]] || return 0
  awk -v host="$host" '
    function nchar(s,c,i,n){for(i=1;i<=length(s);i++)if(substr(s,i,1)==c)n++;return n}
    { line=$0; trim=line; gsub(/^[ \t]+|[ \t]+$/, "", trim)
      if(!inside && trim ~ /\{$/){labels=trim;sub(/[ \t]*\{$/,"",labels);gsub(/[ \t]/,"",labels);count=split(labels,a,",");for(i=1;i<=count;i++)if(a[i]==host){inside=1;depth=0}}
      if(inside){print line;depth+=nchar(line,"{")-nchar(line,"}");if(depth<=0)exit}}
  ' "$CADDYFILE"
}

preflight_caddy() {
  [[ "$YOUTRACK_CONFIGURE_CADDY" == true ]] || return 0
  require_cmd caddy
  local host block answer; host="$(site_host)"; [[ -f "$CADDYFILE" ]] || return 0
  grep -Fq "$CADDY_MANAGED_PREFIX $host" "$CADDYFILE" && return 0
  block="$(caddy_block_for_host "$host")"; [[ -z "$block" ]] && return 0
  grep -Eq "reverse_proxy (http://)?(${YOUTRACK_BIND_IP}|localhost):${YOUTRACK_PORT}([[:space:]]|$)" <<< "$block" && { CADDY_KEEP_EXISTING=true; return; }
  case "$YOUTRACK_CADDY_OVERWRITE_DOMAIN" in
    true) log "The existing Caddy block for $host is approved for replacement" ;;
    false) fail "Caddyfile already contains an unmanaged block for $host" ;;
    ask) printf 'Caddy domain %s already exists. Replace it with YouTrack? [y/N] ' "$host"; read -r answer || answer=""; [[ "$answer" =~ ^([yY]|yes|YES)$ ]] || fail "Caddy block was not replaced" ;;
  esac
}

remove_caddy_blocks() {
  local host="$1" output="$2"
  awk -v host="$host" -v begin="$CADDY_MANAGED_PREFIX $host" -v end="$CADDY_MANAGED_SUFFIX $host" '
    function nchar(s,c,i,n){for(i=1;i<=length(s);i++)if(substr(s,i,1)==c)n++;return n}
    $0==begin{managed=1;next} managed{if($0==end)managed=0;next}
    {line=$0;trim=line;gsub(/^[ \t]+|[ \t]+$/, "",trim)
     if(!skip && trim~/\{$/){labels=trim;sub(/[ \t]*\{$/,"",labels);gsub(/[ \t]/,"",labels);count=split(labels,a,",");for(i=1;i<=count;i++)if(a[i]==host){skip=1;depth=nchar(line,"{")-nchar(line,"}");next}}
     if(skip){depth+=nchar(line,"{")-nchar(line,"}");if(depth<=0)skip=0;next} print}
  ' "$CADDYFILE" > "$output"
}

configure_caddy() {
  [[ "$YOUTRACK_CONFIGURE_CADDY" == true ]] || return 0
  [[ "${CADDY_KEEP_EXISTING:-false}" != true ]] || { log "Keeping compatible existing Caddy block"; return; }
  local host backup tmp; host="$(site_host)"; backup=""; tmp="$(mktemp)"
  install -d -m 0755 "$(dirname -- "$CADDYFILE")"; [[ -f "$CADDYFILE" ]] || touch "$CADDYFILE"
  backup="${CADDYFILE}.bak.$(date +%s)"; cp -a "$CADDYFILE" "$backup"
  remove_caddy_blocks "$host" "$tmp"; install -m 0644 "$tmp" "$CADDYFILE"; rm -f "$tmp"
  cat >> "$CADDYFILE" <<EOF

$CADDY_MANAGED_PREFIX $host
$host {
    encode zstd gzip
    reverse_proxy ${YOUTRACK_BIND_IP}:${YOUTRACK_PORT}
}
$CADDY_MANAGED_SUFFIX $host
EOF
  if ! caddy validate --config "$CADDYFILE"; then cp -a "$backup" "$CADDYFILE"; fail "Caddy validation failed; restored $backup"; fi
  if ! systemctl reload caddy; then cp -a "$backup" "$CADDYFILE"; caddy validate --config "$CADDYFILE" >/dev/null && systemctl reload caddy; fail "Caddy reload failed; restored $backup"; fi
}

start_and_wait() {
  local compose="$YOUTRACK_INSTALL_DIR/docker-compose.yml" code
  docker compose -f "$compose" pull
  docker compose -f "$compose" up -d
  log "Waiting for YouTrack startup"
  for _ in {1..60}; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 "http://${YOUTRACK_BIND_IP}:${YOUTRACK_PORT}/" || true)"
    [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]] && { log "YouTrack local endpoint is ready (HTTP $code)"; return; }
    sleep 5
  done
  docker logs --tail 80 "$YOUTRACK_CONTAINER_NAME" >&2 || true
  fail "YouTrack did not become ready within 5 minutes"
}

main() {
  require_root; require_cmd apt-get; load_env; validate_env; check_platform_and_resources
  install_docker; require_cmd curl; check_port; preflight_upgrade; preflight_caddy; write_compose; start_and_wait; configure_caddy
  log "YouTrack is available at $YOUTRACK_URL"
  warn "On a new install, finish the JetBrains configuration wizard and set Base URL to $YOUTRACK_URL"
  warn "Retrieve the one-time wizard URL only in your terminal: docker logs $YOUTRACK_CONTAINER_NAME 2>&1 | grep -m1 wizard_token"
  log "Run diagnostics: cd ~/ubuntu-scripts/youtrack && bash check-setup.sh"
}

main "$@"
