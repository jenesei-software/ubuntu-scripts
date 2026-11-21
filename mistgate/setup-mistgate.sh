#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"

RELEASES_REPO="Mistgate/mistgate"
RELEASES_DOWNLOAD_BASE="https://github.com/${RELEASES_REPO}/releases/download"
RELEASES_API_URL="https://api.github.com/repos/${RELEASES_REPO}/releases?per_page=100"

# Release trust root of the official Mistgate builds. The same Ed25519 key signs
# the node bundle (raw signature) and the panel manifest (Ed25519ctx / SSHSIG).
OFFICIAL_RELEASE_KEY_BASE64="6ylEpIbbde2c7e7FcaC/Wc5DAmHfOHsPsOqiB8HaU3c="
OFFICIAL_RELEASE_SSH_KEY_BASE64="AAAAC3NzaC1lZDI1NTE5AAAAIOspRKSG23XtnO3uxXGgv1nOQwJh3zh7D7DqogfB2lN3"
PANEL_SSH_NAMESPACE="mistgate-panel-manifest-v1"
PANEL_SIGNATURE_CONTEXT="mistgate panel manifest v1"

UNIT_NAME="mistgate.service"
UNIT_FILE="/etc/systemd/system/mistgate.service"
CONFIG_DIR="/etc/mistgate"
ADMIN_URL_FILE="$CONFIG_DIR/admin-url"
UPDATE_CHANNEL_FILE="$CONFIG_DIR/panel-update-channel"
DECOY_SITES_DIR="$SCRIPT_DIR/decoy-sites"

CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts mistgate"
CADDY_MANAGED_SUFFIX="# END ubuntu-scripts mistgate"

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
ok() { log_line "OK" "$*"; }
section() { echo; log_line "SECTION" "$*"; }
fail() { log_line "ERROR" "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  log_line "ERROR" "Setup failed at line ${BASH_LINENO[0]:-${LINENO}}: ${BASH_COMMAND:-unknown} (exit $exit_code)" >&2
}
trap on_error ERR

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/mistgate && bash setup-mistgate.sh"
}
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

reset_env_vars() {
  MISTGATE_PUBLIC_URL=""
  MISTGATE_ADMIN_MODE=""
  MISTGATE_ADMIN_HOST=""
  MISTGATE_ADMIN_LISTEN=""
  MISTGATE_TLS_MODE=""
  MISTGATE_ACME_EMAIL=""
  MISTGATE_ACME_DOMAINS=""
  MISTGATE_ACME_HTTP=":80"
  MISTGATE_TLS_CERT=""
  MISTGATE_TLS_KEY=""
  MISTGATE_AGENT_PORT=""
  MISTGATE_AGENT_ADDR=""
  MISTGATE_DECOY_DIR="/srv/mistgate-decoy"
  MISTGATE_DECOY_SITE=""
  DECOY_SITE_CHOSEN=""
  MISTGATE_DATA_DIR=""
  MISTGATE_BIN_DIR=""
  MISTGATE_VERSION=""
  MISTGATE_CHANNEL=""
  MISTGATE_RELEASE_PUBLIC_KEY_BASE64=""
  MISTGATE_RELEASE_PUBLIC_KEY_SSH_BASE64=""
  MISTGATE_ALLOW_UNSIGNED_RELEASE=""
  MISTGATE_CONFIGURE_UFW=""
  MISTGATE_MIN_FREE_GB=""
  MISTGATE_ALLOW_LOW_RESOURCES=""
  MISTGATE_CADDY_OVERWRITE_DOMAIN=""
  MISTGATE_AGENT_PORT=""
  CADDYFILE=""
}

