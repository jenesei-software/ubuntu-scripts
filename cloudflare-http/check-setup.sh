#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
RULE_SCRIPT_NAME="apply-rules.sh"
INSTALL_DIR="/usr/local/sbin"
UNIT_DIR="/etc/systemd/system"
STATE_DIR="/var/lib/cf-only-http"
RANGES_V4_URL="https://www.cloudflare.com/ips-v4"
ERROR_COUNT=0
WARNING_COUNT=0

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
warn() { WARNING_COUNT=$((WARNING_COUNT + 1)); log_line "WARN" "$*"; }
err() { ERROR_COUNT=$((ERROR_COUNT + 1)); log_line "ERROR" "$*"; }
section() { echo; log_line "SECTION" "$*"; }
fail() { log_line "ERROR" "$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/cloudflare-http && bash check-setup.sh"; }

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
  elif [[ -f "$SCRIPT_DIR/.env" ]]; then
    ENV_FILE="$SCRIPT_DIR/.env"
  else
    ENV_FILE=""
  fi
}

load_env() {
  resolve_env_file
  WAN_INTERFACE=""
  HTTP_PORTS="80,443"
  CHAIN_NAME="CF_ONLY_HTTP"
  ALLOW_EXTRA_CIDRS=""
  SERVICE_NAME="cf-only-http"
  REFRESH_TIMER="true"

  if [[ -z "$ENV_FILE" ]]; then
    warn "Environment file not found; using diagnostic defaults"
  else
    info "Loading environment from $ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
    WAN_INTERFACE="${WAN_INTERFACE:-}"
    HTTP_PORTS="${HTTP_PORTS:-80,443}"
    CHAIN_NAME="${CHAIN_NAME:-CF_ONLY_HTTP}"
    ALLOW_EXTRA_CIDRS="${ALLOW_EXTRA_CIDRS:-}"
    SERVICE_NAME="${SERVICE_NAME:-cf-only-http}"
    REFRESH_TIMER="${REFRESH_TIMER:-true}"
  fi
}

