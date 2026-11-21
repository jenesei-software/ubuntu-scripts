#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"

RELEASES_REPO="Mistgate/mistgate"
RELEASES_DOWNLOAD_BASE="https://github.com/${RELEASES_REPO}/releases/download"
RELEASES_API_URL="https://api.github.com/repos/${RELEASES_REPO}/releases?per_page=100"

OFFICIAL_RELEASE_KEY_BASE64="6ylEpIbbde2c7e7FcaC/Wc5DAmHfOHsPsOqiB8HaU3c="
OFFICIAL_RELEASE_SSH_KEY_BASE64="AAAAC3NzaC1lZDI1NTE5AAAAIOspRKSG23XtnO3uxXGgv1nOQwJh3zh7D7DqogfB2lN3"
PANEL_SSH_NAMESPACE="mistgate-panel-manifest-v1"
PANEL_SIGNATURE_CONTEXT="mistgate panel manifest v1"

UNIT_NAME="mistgate.service"
UNIT_FILE="/etc/systemd/system/mistgate.service"

TMP_DIR=""
SERVICE_STOPPED=false

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
  log_line "ERROR" "Update failed at line ${BASH_LINENO[0]:-${LINENO}}: ${BASH_COMMAND:-unknown} (exit $exit_code)" >&2
}
cleanup() {
  local exit_code=$?
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
  if [[ "$SERVICE_STOPPED" == "true" ]]; then
    warn "Restarting $UNIT_NAME after an interrupted update"
    systemctl start "$UNIT_NAME" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}
trap on_error ERR
trap cleanup EXIT

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/mistgate && bash update-mistgate.sh"
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
  MISTGATE_DATA_DIR=""
  MISTGATE_BIN_DIR=""
  MISTGATE_VERSION=""
  MISTGATE_CHANNEL=""
  MISTGATE_TLS_MODE=""
  MISTGATE_ACME_HTTP=":80"
  MISTGATE_RELEASE_PUBLIC_KEY_BASE64=""
  MISTGATE_RELEASE_PUBLIC_KEY_SSH_BASE64=""
  MISTGATE_ALLOW_UNSIGNED_RELEASE=""
  MISTGATE_UPGRADE_CONFIRMED=""
  MISTGATE_FORCE_UPDATE=""
  MISTGATE_MIN_FREE_GB=""
}