load_env() {
  if [[ -n "$ENV_FILE_INPUT" ]]; then
    ENV_FILE="$(resolve_env_path "$ENV_FILE_INPUT")"
  elif [[ -f "$SCRIPT_DIR/.env" ]]; then
    ENV_FILE="$SCRIPT_DIR/.env"
  else
    fail "Environment file not found. Copy mistgate/env.example to mistgate/.env or run: cd mistgate && cp env.example .env"
  fi
  [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
  log "Loading environment from $ENV_FILE"

  reset_env_vars
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  MISTGATE_PUBLIC_URL="${MISTGATE_PUBLIC_URL%/}"
  MISTGATE_ADMIN_MODE="${MISTGATE_ADMIN_MODE:-path}"
  MISTGATE_ADMIN_LISTEN="${MISTGATE_ADMIN_LISTEN:-127.0.0.1:8081}"
  MISTGATE_TLS_MODE="${MISTGATE_TLS_MODE:-acme}"
  MISTGATE_AGENT_PORT="${MISTGATE_AGENT_PORT:-8443}"
  MISTGATE_DECOY_SITE="${MISTGATE_DECOY_SITE:-auto}"
  MISTGATE_DATA_DIR="${MISTGATE_DATA_DIR:-/var/lib/mistgate}"
  MISTGATE_BIN_DIR="${MISTGATE_BIN_DIR:-/usr/local/bin}"
  MISTGATE_CHANNEL="${MISTGATE_CHANNEL:-stable}"
  MISTGATE_CONFIGURE_UFW="${MISTGATE_CONFIGURE_UFW:-true}"
  MISTGATE_MIN_FREE_GB="${MISTGATE_MIN_FREE_GB:-3}"
  MISTGATE_ALLOW_LOW_RESOURCES="${MISTGATE_ALLOW_LOW_RESOURCES:-false}"
  MISTGATE_ALLOW_UNSIGNED_RELEASE="${MISTGATE_ALLOW_UNSIGNED_RELEASE:-false}"
  MISTGATE_CADDY_OVERWRITE_DOMAIN="${MISTGATE_CADDY_OVERWRITE_DOMAIN:-ask}"
  CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"

  MISTGATE_RELEASE_PUBLIC_KEY_BASE64="${MISTGATE_RELEASE_PUBLIC_KEY_BASE64:-$OFFICIAL_RELEASE_KEY_BASE64}"
  MISTGATE_RELEASE_PUBLIC_KEY_SSH_BASE64="${MISTGATE_RELEASE_PUBLIC_KEY_SSH_BASE64:-$OFFICIAL_RELEASE_SSH_KEY_BASE64}"
}

validate_bool() {
  local name="$1"
  local value="$2"
  [[ "$value" == "true" || "$value" == "false" ]] || fail "$name must be true or false"
}

validate_port() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be numeric"
  (( 10#$value >= 1 && 10#$value <= 65535 )) || fail "$name must be between 1 and 65535"
}

validate_abs_path() {
  local name="$1"
  local value="$2"
  [[ "$value" == /* && "$value" != "/" ]] || fail "$name must be an absolute non-root path"
  [[ "$value" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "$name may contain only letters, digits and . _ - /"
  [[ "$value" != /home && "$value" != /home/* && "$value" != /root && "$value" != /root/* ]] \
    || fail "$name cannot live under /home or /root because the service has ProtectHome=yes"
}

valid_hostname() {
  local value="$1"
  local label
  local -a labels
  [[ ${#value} -le 253 && "$value" =~ ^[A-Za-z0-9.-]+$ && "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
  local IFS=.
  read -r -a labels <<< "$value"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

site_host() {
  local value="$MISTGATE_PUBLIC_URL"
  value="${value#https://}"
  value="${value%%/*}"
  printf '%s\n' "$value"
}

validate_host_list() {
  local raw="$1"
  local item
  local -a items
  [[ -z "$raw" ]] && return
  IFS=',' read -r -a items <<< "$raw"
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n "$item" ]] || fail "MISTGATE_ACME_DOMAINS contains an empty entry"
    valid_hostname "$item" || fail "MISTGATE_ACME_DOMAINS contains an invalid hostname: $item"
  done
}

validate_env() {
  [[ -n "$MISTGATE_PUBLIC_URL" ]] || fail "MISTGATE_PUBLIC_URL is required, for example https://panel.example.com"
  [[ "$MISTGATE_PUBLIC_URL" =~ ^https://[A-Za-z0-9.-]+/?$ ]] \
    || fail "MISTGATE_PUBLIC_URL must be a bare HTTPS URL without a path, port, query or fragment"
  valid_hostname "$(site_host)" || fail "MISTGATE_PUBLIC_URL host is not a valid hostname"

  case "$MISTGATE_ADMIN_MODE" in
    path) ;;
    host)
      [[ -n "$MISTGATE_ADMIN_HOST" ]] || fail "MISTGATE_ADMIN_HOST is required when MISTGATE_ADMIN_MODE=host"
      valid_hostname "$MISTGATE_ADMIN_HOST" || fail "MISTGATE_ADMIN_HOST is not a valid hostname"
      [[ "$MISTGATE_ADMIN_HOST" != "$(site_host)" ]] || fail "MISTGATE_ADMIN_HOST must differ from the public host"
      ;;
    listen)
      [[ "$MISTGATE_ADMIN_LISTEN" =~ ^127\.0\.0\.1:[0-9]+$ ]] \
        || fail "MISTGATE_ADMIN_LISTEN must be a loopback address such as 127.0.0.1:8081"
      validate_port MISTGATE_ADMIN_LISTEN "${MISTGATE_ADMIN_LISTEN##*:}"
      ;;
    *) fail "MISTGATE_ADMIN_MODE must be path, host or listen" ;;
  esac

  case "$MISTGATE_TLS_MODE" in
    acme)
      if [[ -n "$MISTGATE_ACME_EMAIL" ]]; then
        [[ "$MISTGATE_ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
          || fail "MISTGATE_ACME_EMAIL is not a valid email address"
      fi
      if [[ -n "$MISTGATE_ACME_HTTP" && "$MISTGATE_ACME_HTTP" != :* ]]; then
        fail "MISTGATE_ACME_HTTP must be a port such as :80 or empty"
      fi
      if [[ "$MISTGATE_ACME_HTTP" =~ ^:[0-9]+$ ]]; then
        validate_port MISTGATE_ACME_HTTP "${MISTGATE_ACME_HTTP#:}"
      fi
      ;;
    files)
      [[ -n "$MISTGATE_TLS_CERT" && -n "$MISTGATE_TLS_KEY" ]] \
        || fail "MISTGATE_TLS_CERT and MISTGATE_TLS_KEY are required when MISTGATE_TLS_MODE=files"
      [[ -r "$MISTGATE_TLS_CERT" ]] || fail "MISTGATE_TLS_CERT is not readable: $MISTGATE_TLS_CERT"
      [[ -r "$MISTGATE_TLS_KEY" ]] || fail "MISTGATE_TLS_KEY is not readable: $MISTGATE_TLS_KEY"
      [[ "$MISTGATE_TLS_CERT" == /* && "$MISTGATE_TLS_KEY" == /* ]] \
        || fail "MISTGATE_TLS_CERT and MISTGATE_TLS_KEY must be absolute paths"
      [[ "$MISTGATE_TLS_CERT$MISTGATE_TLS_KEY" =~ ^/[A-Za-z0-9._/-]+$ ]] \
        || fail "TLS paths may contain only letters, digits and . _ - /"
      [[ "$MISTGATE_TLS_CERT" != /home/* && "$MISTGATE_TLS_KEY" != /home/* && "$MISTGATE_TLS_CERT" != /root/* && "$MISTGATE_TLS_KEY" != /root/* ]] \
        || fail "TLS files cannot live under /home or /root because the service has ProtectHome=yes"
      local tls_key_mode
      tls_key_mode="$(stat -c '%a' "$MISTGATE_TLS_KEY")"
      if (( 8#$tls_key_mode & 077 )); then
        warn "MISTGATE_TLS_KEY is readable by group or others; restrict it to root (chmod 600)"
      fi
      ;;
    caddy) ;;
    *) fail "MISTGATE_TLS_MODE must be acme, files or caddy" ;;
  esac

  validate_host_list "$MISTGATE_ACME_DOMAINS"
  validate_port MISTGATE_AGENT_PORT "$MISTGATE_AGENT_PORT"

  if [[ "$MISTGATE_TLS_MODE" == "files" ]]; then
    if ! openssl x509 -in "$MISTGATE_TLS_CERT" -noout -checkhost "$(site_host)" >/dev/null 2>&1; then
      warn "MISTGATE_TLS_CERT does not list $(site_host); clients will reject it"
    fi
    if [[ "$MISTGATE_ADMIN_MODE" == "host" ]] \
      && ! openssl x509 -in "$MISTGATE_TLS_CERT" -noout -checkhost "$MISTGATE_ADMIN_HOST" >/dev/null 2>&1; then
      warn "MISTGATE_TLS_CERT does not list $MISTGATE_ADMIN_HOST; the admin host will fail TLS"
    fi
  fi

  if [[ -n "$MISTGATE_AGENT_ADDR" ]]; then
    [[ "$MISTGATE_AGENT_ADDR" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] \
      || fail "MISTGATE_AGENT_ADDR must be host:port"
    validate_port MISTGATE_AGENT_ADDR "${MISTGATE_AGENT_ADDR##*:}"
  fi

  validate_abs_path MISTGATE_DATA_DIR "$MISTGATE_DATA_DIR"
  validate_abs_path MISTGATE_BIN_DIR "$MISTGATE_BIN_DIR"

  if [[ -n "$MISTGATE_DECOY_DIR" ]]; then
    validate_abs_path MISTGATE_DECOY_DIR "$MISTGATE_DECOY_DIR"

    if [[ -e "$MISTGATE_DECOY_DIR" || -L "$MISTGATE_DECOY_DIR" ]]; then
      [[ -d "$MISTGATE_DECOY_DIR" && ! -L "$MISTGATE_DECOY_DIR" ]] \
        || fail "MISTGATE_DECOY_DIR must be a real directory, not a symlink: $MISTGATE_DECOY_DIR"

      if [[ ! -f "$MISTGATE_DECOY_DIR/index.html" || -L "$MISTGATE_DECOY_DIR/index.html" ]]; then
        if find "$MISTGATE_DECOY_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
          fail "MISTGATE_DECOY_DIR is not empty but has no regular index.html: $MISTGATE_DECOY_DIR"
        fi
      else
        [[ -r "$MISTGATE_DECOY_DIR/index.html" ]] || fail "MISTGATE_DECOY_DIR/index.html is not readable by root"

        if find "$MISTGATE_DECOY_DIR" -type l -print -quit 2>/dev/null | grep -q .; then
          fail "MISTGATE_DECOY_DIR must not contain symbolic links: the panel cannot copy them to nodes"
        fi
        if find "$MISTGATE_DECOY_DIR" -type f ! -readable -print -quit 2>/dev/null | grep -q .; then
          fail "MISTGATE_DECOY_DIR contains files that root cannot read"
        fi

        local decoy_size decoy_files
        decoy_size="$(du -sb "$MISTGATE_DECOY_DIR" | awk '{print $1}')"
        decoy_files="$(find "$MISTGATE_DECOY_DIR" -type f | wc -l | tr -d '[:space:]')"
        if (( decoy_size > 2 * 1024 * 1024 )); then
          warn "The decoy site is $((decoy_size / 1024)) KiB; the panel serves it, but cannot offer it to nodes (limit 2 MiB)"
        fi
        if (( decoy_files > 4096 )); then
          warn "The decoy site has $decoy_files files; the panel serves it, but cannot offer it to nodes (limit 4096)"
        fi
      fi
    fi

    case "$MISTGATE_DECOY_SITE" in
      auto) ;;
      rybalka|palatki|gazirovka|bakery|veloservice)
        [[ -d "$DECOY_SITES_DIR/$MISTGATE_DECOY_SITE" ]] \
          || fail "MISTGATE_DECOY_SITE=$MISTGATE_DECOY_SITE is missing from $DECOY_SITES_DIR"
        ;;
      *)
        fail "MISTGATE_DECOY_SITE must be auto, rybalka, palatki, gazirovka, bakery or veloservice"
        ;;
    esac
  fi

  [[ "$MISTGATE_CHANNEL" == "stable" || "$MISTGATE_CHANNEL" == "testing" || "$MISTGATE_CHANNEL" == "dev" ]] \
    || fail "MISTGATE_CHANNEL must be stable, testing or dev"
  if [[ -n "$MISTGATE_VERSION" ]]; then
    [[ "$MISTGATE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(dev|testing)\.[0-9]+)?$ ]] \
      || fail "MISTGATE_VERSION must be a release tag such as v0.1.89"
  fi

  [[ "$MISTGATE_RELEASE_PUBLIC_KEY_BASE64" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || fail "MISTGATE_RELEASE_PUBLIC_KEY_BASE64 must be a base64 Ed25519 public key"
  [[ "$MISTGATE_RELEASE_PUBLIC_KEY_SSH_BASE64" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] \
    || fail "MISTGATE_RELEASE_PUBLIC_KEY_SSH_BASE64 must be an SSH wire-format public key"

  validate_bool MISTGATE_ALLOW_UNSIGNED_RELEASE "$MISTGATE_ALLOW_UNSIGNED_RELEASE"
  validate_bool MISTGATE_CONFIGURE_UFW "$MISTGATE_CONFIGURE_UFW"
  validate_bool MISTGATE_ALLOW_LOW_RESOURCES "$MISTGATE_ALLOW_LOW_RESOURCES"
  [[ "$MISTGATE_MIN_FREE_GB" =~ ^[0-9]+$ ]] || fail "MISTGATE_MIN_FREE_GB must be an integer"
  [[ "$MISTGATE_CADDY_OVERWRITE_DOMAIN" == "ask" || "$MISTGATE_CADDY_OVERWRITE_DOMAIN" == "true" || "$MISTGATE_CADDY_OVERWRITE_DOMAIN" == "false" ]] \
    || fail "MISTGATE_CADDY_OVERWRITE_DOMAIN must be ask, true or false"

  if [[ "$MISTGATE_TLS_MODE" == "caddy" ]]; then
    [[ -f "$CADDYFILE" ]] || fail "MISTGATE_TLS_MODE=caddy requires an existing Caddyfile: $CADDYFILE"
    require_cmd caddy
  fi
}

check_platform() {
  section "Platform"
  [[ -r /etc/os-release ]] || fail "/etc/os-release is missing"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] \
    || fail "This repository targets Ubuntu 24.04; detected ${PRETTY_NAME:-unknown}"
  [[ -d /run/systemd/system ]] || fail "systemd is required"
  require_cmd systemctl
  ok "Ubuntu 24.04 with systemd"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) fail "Unsupported architecture: $(uname -m). Mistgate ships amd64 and arm64 builds." ;;
  esac
  ok "Architecture: $ARCH"
}

check_resources() {
  section "Resources"
  local cpu memory_kb available_kb required_kb
  local -a problems=()
  cpu="$(nproc)"
  memory_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  available_kb="$(df -Pk "$MISTGATE_DATA_DIR" 2>/dev/null | awk 'NR == 2 {print $4}' || true)"
  if [[ -z "$available_kb" ]]; then
    available_kb="$(df -Pk /var/lib | awk 'NR == 2 {print $4}')"
  fi
  required_kb=$((10#$MISTGATE_MIN_FREE_GB * 1024 * 1024))
  (( cpu >= 1 )) || problems+=("at least 1 CPU core is required")
  (( memory_kb >= 512 * 1024 )) || problems+=("at least 512 MB RAM is recommended")
  (( available_kb >= required_kb )) || problems+=("at least $MISTGATE_MIN_FREE_GB GB free disk space is required")
  log "Resources: ${cpu} CPU, $((memory_kb / 1024)) MB RAM, $((available_kb / 1024)) MB free"
  if (( ${#problems[@]} )); then
    printf ' - %s\n' "${problems[@]}" >&2
    [[ "$MISTGATE_ALLOW_LOW_RESOURCES" == "true" ]] || fail "Resource preflight failed"
    warn "Continuing because MISTGATE_ALLOW_LOW_RESOURCES=true"
  fi
}

check_commands() {
  section "Required commands"
  local tool
  for tool in awk base64 cksum curl df du find grep install mktemp sed sha256sum sort ss tail tar tr wc; do
    require_cmd "$tool"
  done
  if [[ "$MISTGATE_ALLOW_UNSIGNED_RELEASE" != "true" ]]; then
    require_cmd openssl
    require_cmd ssh-keygen
  fi
  ok "All required commands are present"
}

preflight_install() {
  section "Existing installation"
  if [[ -f "$UNIT_FILE" ]] || systemctl cat "$UNIT_NAME" >/dev/null 2>&1; then
    if grep -Fq 'Description=Mistgate panel' "$UNIT_FILE" 2>/dev/null \
      || systemctl cat "$UNIT_NAME" 2>/dev/null | grep -Fq 'Description=Mistgate panel'; then
      local existing_data_dir
      existing_data_dir="$(systemctl cat "$UNIT_NAME" 2>/dev/null | sed -n 's/.*--data-dir \([^ ]*\).*/\1/p' | sed -n '1p')"
      if [[ -n "$existing_data_dir" && "$existing_data_dir" != "$MISTGATE_DATA_DIR" ]]; then
        fail "Existing installation uses $existing_data_dir, not MISTGATE_DATA_DIR=$MISTGATE_DATA_DIR. Refusing to take it over."
      fi
      warn "Existing Mistgate installation detected; continuing as a repair and keeping the data directory"
    else
      fail "$UNIT_NAME exists but is not this module's unit. Refusing to replace it."
    fi
  fi

  if [[ -d "$MISTGATE_DATA_DIR" ]]; then
    local -a entries=()
    shopt -s nullglob dotglob
    entries=("$MISTGATE_DATA_DIR"/*)
    shopt -u nullglob dotglob
    if (( ${#entries[@]} > 0 )); then
      [[ -f "$MISTGATE_DATA_DIR/mistgate.db" ]] \
        || fail "$MISTGATE_DATA_DIR is not empty but contains no Mistgate database. Refusing to reuse it."
      [[ -f "$MISTGATE_DATA_DIR/master.key" ]] \
        || fail "$MISTGATE_DATA_DIR has a database but no master.key. Restore master.key from backup; setup will not create a new one."
      warn "Existing Mistgate data found in $MISTGATE_DATA_DIR; finishing a partial installation"
    fi
  fi

  if [[ ! -e "$MISTGATE_BIN_DIR/mistgate" ]]; then
    ok "No existing panel installation"
  fi
}

port_listener() {
  local port="$1"
  ss -H -ltnp "( sport = :$port )" 2>/dev/null | sed -n '1p'
}

check_ports() {
  section "Port conflicts"
  local -a ports=()
  case "$MISTGATE_TLS_MODE" in
    acme)
      ports+=(443)
      if [[ -n "$MISTGATE_ACME_HTTP" ]]; then
        ports+=("${MISTGATE_ACME_HTTP#:}")
      fi
      ;;
    files) ports+=(443) ;;
    caddy) ports+=(8080 "$MISTGATE_AGENT_PORT") ;;
  esac

  local port listener
  for port in "${ports[@]}"; do
    listener="$(port_listener "$port")"
    if [[ -n "$listener" && "$listener" != *'"mistgate"'* ]]; then
      fail "TCP port $port is already in use: $listener"
    fi
    if [[ -z "$listener" ]]; then
      ok "TCP port $port is free"
    else
      ok "TCP port $port is held by the existing Mistgate service"
    fi
  done
}

check_dns() {
  section "DNS"
  local host
  host="$(site_host)"
  if getent hosts "$host" >/dev/null 2>&1; then
    ok "$host resolves: $(getent hosts "$host" | awk '{print $1}' | tr '\n' ' ')"
  else
    warn "$host does not resolve from this server yet"
  fi
  if [[ "$MISTGATE_TLS_MODE" == "acme" ]]; then
    warn "Let's Encrypt issuance needs $host to point directly at this server on TCP 80/443"
  fi
}

canonical_integer() { [[ "$1" == "0" || "$1" =~ ^[1-9][0-9]*$ ]]; }

parse_release_tag() {
  local tag="$1" value major minor patch suffix number rank
  local -a fields
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(dev|testing)\.[0-9]+)?$ ]] || return 1
  value="${tag#v}"
  IFS='.-' read -r -a fields <<< "$value"
  ((${#fields[@]} == 3 || ${#fields[@]} == 5)) || return 1
  major="${fields[0]}"
  minor="${fields[1]}"
  patch="${fields[2]}"
  canonical_integer "$major" && canonical_integer "$minor" && canonical_integer "$patch" || return 1
  if ((${#fields[@]} == 3)); then
    tag_channel="stable"
    rank=3
    number=0
  else
    suffix="${fields[3]}"
    number="${fields[4]}"
    [[ "$suffix" == "dev" || "$suffix" == "testing" ]] || return 1
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || return 1
    if [[ "$suffix" == "dev" ]]; then
      tag_channel="dev"
      rank=1
    else
      tag_channel="testing"
      rank=2
    fi
  fi
  tag_sort_key="$major.$minor.$patch-$rank.$number"
}

latest_channel_release() {
  local tag
  local candidates="$TMP_DIR/channel-releases"
  : > "$candidates"
  while IFS= read -r tag; do
    parse_release_tag "$tag" || continue
    case "$MISTGATE_CHANNEL:$tag_channel" in
      stable:stable|testing:stable|testing:testing|dev:stable|dev:testing|dev:dev) ;;
      *) continue ;;
    esac
    printf '%s\t%s\n' "$tag_sort_key" "$tag" >> "$candidates"
  # The API returns one JSON document; tag_name comes before draft for every release.
  done < <(
    tr -d '\r\n' < "$TMP_DIR/releases.json" |
      grep -oE '"(tag_name|draft)"[[:space:]]*:[[:space:]]*("[^"]*"|true|false)' |
      awk '
        /^"tag_name"/ {
          tag = $0
          sub(/^"tag_name"[[:space:]]*:[[:space:]]*"/, "", tag)
          sub(/"$/, "", tag)
          next
        }
        /^"draft"/ {
          if (tag != "" && $0 ~ /false$/) print tag
          tag = ""
        }
      '
  )
  [[ -s "$candidates" ]] || fail "No published release found on the $MISTGATE_CHANNEL channel"
  MISTGATE_VERSION="$(LC_ALL=C sort -V -t $'\t' -k1,1 "$candidates" | tail -n 1 | cut -f 2)"
}

curl_download() {
  local url="$1"
  local output="$2"
  local extra=()
  [[ "$url" == http://* ]] && extra+=(--proto '=http,https') || extra+=(--proto '=https' --tlsv1.2)
  curl --fail --silent --show-error --location --retry 5 --retry-delay 1 \
    "${extra[@]}" --output "$output" "$url"
}

download_release() {
  section "Release download"
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mistgate-setup.XXXXXX")"
  cleanup_tmp() { rm -rf -- "$TMP_DIR"; }
  trap cleanup_tmp EXIT

  if [[ -z "$MISTGATE_VERSION" ]]; then
    log "Looking up the newest $MISTGATE_CHANNEL release"
    curl --fail --silent --show-error --location --retry 5 --retry-delay 1 \
      --proto '=https' --tlsv1.2 \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --user-agent 'ubuntu-scripts' \
      --output "$TMP_DIR/releases.json" "$RELEASES_API_URL" \
      || fail "Could not download the GitHub release list"
    latest_channel_release
  fi

  BINARY_NAME="mistgate-linux-$ARCH"
  RELEASE_PATH="$RELEASES_DOWNLOAD_BASE/$MISTGATE_VERSION"
  log "Using Mistgate $MISTGATE_VERSION ($BINARY_NAME)"

  local asset
  for asset in "$BINARY_NAME" SHA256SUMS panel-manifest.json panel-manifest.sig; do
    curl_download "$RELEASE_PATH/$asset" "$TMP_DIR/$asset" \
      || fail "Could not download release asset: $asset"
  done

  if curl_download "$RELEASE_PATH/panel-manifest.sshsig" "$TMP_DIR/panel-manifest.sshsig" 2>/dev/null; then
    PANEL_SSHSIG_PRESENT=true
  else
    PANEL_SSHSIG_PRESENT=false
    rm -f -- "$TMP_DIR/panel-manifest.sshsig"
  fi
  ok "Downloaded $MISTGATE_VERSION"
}

make_ed25519_public_pem() {
  local base64_key="$1"
  local output="$2"
  printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00' > "$output.der"
  printf '%s' "$base64_key" | base64 -d >> "$output.der" 2>/dev/null \
    || fail "Could not decode the release public key"
  [[ "$(wc -c < "$output.der" | tr -d '[:space:]')" == "44" ]] \
    || fail "The release public key must encode 32 Ed25519 bytes"
  openssl pkey -pubin -inform DER -in "$output.der" -out "$output" >/dev/null 2>&1 \
    || fail "Could not read the release public key"
}

ssh_keygen_verify_supported() {
  local usage
  usage="$(ssh-keygen -Y 2>&1 || true)"
  [[ "$usage" == *verify* ]]
}

openssl_ed25519ctx_supported() {
  local version major minor
  version="$(openssl version 2>/dev/null | awk '{print $2}')"
  [[ "$version" =~ ^([0-9]+)\.([0-9]+)\. ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  (( major > 3 || (major == 3 && minor >= 2) ))
}

verify_panel_manifest() {
  section "Release signature"

  if [[ "$MISTGATE_ALLOW_UNSIGNED_RELEASE" == "true" ]]; then
    warn "Signature verification is disabled by MISTGATE_ALLOW_UNSIGNED_RELEASE=true"
    return 0
  fi

  if [[ "$PANEL_SSHSIG_PRESENT" == "true" ]] && ssh_keygen_verify_supported; then
    printf 'mistgate-release ssh-ed25519 %s\n' "$MISTGATE_RELEASE_PUBLIC_KEY_SSH_BASE64" > "$TMP_DIR/allowed_signers"
    ssh-keygen -Y verify \
      -f "$TMP_DIR/allowed_signers" \
      -I mistgate-release \
      -n "$PANEL_SSH_NAMESPACE" \
      -s "$TMP_DIR/panel-manifest.sshsig" \
      < "$TMP_DIR/panel-manifest.json" >/dev/null 2>&1 \
      || fail "panel-manifest.sshsig did not verify with the configured release key"
    ok "Panel manifest verified with ssh-keygen"
    return 0
  fi

  openssl_ed25519ctx_supported \
    || fail "ssh-keygen -Y verify (openssh-client) or OpenSSL 3.2+ is required to verify the release signature"

  make_ed25519_public_pem "$MISTGATE_RELEASE_PUBLIC_KEY_BASE64" "$TMP_DIR/release-key.pem"
  [[ "$(wc -c < "$TMP_DIR/panel-manifest.sig" | tr -d '[:space:]')" == "64" ]] \
    || fail "panel-manifest.sig is not a raw 64-byte Ed25519 signature"
  openssl pkeyutl -verify -pubin -inkey "$TMP_DIR/release-key.pem" -rawin \
    -in "$TMP_DIR/panel-manifest.json" -sigfile "$TMP_DIR/panel-manifest.sig" \
    -pkeyopt instance:Ed25519ctx -pkeyopt "context-string:$PANEL_SIGNATURE_CONTEXT" >/dev/null 2>&1 \
    || fail "panel-manifest.sig did not verify with the configured release key"
  ok "Panel manifest verified with OpenSSL"
}

verify_release_checksums() {
  section "Checksums"
  local sum_count expected_sha actual_sha
  sum_count="$(awk -v file="$BINARY_NAME" '$2 == file || $2 == "*" file { count++ } END { print count + 0 }' "$TMP_DIR/SHA256SUMS")"
  [[ "$sum_count" == "1" ]] || fail "SHA256SUMS must contain exactly one entry for $BINARY_NAME"
  expected_sha="$(awk -v file="$BINARY_NAME" '$2 == file || $2 == "*" file { print $1 }' "$TMP_DIR/SHA256SUMS")"
  [[ "$expected_sha" =~ ^[a-fA-F0-9]{64}$ ]] || fail "SHA256SUMS has an invalid hash for $BINARY_NAME"
  actual_sha="$(sha256sum -- "$TMP_DIR/$BINARY_NAME" | awk '{ print $1 }')"
  [[ "${actual_sha,,}" == "${expected_sha,,}" ]] || fail "SHA256SUMS verification failed for $BINARY_NAME"
  ok "SHA-256 matches SHA256SUMS"
}

verify_manifest_metadata() {
  section "Manifest metadata"
  local schema version built expires count entry_os entry_arch entry_size entry_sha
  IFS=$'\t' read -r schema version built expires count entry_os entry_arch entry_size entry_sha < <(
    awk -F'"' -v wanted="$BINARY_NAME" '
      /"schema"[[:space:]]*:/ { x=$3; sub(/^[[:space:]]*:[[:space:]]*/, "", x); sub(/,.*/, "", x); schema=x; schemas++ }
      /"version"[[:space:]]*:/ { version=$4; versions++ }
      /"built"[[:space:]]*:/ { x=$3; sub(/^[[:space:]]*:[[:space:]]*/, "", x); sub(/,.*/, "", x); built=x; builts++ }
      /"expires"[[:space:]]*:/ { x=$3; sub(/^[[:space:]]*:[[:space:]]*/, "", x); sub(/,.*/, "", x); expires=x; expiries++ }
      /"os"[[:space:]]*:/ { os=$4 }
      /"arch"[[:space:]]*:/ { arch=$4 }
      /"name"[[:space:]]*:/ { name=$4 }
      /"size"[[:space:]]*:/ { x=$3; sub(/^[[:space:]]*:[[:space:]]*/, "", x); sub(/,.*/, "", x); size=x }
      /"sha256"[[:space:]]*:/ { sha=$4; if (name == wanted) { entries++; found_os=os; found_arch=arch; found_size=size; found_sha=sha } }
      END { printf "%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\n", schema, version, built, expires, entries, found_os, found_arch, found_size, found_sha }
    ' "$TMP_DIR/panel-manifest.json"
  )
  [[ "$schema" == "1" && "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]] \
    || fail "panel-manifest.json has an invalid schema or version"
  [[ "$built" =~ ^[0-9]+$ && "$expires" =~ ^[0-9]+$ ]] || fail "panel-manifest.json has invalid timestamps"
  (( expires > built )) || fail "panel-manifest.json expires before it was built"
  [[ "$version" == "$MISTGATE_VERSION" ]] \
    || fail "panel-manifest.json is for $version, not the requested $MISTGATE_VERSION"
  (( $(date +%s) <= expires )) || fail "panel-manifest.json expired; a newer release must be signed"
  [[ "$count" == "1" && "$entry_os" == "linux" && "$entry_arch" == "$ARCH" ]] \
    || fail "panel-manifest.json does not list $BINARY_NAME for linux/$ARCH"
  [[ "$entry_size" =~ ^[0-9]+$ && "$entry_sha" =~ ^[a-fA-F0-9]{64}$ ]] \
    || fail "panel-manifest.json has invalid metadata for $BINARY_NAME"
  local binary_size actual_sha
  binary_size="$(wc -c < "$TMP_DIR/$BINARY_NAME" | tr -d '[:space:]')"
  actual_sha="$(sha256sum -- "$TMP_DIR/$BINARY_NAME" | awk '{ print $1 }')"
  [[ "$entry_size" == "$binary_size" ]] || fail "$BINARY_NAME size does not match panel-manifest.json"
  [[ "${entry_sha,,}" == "${actual_sha,,}" ]] || fail "$BINARY_NAME SHA-256 does not match panel-manifest.json"
  ok "Manifest $version, expires $(date -u -d "@$expires" '+%F %T UTC')"
}

install_binary() {
  section "Binary"
  install -d -m 0755 "$MISTGATE_BIN_DIR"
  install -m 0755 "$TMP_DIR/$BINARY_NAME" "$MISTGATE_BIN_DIR/.mistgate.new"
  mv -f "$MISTGATE_BIN_DIR/.mistgate.new" "$MISTGATE_BIN_DIR/mistgate"
  ok "Installed $("$MISTGATE_BIN_DIR/mistgate" version | sed -n '1p')"
}

install_decoy_helper() {
  local helper="$MISTGATE_BIN_DIR/mistgate-decoy"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
#!/usr/bin/env bash
exec bash "$SCRIPT_DIR/use-decoy-site.sh" "\$@"
EOF
  install -m 0755 "$tmp" "$helper"
  rm -f "$tmp"
  ok "Installed decoy helper: $helper"
}

run_panel_setup() {
  section "Panel data directory"
  local -a setup_args=(setup --public-url "$MISTGATE_PUBLIC_URL" --data-dir "$MISTGATE_DATA_DIR")
  # mistgate setup also reads MISTGATE_ADMIN_HOST and MISTGATE_ADMIN_LISTEN
  # from the environment. load_env exports every value from .env, so clear
  # both here and let the selected mode pass its explicit flag. Otherwise
  # the default MISTGATE_ADMIN_LISTEN silently turns path mode into listen.
  local -a setup_env=(env -u MISTGATE_ADMIN_HOST -u MISTGATE_ADMIN_LISTEN)
  case "$MISTGATE_ADMIN_MODE" in
    host) setup_args+=(--admin-host "$MISTGATE_ADMIN_HOST") ;;
    listen) setup_args+=(--admin-listen "$MISTGATE_ADMIN_LISTEN") ;;
  esac

  if ! "${setup_env[@]}" "$MISTGATE_BIN_DIR/mistgate" "${setup_args[@]}" > "$TMP_DIR/setup.out" 2>&1; then
    cat "$TMP_DIR/setup.out" >&2
    fail "mistgate setup failed. Fix the cause and rerun; existing data is preserved."
  fi

  ADMIN_URL="$(sed -n 's/^Admin URL:[[:space:]]*//p' "$TMP_DIR/setup.out")"
  SETUP_LINK="$(sed -n 's/^Setup link:[[:space:]]*//p' "$TMP_DIR/setup.out")"
  [[ -n "$ADMIN_URL" ]] || fail "mistgate setup did not print the admin URL"

  case "$MISTGATE_ADMIN_MODE" in
    path)
      [[ "$ADMIN_URL" == "$MISTGATE_PUBLIC_URL/"* ]] \
        || fail "The existing data directory belongs to another admin URL ($ADMIN_URL). Refusing to change it."
      ;;
    host)
      [[ "$ADMIN_URL" == "https://$MISTGATE_ADMIN_HOST/" ]] \
        || fail "The existing data directory belongs to another admin URL ($ADMIN_URL). Refusing to change it."
      ;;
    listen)
      [[ "$ADMIN_URL" == "http://localhost:${MISTGATE_ADMIN_LISTEN##*:}/" ]] \
        || fail "The existing data directory belongs to another admin URL ($ADMIN_URL). Refusing to change it."
      ;;
  esac

  install -d -m 0700 "$CONFIG_DIR"
  chmod 0700 "$CONFIG_DIR"
  (
    umask 077
    printf '%s\n' "$ADMIN_URL" > "$ADMIN_URL_FILE"
  )
  chmod 0600 "$ADMIN_URL_FILE"

  if [[ ! -e "$UPDATE_CHANNEL_FILE" ]]; then
    printf '%s\n' "$MISTGATE_CHANNEL" > "$UPDATE_CHANNEL_FILE"
    chmod 0644 "$UPDATE_CHANNEL_FILE"
  elif [[ "$(tr -d '[:space:]' < "$UPDATE_CHANNEL_FILE")" != "$MISTGATE_CHANNEL" ]]; then
    warn "Root update channel policy keeps its existing value: $(tr -d '[:space:]' < "$UPDATE_CHANNEL_FILE")"
  fi

  ok "Admin URL stored in $ADMIN_URL_FILE (mode 0600)"
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

