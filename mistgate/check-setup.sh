#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"

UNIT_NAME="mistgate.service"
UNIT_FILE="/etc/systemd/system/mistgate.service"
CONFIG_DIR="/etc/mistgate"
ADMIN_URL_FILE="$CONFIG_DIR/admin-url"
UPDATE_CHANNEL_FILE="$CONFIG_DIR/panel-update-channel"
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts mistgate"

ERRORS=0
WARNINGS=0

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
warn() { log_line "WARN" "$*"; WARNINGS=$((WARNINGS + 1)); }
err() { log_line "ERROR" "$*"; ERRORS=$((ERRORS + 1)); }
section() { echo; log_line "SECTION" "$*"; }
fail() { log_line "ERROR" "$*" >&2; exit 1; }
require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/mistgate && bash check-setup.sh"
}

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
  MISTGATE_ADMIN_LISTEN=""
  MISTGATE_TLS_MODE=""
  MISTGATE_ACME_HTTP=":80"
  MISTGATE_TLS_CERT=""
  MISTGATE_DATA_DIR=""
  MISTGATE_BIN_DIR=""
  MISTGATE_CHANNEL=""
  MISTGATE_VERSION=""
  MISTGATE_AGENT_PORT=""
  MISTGATE_CONFIGURE_UFW=""
  CADDYFILE=""
}

load_env() {
  if [[ -n "$ENV_FILE_INPUT" ]]; then
    ENV_FILE="$(resolve_env_path "$ENV_FILE_INPUT")"
  elif [[ -f "$SCRIPT_DIR/.env" ]]; then
    ENV_FILE="$SCRIPT_DIR/.env"
  else
    ENV_FILE=""
  fi

  reset_env_vars
  if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
    info "Loading environment from $ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  else
    warn "Environment file not found; checking with default paths only"
  fi

  MISTGATE_PUBLIC_URL="${MISTGATE_PUBLIC_URL%/}"
  MISTGATE_ADMIN_MODE="${MISTGATE_ADMIN_MODE:-path}"
  MISTGATE_ADMIN_LISTEN="${MISTGATE_ADMIN_LISTEN:-127.0.0.1:8081}"
  MISTGATE_TLS_MODE="${MISTGATE_TLS_MODE:-acme}"
  MISTGATE_DATA_DIR="${MISTGATE_DATA_DIR:-/var/lib/mistgate}"
  MISTGATE_BIN_DIR="${MISTGATE_BIN_DIR:-/usr/local/bin}"
  MISTGATE_CHANNEL="${MISTGATE_CHANNEL:-stable}"
  MISTGATE_AGENT_PORT="${MISTGATE_AGENT_PORT:-8443}"
  MISTGATE_CONFIGURE_UFW="${MISTGATE_CONFIGURE_UFW:-true}"
  CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
}

site_host() {
  local value="$MISTGATE_PUBLIC_URL"
  value="${value#https://}"
  value="${value%%/*}"
  printf '%s\n' "$value"
}

check_platform() {
  section "Platform"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    info "OS: ${PRETTY_NAME:-unknown}"
    [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] \
      || warn "This repository targets Ubuntu 24.04"
  else
    err "/etc/os-release is missing"
  fi
  info "Architecture: $(uname -m)"
  if [[ -d /run/systemd/system ]]; then ok "systemd is running"; else err "systemd is not running"; fi
}

check_commands() {
  section "Commands"
  local tool
  for tool in curl find openssl sha256sum stat systemctl ss; do
    if command -v "$tool" >/dev/null 2>&1; then
      ok "Command found: $tool"
    else
      err "Command not found: $tool"
    fi
  done
  command -v ss >/dev/null 2>&1 || true
}

check_binary() {
  section "Mistgate binary"
  local binary="$MISTGATE_BIN_DIR/mistgate"
  if [[ ! -x "$binary" ]]; then
    err "Binary is missing or not executable: $binary"
    return
  fi
  ok "Binary exists: $binary"
  local version_output
  if version_output="$("$binary" version 2>&1)"; then
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then
        info "$line"
      fi
    done <<< "$version_output"
    local installed
    installed="$(sed -n '1s/^mistgate[[:space:]]*//p' <<< "$version_output")"
    if [[ -n "$MISTGATE_VERSION" && "$installed" != "$MISTGATE_VERSION" ]]; then
      warn "Installed version $installed differs from pinned MISTGATE_VERSION=$MISTGATE_VERSION"
    fi
    if grep -q 'release key: none' <<< "$version_output"; then
      warn "This is an unsigned build; nodes will not self-update from the panel"
    fi
  else
    err "Could not run $binary version"
  fi
  if [[ -f "$binary.prev" ]]; then
    info "Previous binary kept for rollback: $binary.prev"
  fi
}

