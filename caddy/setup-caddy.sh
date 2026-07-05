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

log() { log_line "INFO" "$*"; }
fail() { log_line "ERROR" "$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/caddy && bash setup-caddy.sh"; }
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
    log "Environment file not found, installing Caddy without replacing Caddyfile"
    return
  fi

  [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
  log "Loading environment from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
}

validate_caddy_env() {
  if [[ -z "${CADDY_DOMAIN:-}" && -z "${CADDY_UPSTREAM:-}" ]]; then
    return
  fi

  [[ -n "${CADDY_DOMAIN:-}" ]] || fail "CADDY_DOMAIN is required when CADDY_UPSTREAM is set"
  [[ -n "${CADDY_UPSTREAM:-}" ]] || fail "CADDY_UPSTREAM is required when CADDY_DOMAIN is set"
  [[ "$CADDY_UPSTREAM" =~ ^https?:// ]] || fail "CADDY_UPSTREAM must start with http:// or https://"
}

install_caddy() {
  log "Installing Caddy from the official apt repository"
  export DEBIAN_FRONTEND=noninteractive
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a

  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install debian-keyring debian-archive-keyring apt-transport-https ca-certificates curl gnupg ufw

  curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" \
    | gpg --batch --yes --dearmor -o "$CADDY_KEYRING"
  chmod 0644 "$CADDY_KEYRING"

  curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt" -o "$CADDY_SOURCE_LIST"
  chmod 0644 "$CADDY_SOURCE_LIST"

  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install caddy
}

configure_firewall() {
  log "Allowing HTTP and HTTPS in UFW"
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw reload || true
}

write_caddyfile() {
  [[ -n "${CADDY_DOMAIN:-}" && -n "${CADDY_UPSTREAM:-}" ]] || {
    log "CADDY_DOMAIN and CADDY_UPSTREAM are empty, keeping existing Caddyfile"
    return
  }

  log "Writing Caddyfile for $CADDY_DOMAIN -> $CADDY_UPSTREAM"
  install -d -m 0755 "$(dirname -- "$CADDYFILE")"

  if [[ -f "$CADDYFILE" ]]; then
    cp "$CADDYFILE" "${CADDYFILE}.bak.$(date +%s)"
  fi

  if [[ -n "${CADDY_EMAIL:-}" ]]; then
    cat > "$CADDYFILE" <<EOF
{
    email $CADDY_EMAIL
}

$CADDY_DOMAIN {
    encode zstd gzip
    reverse_proxy $CADDY_UPSTREAM
}
EOF
  else
    cat > "$CADDYFILE" <<EOF
$CADDY_DOMAIN {
    encode zstd gzip
    reverse_proxy $CADDY_UPSTREAM
}
EOF
  fi

  caddy validate --config "$CADDYFILE"
}

restart_caddy() {
  log "Enabling Caddy service"
  systemctl enable --now caddy

  if systemctl reload caddy 2>/dev/null; then
    log "Caddy reloaded"
  else
    log "Caddy reload failed, restarting service"
    systemctl restart caddy
  fi
}

main() {
  require_root
  require_cmd apt-get
  require_cmd systemctl
  load_env
  validate_caddy_env
  install_caddy
  configure_firewall
  write_caddyfile
  restart_caddy

  log "Done. Caddy version: $(caddy version)"
}

main "$@"