remove_caddy_blocks() {
  local host="$1"
  local output="$2"
  awk -v host="$host" -v begin="$CADDY_MANAGED_PREFIX $host" -v end="$CADDY_MANAGED_SUFFIX $host" '
    function count_char(value, char, i, total) {
      total = 0
      for (i = 1; i <= length(value); i++) {
        if (substr(value, i, 1) == char) total++
      }
      return total
    }
    $0 == begin { managed = 1; next }
    managed { if ($0 == end) managed = 0; next }
    {
      original = $0
      trimmed = original
      gsub(/^[ \t]+|[ \t]+$/, "", trimmed)
      if (!skip && trimmed ~ /\{$/) {
        labels = trimmed
        sub(/[ \t]*\{$/, "", labels)
        gsub(/[ \t]/, "", labels)
        n = split(labels, parts, ",")
        for (i = 1; i <= n; i++) {
          if (parts[i] == host) {
            skip = 1
            depth = count_char(original, "{") - count_char(original, "}")
            next
          }
        }
      }
      if (skip) {
        depth += count_char(original, "{") - count_char(original, "}")
        if (depth <= 0) skip = 0
        next
      }
      print original
    }
  ' "$CADDYFILE" > "$output"
}

confirm_caddy_replacement() {
  local host="$1"
  local answer
  case "$MISTGATE_CADDY_OVERWRITE_DOMAIN" in
    true) log "Existing Caddy block for $host will be replaced (approved in env)"; return 0 ;;
    false) return 1 ;;
  esac
  printf 'Caddy domain %s already exists and points somewhere else. Replace it with Mistgate? [y/N] ' "$host"
  read -r answer || answer=""
  [[ "$answer" =~ ^([yY]|yes|YES)$ ]]
}