check_data_dir() {
  section "Data directory"
  local dir="$MISTGATE_DATA_DIR"
  if [[ ! -d "$dir" ]]; then
    err "Data directory is missing: $dir"
    return
  fi
  ok "Data directory exists: $dir"

  local dir_mode owner
  dir_mode="$(stat -c '%a' "$dir")"
  owner="$(stat -c '%U:%G' "$dir")"
  if [[ "$dir_mode" == "700" ]]; then ok "Data directory mode is 0700"; else err "Data directory mode is $dir_mode, expected 700"; fi
  if [[ "$owner" == "root:root" ]]; then ok "Data directory owner is root:root"; else warn "Data directory owner is $owner"; fi

  local file mode size
  for file in master.key mistgate.db; do
    if [[ ! -f "$dir/$file" ]]; then
      err "Required file is missing: $dir/$file"
      continue
    fi
    mode="$(stat -c '%a' "$dir/$file")"
    size="$(stat -c '%s' "$dir/$file")"
    if [[ "$mode" == "600" ]]; then ok "$file mode is 0600 ($size bytes)"; else err "$file mode is $mode, expected 600"; fi
  done

  if [[ -f "$dir/master.key" && "$(stat -c '%s' "$dir/master.key")" != "32" ]]; then
    err "master.key must be exactly 32 bytes"
  fi

  if [[ "$MISTGATE_TLS_MODE" == "acme" ]]; then
    if [[ -d "$dir/acme" ]]; then
      ok "ACME state directory exists"
      if find "$dir/acme" -type f 2>/dev/null | grep -q .; then
        ok "Let's Encrypt certificate material is present"
      else
        warn "No certificate material in $dir/acme yet; the panel may still be issuing"
      fi
    else
      warn "ACME state directory is missing: $dir/acme"
    fi
  fi

  if [[ -f "$dir/dist/manifest.json" ]]; then
    ok "Node release package is present: $dir/dist/manifest.json"
  else
    warn "No node release package in $dir/dist yet; the panel downloads it within 10 minutes"
  fi

  local available_kb
  available_kb="$(df -Pk "$dir" | awk 'NR == 2 {print $4}')"
  if (( available_kb >= 1024 * 1024 )); then ok "Free disk space: $((available_kb / 1024)) MB"; else warn "Low free disk space: $((available_kb / 1024)) MB"; fi
}

check_admin_url_file() {
  section "Admin URL"
  if [[ -d "$CONFIG_DIR" ]]; then
    if [[ "$(stat -c '%a' "$CONFIG_DIR")" == "700" ]]; then
      ok "$CONFIG_DIR mode is 0700"
    else
      warn "$CONFIG_DIR mode is $(stat -c '%a' "$CONFIG_DIR"), expected 700"
    fi
  fi
  if [[ ! -f "$ADMIN_URL_FILE" ]]; then
    warn "Stored admin URL is missing: $ADMIN_URL_FILE. Run 'mistgate setup --data-dir $MISTGATE_DATA_DIR' to print it."
    return
  fi
  local mode owner
  mode="$(stat -c '%a' "$ADMIN_URL_FILE")"
  owner="$(stat -c '%U:%G' "$ADMIN_URL_FILE")"
  if [[ "$mode" == "600" && "$owner" == "root:root" ]]; then
    ok "Admin URL is stored root-only ($ADMIN_URL_FILE)"
  else
    err "Admin URL file must be root:root with mode 600 (found $owner $mode)"
  fi
}