load_env() {
  if [[ -n "$ENV_FILE_INPUT" ]]; then
    ENV_FILE="$(resolve_env_path "$ENV_FILE_INPUT")"
  elif [[ -f "$SCRIPT_DIR/.env" ]]; then
    ENV_FILE="$SCRIPT_DIR/.env"
  else
    fail "Environment file not found. Copy mistgate/env.example to mistgate/.env"
  fi
  [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
  log "Loading environment from $ENV_FILE"

  reset_env_vars
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  MISTGATE_DATA_DIR="${MISTGATE_DATA_DIR:-/var/lib/mistgate}"
  MISTGATE_BIN_DIR="${MISTGATE_BIN_DIR:-/usr/local/bin}"
  MISTGATE_CHANNEL="${MISTGATE_CHANNEL:-stable}"
  MISTGATE_TLS_MODE="${MISTGATE_TLS_MODE:-acme}"
  MISTGATE_ALLOW_UNSIGNED_RELEASE="${MISTGATE_ALLOW_UNSIGNED_RELEASE:-false}"
  MISTGATE_UPGRADE_CONFIRMED="${MISTGATE_UPGRADE_CONFIRMED:-false}"
  MISTGATE_FORCE_UPDATE="${MISTGATE_FORCE_UPDATE:-false}"
  MISTGATE_MIN_FREE_GB="${MISTGATE_MIN_FREE_GB:-3}"
  MISTGATE_RELEASE_PUBLIC_KEY_BASE64="${MISTGATE_RELEASE_PUBLIC_KEY_BASE64:-$OFFICIAL_RELEASE_KEY_BASE64}"
  MISTGATE_RELEASE_PUBLIC_KEY_SSH_BASE64="${MISTGATE_RELEASE_PUBLIC_KEY_SSH_BASE64:-$OFFICIAL_RELEASE_SSH_KEY_BASE64}"
}

validate_bool() {
  local name="$1"
  local value="$2"
  [[ "$value" == "true" || "$value" == "false" ]] || fail "$name must be true or false"
}

validate_env() {
  [[ "$MISTGATE_DATA_DIR" == /* && "$MISTGATE_DATA_DIR" != "/" && "$MISTGATE_DATA_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || fail "MISTGATE_DATA_DIR must be an absolute path"
  [[ "$MISTGATE_BIN_DIR" == /* && "$MISTGATE_BIN_DIR" != "/" && "$MISTGATE_BIN_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || fail "MISTGATE_BIN_DIR must be an absolute path"
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
  validate_bool MISTGATE_UPGRADE_CONFIRMED "$MISTGATE_UPGRADE_CONFIRMED"
  validate_bool MISTGATE_FORCE_UPDATE "$MISTGATE_FORCE_UPDATE"
  [[ "$MISTGATE_MIN_FREE_GB" =~ ^[0-9]+$ ]] || fail "MISTGATE_MIN_FREE_GB must be an integer"
  case "$MISTGATE_TLS_MODE" in
    acme|files|caddy) ;;
    *) fail "MISTGATE_TLS_MODE must be acme, files or caddy" ;;
  esac
}

check_installed() {
  section "Installed panel"
  [[ -x "$MISTGATE_BIN_DIR/mistgate" ]] || fail "Mistgate is not installed: $MISTGATE_BIN_DIR/mistgate is missing"
  [[ -f "$UNIT_FILE" ]] || fail "Mistgate unit is missing: $UNIT_FILE"
  CURRENT_VERSION="$("$MISTGATE_BIN_DIR/mistgate" version | sed -n '1s/^mistgate[[:space:]]*//p')"
  [[ -n "$CURRENT_VERSION" ]] || fail "Could not read the installed Mistgate version"
  ok "Installed version: $CURRENT_VERSION"
  if systemctl is-active --quiet "$UNIT_NAME"; then
    ok "Service is running"
  else
    warn "Service is not running; the update will start it"
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

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) fail "Unsupported architecture: $(uname -m)" ;;
  esac
}

resolve_version() {
  section "Release lookup"
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mistgate-update.XXXXXX")"

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
  log "Target version: $MISTGATE_VERSION ($BINARY_NAME)"
}

download_assets() {
  section "Release download"
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
  BINARY_SIZE="$entry_size"
  local actual_sha
  actual_sha="$(sha256sum -- "$TMP_DIR/$BINARY_NAME" | awk '{ print $1 }')"
  [[ "$entry_size" == "$(wc -c < "$TMP_DIR/$BINARY_NAME" | tr -d '[:space:]')" ]] \
    || fail "$BINARY_NAME size does not match panel-manifest.json"
  [[ "${entry_sha,,}" == "${actual_sha,,}" ]] || fail "$BINARY_NAME SHA-256 does not match panel-manifest.json"
  ok "Manifest $version, expires $(date -u -d "@$expires" '+%F %T UTC')"
}

check_disk() {
  section "Disk"
  local available_kb required_kb
  available_kb="$(df -Pk "$MISTGATE_DATA_DIR" | awk 'NR == 2 {print $4}')"
  required_kb=$(( (BINARY_SIZE / 1024) + 10#$MISTGATE_MIN_FREE_GB * 1024 * 1024 ))
  (( available_kb >= required_kb )) \
    || fail "Not enough free disk space: $((available_kb / 1024)) MB available, $((required_kb / 1024)) MB required"
  ok "Free disk space: $((available_kb / 1024)) MB"
}

backup_data() {
  section "Backup"
  BACKUP_FILE="${MISTGATE_DATA_DIR}.panel-update-backup.tar.gz"
  log "Archiving the data directory to $BACKUP_FILE"
  rm -f -- "$BACKUP_FILE"
  (
    umask 077
    tar czf "$BACKUP_FILE" -C "$(dirname -- "$MISTGATE_DATA_DIR")" "$(basename -- "$MISTGATE_DATA_DIR")"
  )
  chmod 0600 "$BACKUP_FILE"
  ok "Backup written: $BACKUP_FILE (contains master.key; keep it off-host and encrypted)"
}

install_new_binary() {
  section "Binary swap"
  local binary="$MISTGATE_BIN_DIR/mistgate"
  install -m 0755 "$TMP_DIR/$BINARY_NAME" "$MISTGATE_BIN_DIR/.mistgate.new"
  cp -a "$binary" "$binary.prev"
  mv -f "$MISTGATE_BIN_DIR/.mistgate.new" "$binary"
  ok "Installed $MISTGATE_VERSION; previous binary kept at $binary.prev"
}

tcp_accepts() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
}

wait_health() {
  local code
  for _ in {1..60}; do
    if ! systemctl is-active --quiet "$UNIT_NAME"; then
      return 1
    fi
    case "$MISTGATE_TLS_MODE" in
      acme)
        if [[ -n "$MISTGATE_ACME_HTTP" ]]; then
          code="$(curl --silent --show-error --connect-timeout 2 --max-time 4 \
            -o /dev/null -w '%{http_code}' "http://127.0.0.1${MISTGATE_ACME_HTTP}/" || true)"
          if tcp_accepts 443 && [[ "$code" != "000" && -n "$code" ]]; then
            return 0
          fi
        elif tcp_accepts 443; then
          return 0
        fi
        ;;
      files)
        if tcp_accepts 443; then
          return 0
        fi
        ;;
      caddy)
        code="$(curl --silent --show-error --connect-timeout 2 --max-time 4 \
          -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080/" || true)"
        if [[ "$code" != "000" && -n "$code" ]]; then
          return 0
        fi
        ;;
    esac
    sleep 2
  done
  return 1
}