decoy_starter_names() {
  printf '%s\n' rybalka palatki gazirovka bakery veloservice
}

choose_decoy_site() {
  if [[ "$MISTGATE_DECOY_SITE" != "auto" ]]; then
    printf '%s\n' "$MISTGATE_DECOY_SITE"
    return 0
  fi

  local -a names=()
  local hash index
  mapfile -t names < <(decoy_starter_names)
  hash="$(printf '%s' "$(site_host)" | cksum | awk '{print $1}')"
  index=$(( hash % ${#names[@]} ))
  printf '%s\n' "${names[$index]}"
}

prepare_decoy_dir() {
  [[ -n "$MISTGATE_DECOY_DIR" ]] || {
    log "MISTGATE_DECOY_DIR is empty; the panel will serve its built-in page"
    return 0
  }

  local dir="$MISTGATE_DECOY_DIR"
  if [[ ! -e "$dir" ]]; then
    install -d -m 0755 "$(dirname -- "$dir")"
    install -d -m 0755 "$dir"
  fi

  if [[ -f "$dir/index.html" ]]; then
    log "Keeping the existing decoy site in $dir"
    return 0
  fi

  local site
  site="$(choose_decoy_site)"
  [[ -d "$DECOY_SITES_DIR/$site" ]] || fail "Decoy starter site not found: $DECOY_SITES_DIR/$site"

  log "Installing the '$site' starter decoy site into $dir"
  cp -a "$DECOY_SITES_DIR/$site/." "$dir/"
  DECOY_SITE_CHOSEN="$site"
  find "$dir" -type d -exec chmod 0755 {} +
  find "$dir" -type f -exec chmod 0644 {} +
  ok "Starter decoy site '$site' is installed; replace its files with your own before sharing the address"
}

preflight_caddy() {
  [[ "$MISTGATE_TLS_MODE" == "caddy" ]] || return 0
  section "Caddy"
  require_cmd caddy
  local host block
  for host in "${CADDY_HOSTS[@]}"; do
    grep -Fq "$CADDY_MANAGED_PREFIX $host" "$CADDYFILE" && continue
    block="$(caddy_block_for_host "$host")"
    [[ -n "$block" ]] || continue
    if grep -Eq 'reverse_proxy (http://)?(127\.0\.0\.1|localhost):8080([[:space:]]|$)' <<< "$block"; then
      log "Caddy already routes $host to the Mistgate listener"
      continue
    fi
    confirm_caddy_replacement "$host" || fail "Caddyfile already contains an unmanaged block for $host"
  done
}

configure_caddy() {
  [[ "$MISTGATE_TLS_MODE" == "caddy" ]] || return 0
  section "Caddy configuration"
  local host backup tmp
  tmp="$(mktemp)"
  install -d -m 0755 "$(dirname -- "$CADDYFILE")"
  [[ -f "$CADDYFILE" ]] || touch "$CADDYFILE"
  backup="${CADDYFILE}.bak.$(date +%s)"
  cp -a "$CADDYFILE" "$backup"

  remove_caddy_blocks "${CADDY_HOSTS[0]}" "$tmp"
  install -m 0644 "$tmp" "$CADDYFILE"
  for host in "${CADDY_HOSTS[@]:1}"; do
    remove_caddy_blocks "$host" "$tmp"
    install -m 0644 "$tmp" "$CADDYFILE"
  done
  rm -f "$tmp"

  for host in "${CADDY_HOSTS[@]}"; do
    cat >> "$CADDYFILE" <<EOF

$CADDY_MANAGED_PREFIX $host
$host {
    encode zstd gzip
    reverse_proxy 127.0.0.1:8080
}
$CADDY_MANAGED_SUFFIX $host
EOF
  done

  if ! caddy validate --config "$CADDYFILE"; then
    cp -a "$backup" "$CADDYFILE"
    fail "Caddy validation failed; restored $backup"
  fi
  if ! systemctl reload caddy; then
    cp -a "$backup" "$CADDYFILE"
    if caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
      systemctl reload caddy || true
    fi
    fail "Caddy reload failed; restored $backup"
  fi
  ok "Caddy proxies ${CADDY_HOSTS[*]} to 127.0.0.1:8080"
}

build_serve_command() {
  local listen
  SERVE_ARGS=(
    "$MISTGATE_BIN_DIR/mistgate" serve
    --data-dir "$MISTGATE_DATA_DIR"
    --update-service "$UNIT_NAME"
    --log-level info
    --log-format text
  )
  case "$MISTGATE_TLS_MODE" in
    acme)
      listen=":443"
      SERVE_ARGS+=(--listen "$listen")
      local domain
      for domain in "${ACME_DOMAINS[@]}"; do
        SERVE_ARGS+=(--acme-domain "$domain")
      done
      if [[ -n "$MISTGATE_ACME_EMAIL" ]]; then
        SERVE_ARGS+=(--acme-email "$MISTGATE_ACME_EMAIL")
      fi
      if [[ -n "$MISTGATE_ACME_HTTP" ]]; then
        SERVE_ARGS+=(--acme-http "$MISTGATE_ACME_HTTP")
      else
        SERVE_ARGS+=(--acme-http=)
      fi
      ;;
    files)
      listen=":443"
      SERVE_ARGS+=(--listen "$listen" --tls-cert "$MISTGATE_TLS_CERT" --tls-key "$MISTGATE_TLS_KEY")
      ;;
    caddy)
      listen="127.0.0.1:8080"
      SERVE_ARGS+=(
        --listen "$listen"
        --trusted-proxy 127.0.0.1
        --agent-listen ":$MISTGATE_AGENT_PORT"
        --agent-addr "$AGENT_ADDR"
      )
      ;;
  esac
  if [[ "$MISTGATE_ADMIN_MODE" == "listen" ]]; then
    SERVE_ARGS+=(--admin-listen "$MISTGATE_ADMIN_LISTEN")
  fi
  if [[ -n "$MISTGATE_DECOY_DIR" ]]; then
    SERVE_ARGS+=(--decoy-dir "$MISTGATE_DECOY_DIR")
  fi
}