detect_interface() {
  ip -o -4 route show default 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

check_system() {
  section "System"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
      ok "Operating system: ${PRETTY_NAME:-Ubuntu 24.04}"
    else
      err "Expected Ubuntu 24.04, detected ${PRETTY_NAME:-unknown}"
    fi
  else
    err "/etc/os-release is missing"
  fi
}

check_commands() {
  local command

  section "Commands"
  for command in iptables ip curl systemctl; do
    if command -v "$command" >/dev/null 2>&1; then
      ok "Command is available: $command"
    else
      err "Command not found: $command"
    fi
  done

  if command -v ip6tables >/dev/null 2>&1; then
    ok "Command is available: ip6tables"
  else
    warn "Command not found: ip6tables (IPv6 will not be restricted)"
  fi
}

check_interface() {
  local detected

  section "Interface"
  if [[ -z "$WAN_INTERFACE" ]]; then
    detected="$(detect_interface)"
    if [[ -n "$detected" ]]; then
      warn "WAN_INTERFACE is not set; the default interface is $detected"
      WAN_INTERFACE="$detected"
    else
      err "WAN_INTERFACE is not set and the default interface could not be detected"
      return
    fi
  fi

  if ip link show "$WAN_INTERFACE" >/dev/null 2>&1; then
    ok "Interface exists: $WAN_INTERFACE"
  else
    err "Interface does not exist: $WAN_INTERFACE"
  fi
}

check_rules() {
  local allowed

  section "Rules"

  if iptables -nL DOCKER-USER >/dev/null 2>&1; then
    ok "The DOCKER-USER chain is present"
  else
    err "The DOCKER-USER chain is missing; Docker is not running or not installed"
    return
  fi

  if iptables -C DOCKER-USER -i "$WAN_INTERFACE" -p tcp -m multiport --dports "$HTTP_PORTS" -j "$CHAIN_NAME" 2>/dev/null; then
    ok "IPv4 jump rule is present: $HTTP_PORTS on $WAN_INTERFACE -> $CHAIN_NAME"
  else
    err "IPv4 jump rule is missing from DOCKER-USER"
  fi

  if iptables -nL "$CHAIN_NAME" >/dev/null 2>&1; then
    allowed="$(iptables -nL "$CHAIN_NAME" | grep -c 'RETURN' || true)"
    ok "IPv4 chain is present: $CHAIN_NAME"
    if (( allowed > 0 )); then
      ok "IPv4 allow entries: $allowed"
    else
      err "IPv4 chain $CHAIN_NAME has no allowed ranges; all traffic to $HTTP_PORTS is dropped"
    fi
    if iptables -nL "$CHAIN_NAME" | grep -q 'DROP'; then
      ok "IPv4 chain drops everything else"
    else
      err "IPv4 chain $CHAIN_NAME has no final DROP rule"
    fi
  else
    err "IPv4 chain is missing: $CHAIN_NAME"
  fi

  if command -v ip6tables >/dev/null 2>&1 && ip6tables -nL DOCKER-USER >/dev/null 2>&1; then
    if ip6tables -C DOCKER-USER -i "$WAN_INTERFACE" -p tcp -m multiport --dports "$HTTP_PORTS" -j "$CHAIN_NAME" 2>/dev/null; then
      ok "IPv6 jump rule is present"
    else
      warn "IPv6 jump rule is missing from DOCKER-USER"
    fi
  else
    warn "IPv6 is not restricted: ip6tables or its DOCKER-USER chain is unavailable"
  fi

  info "Docker-published ports bypass UFW; this chain is the only thing filtering them"
}

check_ranges() {
  local cached
  local live

  section "Cloudflare ranges"

  if [[ -s "$STATE_DIR/ips-v4" ]]; then
    cached="$(grep -c . "$STATE_DIR/ips-v4")"
    ok "Cached IPv4 list: $cached ranges ($STATE_DIR/ips-v4)"
  else
    err "The cached IPv4 list is missing or empty: $STATE_DIR/ips-v4"
  fi

  if [[ -s "$STATE_DIR/ips-v6" ]]; then
    ok "Cached IPv6 list: $(grep -c . "$STATE_DIR/ips-v6") ranges ($STATE_DIR/ips-v6)"
  else
    warn "The cached IPv6 list is missing or empty: $STATE_DIR/ips-v6"
  fi

  if live="$(curl -fsS --max-time 15 --retry 1 "$RANGES_V4_URL" 2>/dev/null)"; then
    live="$(printf '%s\n' "$live" | grep -c . || true)"
    if [[ -n "${cached:-}" && "$live" != "$cached" ]]; then
      warn "The live Cloudflare IPv4 list has $live ranges, the cache has $cached; rerun setup to refresh"
    else
      ok "The cached IPv4 list matches the live one ($live ranges)"
    fi
  else
    warn "Could not reach $RANGES_V4_URL to compare the cached list"
  fi
}

check_units() {
  local installed="$INSTALL_DIR/$SERVICE_NAME.sh"

  section "systemd"

  if [[ -f "$installed" ]]; then
    ok "Installed rule script exists: $installed"
    if [[ -x "$installed" ]]; then
      ok "Installed rule script is executable"
    else
      err "Installed rule script is not executable: $installed"
    fi
    if cmp -s "$SCRIPT_DIR/$RULE_SCRIPT_NAME" "$installed"; then
      ok "Installed rule script matches the repository copy"
    else
      warn "Installed rule script differs from the repository copy; rerun setup to update it"
    fi
  else
    err "Installed rule script is missing: $installed"
  fi

  if [[ -f "$UNIT_DIR/$SERVICE_NAME.service" ]]; then
    ok "Service unit exists: $SERVICE_NAME.service"
    if systemctl is-enabled "$SERVICE_NAME.service" >/dev/null 2>&1; then
      ok "Service is enabled: $SERVICE_NAME.service"
    else
      err "Service is not enabled: $SERVICE_NAME.service"
    fi
    if systemctl is-active "$SERVICE_NAME.service" >/dev/null 2>&1; then
      ok "Service is active: $SERVICE_NAME.service"
    else
      err "Service is not active: $SERVICE_NAME.service"
    fi
  else
    err "Service unit is missing: $UNIT_DIR/$SERVICE_NAME.service"
  fi

  if [[ "$REFRESH_TIMER" != "true" ]]; then
    info "The refresh timer is disabled in the env file"
    return
  fi

  if [[ -f "$UNIT_DIR/$SERVICE_NAME.timer" ]]; then
    ok "Timer unit exists: $SERVICE_NAME.timer"
    if systemctl is-enabled "$SERVICE_NAME.timer" >/dev/null 2>&1; then
      ok "Timer is enabled: $SERVICE_NAME.timer"
    else
      err "Timer is not enabled: $SERVICE_NAME.timer"
    fi
    if systemctl is-active "$SERVICE_NAME.timer" >/dev/null 2>&1; then
      ok "Timer is active: $SERVICE_NAME.timer"
    else
      err "Timer is not active: $SERVICE_NAME.timer"
    fi
  else
    err "Timer unit is missing: $UNIT_DIR/$SERVICE_NAME.timer"
  fi
}

summary() {
  section "Summary"
  if (( ERROR_COUNT > 0 )); then
    log_line "ERROR" "$ERROR_COUNT error(s), $WARNING_COUNT warning(s)"
    return 1
  fi
  log_line "OK" "No errors, $WARNING_COUNT warning(s)"
}

main() {
  require_root
  load_env
  check_system
  check_commands
  check_interface
  check_rules
  check_ranges
  check_units
  summary
}

main "$@"