rollback() {
  local binary="$MISTGATE_BIN_DIR/mistgate"
  section "Rollback"
  systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || true
  if [[ -f "$binary.prev" ]]; then
    cp -a "$binary.prev" "$binary"
    systemctl start "$UNIT_NAME" || true
    SERVICE_STOPPED=false
    if wait_health; then
      ok "Rolled back to the previous binary and the panel is healthy again"
    else
      warn "Rolled back, but the panel still does not answer; inspect: journalctl -u $UNIT_NAME -n 100 --no-pager"
    fi
  else
    warn "No previous binary to roll back to"
  fi
}

main() {
  require_root
  local tool
  for tool in awk base64 curl df grep install mktemp sed sha256sum sort ss tail tar tr wc; do
    require_cmd "$tool"
  done
  require_cmd systemctl

  load_env
  validate_env
  if [[ "$MISTGATE_ALLOW_UNSIGNED_RELEASE" != "true" ]]; then
    require_cmd openssl
    require_cmd ssh-keygen
  fi
  check_installed
  detect_arch
  resolve_version

  if [[ "$CURRENT_VERSION" == "$MISTGATE_VERSION" && "$MISTGATE_FORCE_UPDATE" != "true" ]]; then
    ok "Mistgate $MISTGATE_VERSION is already installed; nothing to do"
    log "Set MISTGATE_FORCE_UPDATE=true to reinstall the same signed binary."
    return 0
  fi

  if [[ "$CURRENT_VERSION" != "$MISTGATE_VERSION" && "$MISTGATE_FORCE_UPDATE" != "true" ]] \
    && [[ "$(printf '%s\n%s\n' "$CURRENT_VERSION" "$MISTGATE_VERSION" | LC_ALL=C sort -V | tail -n 1)" == "$CURRENT_VERSION" ]]; then
    fail "Refusing to downgrade $CURRENT_VERSION -> $MISTGATE_VERSION. Pin a newer release or set MISTGATE_FORCE_UPDATE=true."
  fi

  if [[ "$CURRENT_VERSION" != "$MISTGATE_VERSION" && "$MISTGATE_UPGRADE_CONFIRMED" != "true" ]]; then
    fail "Upgrade $CURRENT_VERSION -> $MISTGATE_VERSION requires MISTGATE_UPGRADE_CONFIRMED=true. Create and verify an off-host backup first."
  fi

  download_assets
  verify_release_checksums
  verify_panel_manifest
  verify_manifest_metadata
  check_disk

  log "Stopping $UNIT_NAME for a consistent data snapshot"
  systemctl stop "$UNIT_NAME"
  SERVICE_STOPPED=true
  backup_data
  install_new_binary

  log "Starting $UNIT_NAME"
  if ! systemctl start "$UNIT_NAME"; then
    journalctl -u "$UNIT_NAME" -n 80 --no-pager >&2 || true
    rollback
    fail "Mistgate $MISTGATE_VERSION failed to start; the previous binary was restored"
  fi
  if wait_health; then
    SERVICE_STOPPED=false
    ok "Mistgate $MISTGATE_VERSION is running"
    log "Diagnostics: cd ~/ubuntu-scripts/mistgate && bash check-setup.sh"
    return 0
  fi

  journalctl -u "$UNIT_NAME" -n 80 --no-pager >&2 || true
  rollback
  fail "Mistgate $MISTGATE_VERSION did not become healthy; the previous binary was restored"
}

main "$@"