write_unit() {
  section "systemd unit"
  local exec_start tmp
  exec_start="${SERVE_ARGS[*]}"
  tmp="$(mktemp)"

  cat > "$tmp" <<EOF
[Unit]
Description=Mistgate panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$exec_start
Environment=MISTGATE_UPDATE_CHANNEL=$MISTGATE_CHANNEL
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

# The panel writes only its data directory and only binds low ports.
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ReadWritePaths=$MISTGATE_DATA_DIR
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectClock=yes
ProtectControlGroups=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectHostname=yes
LockPersonality=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
SystemCallArchitectures=native
SystemCallFilter=@system-service
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

  if ! systemd-analyze verify "$tmp" >/dev/null 2>&1; then
    warn "systemd-analyze reported warnings for the generated unit; continuing"
  fi
  install -m 0644 "$tmp" "$UNIT_FILE"
  rm -f "$tmp"

  systemctl daemon-reload
  systemctl enable "$UNIT_NAME"
  systemctl restart "$UNIT_NAME"
  ok "Service $UNIT_NAME enabled and restarted"
}

configure_ufw() {
  [[ "$MISTGATE_CONFIGURE_UFW" == "true" ]] || { log "Skipping UFW because MISTGATE_CONFIGURE_UFW=false"; return; }
  section "UFW"
  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw is not installed; skipping firewall rules"
    return
  fi
  if ! ufw status | grep -q '^Status: active'; then
    warn "UFW is installed but not active; this module never enables it. Open the ports at the provider firewall."
    return
  fi
  local port
  for port in "${UFW_TCP_PORTS[@]}"; do
    if ufw status | grep -Eq "(^|[[:space:]])${port}/tcp([[:space:]]|$)"; then
      ok "UFW already allows $port/tcp"
    else
      ufw allow "$port/tcp" comment 'mistgate-panel' >/dev/null
      ok "UFW allows $port/tcp"
    fi
  done
}