check_unit() {
  section "systemd unit"
  if [[ ! -f "$UNIT_FILE" ]]; then
    err "Unit file is missing: $UNIT_FILE"
    return
  fi
  ok "Unit file exists: $UNIT_FILE"

  if systemctl is-enabled --quiet "$UNIT_NAME" 2>/dev/null; then ok "Service is enabled at boot"; else err "Service is not enabled at boot"; fi
  if systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then ok "Service is active"; else err "Service is NOT active"; fi

  local unit
  unit="$(systemctl cat "$UNIT_NAME" 2>/dev/null || true)"
  local directive
  for directive in \
    'NoNewPrivileges=yes' \
    'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' \
    'ProtectSystem=strict' \
    "ReadWritePaths=$MISTGATE_DATA_DIR" \
    'ProtectHome=yes' \
    'SystemCallFilter=@system-service'; do
    if grep -Fq -- "$directive" <<< "$unit"; then
      ok "Unit hardening: $directive"
    else
      warn "Unit hardening is missing: $directive"
    fi
  done

  if grep -Fq -- "--update-service $UNIT_NAME" <<< "$unit"; then
    ok "Unit allows the panel to update itself through $UNIT_NAME"
  else
    warn "Unit does not pass --update-service $UNIT_NAME; panel self-update may not restart the service"
  fi
}

expected_tcp_ports() {
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
  printf '%s\n' "${ports[@]}"
}

check_listeners() {
  section "Listeners"
  local port line
  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    line="$(ss -H -ltnp "( sport = :$port )" 2>/dev/null | sed -n '1p')"
    if [[ -n "$line" ]]; then
      ok "TCP $port is listening: $line"
    else
      err "TCP $port is not listening"
    fi
  done < <(expected_tcp_ports)

  if [[ "$MISTGATE_TLS_MODE" == "caddy" ]]; then
    if ss -H -ltn 'sport = :8080' 2>/dev/null | grep -q '127.0.0.1:8080'; then
      ok "Panel binds the proxy listener to loopback"
    else
      warn "Panel listener on 8080 is not clearly bound to 127.0.0.1"
    fi
  fi

  if [[ "$MISTGATE_ADMIN_MODE" == "listen" ]]; then
    local admin_port="${MISTGATE_ADMIN_LISTEN##*:}"
    if ss -H -ltn "( sport = :$admin_port )" 2>/dev/null | grep -q '127.0.0.1'; then
      ok "Admin listener is bound to loopback: $MISTGATE_ADMIN_LISTEN"
    else
      err "Admin listener is not bound to loopback: $MISTGATE_ADMIN_LISTEN"
    fi
  fi
}

check_local_http() {
  section "Local HTTP"
  local host code
  host="$(site_host)"
  case "$MISTGATE_TLS_MODE" in
    acme|files)
      code="$(curl --silent --show-error --insecure --resolve "$host:443:127.0.0.1" \
        --connect-timeout 3 --max-time 8 -o /dev/null -w '%{http_code}' "https://$host/" || true)"
      if [[ -n "$code" && "$code" != "000" ]]; then
        ok "HTTPS on 443 answers with HTTP $code for $host"
      else
        err "HTTPS on 443 did not answer for $host"
      fi
      ;;
    caddy)
      code="$(curl --silent --show-error --connect-timeout 3 --max-time 8 \
        -H "Host: $host" -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080/" || true)"
      if [[ -n "$code" && "$code" != "000" ]]; then
        ok "Panel proxy listener answers with HTTP $code"
      else
        err "Panel proxy listener did not answer on 127.0.0.1:8080"
      fi
      ;;
  esac

  if [[ "$MISTGATE_TLS_MODE" == "acme" && -n "$MISTGATE_ACME_HTTP" ]]; then
    code="$(curl --silent --show-error --connect-timeout 3 --max-time 8 \
      -H "Host: $host" -o /dev/null -w '%{http_code}' "http://127.0.0.1:${MISTGATE_ACME_HTTP#:}/" || true)"
    if [[ -n "$code" && "$code" != "000" ]]; then
      ok "HTTP-01 listener on $MISTGATE_ACME_HTTP answers with HTTP $code"
    else
      err "HTTP-01 listener on $MISTGATE_ACME_HTTP did not answer"
    fi
  fi
}