tcp_accepts() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
}

wait_health() {
  section "Health check"
  local code
  for _ in {1..60}; do
    if ! systemctl is-active --quiet "$UNIT_NAME"; then
      journalctl -u "$UNIT_NAME" -n 60 --no-pager >&2 || true
      fail "Service $UNIT_NAME exited during startup"
    fi
    case "$MISTGATE_TLS_MODE" in
      acme)
        if [[ -n "$MISTGATE_ACME_HTTP" ]]; then
          code="$(curl --silent --show-error --connect-timeout 2 --max-time 4 \
            -H "Host: $(site_host)" -o /dev/null -w '%{http_code}' "http://127.0.0.1${MISTGATE_ACME_HTTP}/" || true)"
          if tcp_accepts 443 && [[ "$code" != "000" && -n "$code" ]]; then
            ok "Panel answers on TCP 443 and HTTP"
            return 0
          fi
        elif tcp_accepts 443; then
          ok "Panel answers on TCP 443"
          return 0
        fi
        ;;
      files)
        if tcp_accepts 443; then
          ok "Panel answers on TCP 443"
          return 0
        fi
        ;;
      caddy)
        code="$(curl --silent --show-error --connect-timeout 2 --max-time 4 \
          -H "Host: $(site_host)" -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080/" || true)"
        if [[ "$code" != "000" && -n "$code" ]]; then
          ok "Panel answers on 127.0.0.1:8080 (HTTP $code)"
          return 0
        fi
        ;;
    esac
    sleep 2
  done
  journalctl -u "$UNIT_NAME" -n 80 --no-pager >&2 || true
  fail "Panel did not become healthy within 120 seconds"
}

print_summary() {
  section "Done"
  local url
  url="https://$(site_host)"
  ok "Mistgate $MISTGATE_VERSION is installed"
  log "Public address (decoy site): $url"
  log "Admin URL: $ADMIN_URL"
  if [[ -n "$MISTGATE_DECOY_DIR" ]]; then
    log "Decoy site directory: $MISTGATE_DECOY_DIR (copy your site there; no restart needed)"
    if [[ -n "$DECOY_SITE_CHOSEN" ]]; then
      warn "Starter decoy site '$DECOY_SITE_CHOSEN' is installed; replace its files with your own before sharing the address"
    fi
  fi
  if [[ -n "${SETUP_LINK:-}" ]]; then
    log "One-time setup link (valid for 30 minutes): $SETUP_LINK"
    warn "Open the setup link now and create the owner account. Do not paste it into shared chats."
  else
    warn "No setup link was printed because an owner already exists. Run 'mistgate setup --data-dir $MISTGATE_DATA_DIR' to see the admin URL again."
  fi
  log "Back up the data directory before adding users or nodes:"
  log "  systemctl stop $UNIT_NAME && tar czf ~/mistgate-backup-\$(date +%F).tgz -C $(dirname -- "$MISTGATE_DATA_DIR") $(basename -- "$MISTGATE_DATA_DIR") && systemctl start $UNIT_NAME"
  log "Next: open the setup link, then add a node in Nodes -> Add node."
  log "Diagnostics: cd ~/ubuntu-scripts/mistgate && bash check-setup.sh"
  log "Updates:     cd ~/ubuntu-scripts/mistgate && bash update-mistgate.sh"
}