check_certificate() {
  section "TLS certificate"
  local host enddate
  host="$(site_host)"

  case "$MISTGATE_TLS_MODE" in
    acme|files)
      if ! command -v timeout >/dev/null 2>&1; then
        info "timeout command is missing; skipping certificate expiry read"
        return
      fi
      enddate="$(timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$host" </dev/null 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | sed -n 's/^notAfter=//p' || true)"
      if [[ -n "$enddate" ]]; then
        ok "Served certificate for $host expires: $enddate"
      else
        warn "Could not read the served certificate; issuance may still be in progress"
      fi
      ;;
  esac

  if [[ "$MISTGATE_TLS_MODE" == "files" && -n "$MISTGATE_TLS_CERT" ]]; then
    if openssl x509 -in "$MISTGATE_TLS_CERT" -noout -checkend 604800 >/dev/null 2>&1; then
      ok "Configured certificate is valid for at least 7 days"
    else
      err "Configured certificate expires within 7 days or is unreadable: $MISTGATE_TLS_CERT"
    fi
  fi
}

check_caddy() {
  [[ "$MISTGATE_TLS_MODE" == "caddy" ]] || return 0
  section "Caddy"
  if ! command -v caddy >/dev/null 2>&1; then
    err "caddy command is missing"
    return
  fi
  if systemctl is-active --quiet caddy 2>/dev/null; then ok "Caddy is active"; else err "Caddy is NOT active"; fi
  if [[ -f "$CADDYFILE" ]]; then
    ok "Caddyfile exists: $CADDYFILE"
    if caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then ok "Caddyfile is valid"; else err "Caddyfile validation failed"; fi
    if grep -Fq "$CADDY_MANAGED_PREFIX $(site_host)" "$CADDYFILE"; then
      ok "Managed Mistgate block is present for $(site_host)"
    else
      warn "Managed Mistgate block is missing; check the Caddyfile manually"
    fi
  else
    err "Caddyfile is missing: $CADDYFILE"
  fi
}

check_firewall() {
  section "UFW"
  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw is not installed; nothing to check"
    return
  fi
  local status
  status="$(ufw status 2>/dev/null || true)"
  if grep -q '^Status: active' <<< "$status"; then
    ok "UFW is active"
  else
    warn "UFW is not active"
    return
  fi

  local port
  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    if grep -Eq "(^|[[:space:]])${port}/tcp([[:space:]]|$)" <<< "$status"; then
      ok "UFW allows $port/tcp"
    else
      warn "UFW has no explicit allow rule for $port/tcp"
    fi
  done < <(expected_tcp_ports)
}

check_time_and_dns() {
  section "Time and DNS"
  if command -v timedatectl >/dev/null 2>&1; then
    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == "yes" ]]; then
      ok "Clock is synchronized by NTP"
    else
      warn "Clock is not reported as NTP-synchronized"
    fi
  else
    warn "timedatectl is missing"
  fi

  local host
  host="$(site_host)"
  if [[ -z "$host" ]]; then
    warn "MISTGATE_PUBLIC_URL is not set; skipping DNS"
    return
  fi
  if getent hosts "$host" >/dev/null 2>&1; then
    ok "$host resolves: $(getent hosts "$host" | awk '{print $1}' | tr '\n' ' ')"
  else
    warn "$host does not resolve from this server"
  fi
}

check_update_policy() {
  section "Update channel"
  if [[ -f "$UPDATE_CHANNEL_FILE" ]]; then
    local channel
    channel="$(tr -d '[:space:]' < "$UPDATE_CHANNEL_FILE")"
    ok "Root update channel policy: $channel"
    if [[ -n "$MISTGATE_CHANNEL" && "$channel" != "$MISTGATE_CHANNEL" ]]; then
      warn "Env asks for '$MISTGATE_CHANNEL' but the root policy keeps '$channel' (change requires a root action)"
    fi
  else
    warn "Root update channel policy is missing: $UPDATE_CHANNEL_FILE"
  fi
}

summary() {
  section "Summary"
  info "Errors:   $ERRORS"
  info "Warnings: $WARNINGS"
  if (( ERRORS > 0 )); then
    log_line "ERROR" "Check failed; fix the errors above." >&2
    exit 1
  fi
  ok "Mistgate panel check passed"
}

main() {
  require_root
  load_env
  check_platform
  check_commands
  check_binary
  check_data_dir
  check_admin_url_file
  check_unit
  check_listeners
  check_local_http
  check_certificate
  check_caddy
  check_firewall
  check_time_and_dns
  check_update_policy
  summary
}

main "$@"