build_acme_domains() {
  local -a items=("$(site_host)")
  local -a extra=()
  local item
  if [[ -n "$MISTGATE_ACME_DOMAINS" ]]; then
    IFS=',' read -r -a extra <<< "$MISTGATE_ACME_DOMAINS"
    for item in "${extra[@]}"; do
      item="${item//[[:space:]]/}"
      if [[ -n "$item" ]]; then
        items+=("$item")
      fi
    done
  fi
  if [[ "$MISTGATE_ADMIN_MODE" == "host" ]]; then
    items+=("$MISTGATE_ADMIN_HOST")
  fi
  ACME_DOMAINS=()
  local candidate seen
  for candidate in "${items[@]}"; do
    seen=false
    for item in "${ACME_DOMAINS[@]}"; do
      if [[ "$item" == "$candidate" ]]; then
        seen=true
      fi
    done
    if [[ "$seen" == "false" ]]; then
      ACME_DOMAINS+=("$candidate")
    fi
  done
}

build_runtime_arrays() {
  build_acme_domains
  AGENT_ADDR="${MISTGATE_AGENT_ADDR:-$(site_host):$MISTGATE_AGENT_PORT}"
  CADDY_HOSTS=("$(site_host)")
  if [[ "$MISTGATE_ADMIN_MODE" == "host" ]]; then
    CADDY_HOSTS+=("$MISTGATE_ADMIN_HOST")
  fi

  UFW_TCP_PORTS=()
  case "$MISTGATE_TLS_MODE" in
    acme)
      UFW_TCP_PORTS+=(443)
      if [[ -n "$MISTGATE_ACME_HTTP" ]]; then
        UFW_TCP_PORTS+=("${MISTGATE_ACME_HTTP#:}")
      fi
      ;;
    files) UFW_TCP_PORTS+=(443) ;;
    caddy) UFW_TCP_PORTS+=(80 443 "$MISTGATE_AGENT_PORT") ;;
  esac
}

main() {
  require_root
  load_env
  validate_env
  check_platform
  detect_arch
  check_commands
  check_resources
  preflight_install
  check_ports
  check_dns
  build_runtime_arrays
  prepare_decoy_dir
  preflight_caddy
  download_release
  verify_release_checksums
  verify_panel_manifest
  verify_manifest_metadata
  install_binary
  install_decoy_helper
  run_panel_setup
  build_serve_command
  write_unit
  configure_ufw
  configure_caddy
  wait_health
  print_summary
}

main "$@"
