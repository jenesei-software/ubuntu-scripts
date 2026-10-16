#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
RULE_SCRIPT_NAME="apply-rules.sh"
INSTALL_DIR="/usr/local/sbin"
UNIT_DIR="/etc/systemd/system"

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
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/cloudflare-http && bash setup-cloudflare-http.sh"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"; }

TEMP_FILE=""
cleanup() {
  if [[ -n "$TEMP_FILE" && -f "$TEMP_FILE" ]]; then
    rm -f -- "$TEMP_FILE"
  fi
}
trap cleanup EXIT

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
  WAN_INTERFACE=""
  HTTP_PORTS=""
  CHAIN_NAME=""
  ALLOW_EXTRA_CIDRS=""
  SERVICE_NAME=""
  REFRESH_TIMER=""
}

load_env() {
  resolve_env_file
  reset_env_vars

  if [[ -z "$ENV_FILE" ]]; then
    warn "Environment file not found; using defaults. Copy env.example to .env to keep local settings."
  else
    [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
    log "Loading environment from $ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi

  WAN_INTERFACE="${WAN_INTERFACE:-}"
  HTTP_PORTS="${HTTP_PORTS:-80,443}"
  CHAIN_NAME="${CHAIN_NAME:-CF_ONLY_HTTP}"
  ALLOW_EXTRA_CIDRS="${ALLOW_EXTRA_CIDRS:-}"
  SERVICE_NAME="${SERVICE_NAME:-cf-only-http}"
  REFRESH_TIMER="${REFRESH_TIMER:-true}"
}

validate_bool() {
  local name="$1"
  local value="$2"
  [[ "$value" == "true" || "$value" == "false" ]] || fail "$name must be true or false"
}

validate_cidr_list() {
  local value="$1"
  local cidr
  local -a items=()

  IFS=',' read -r -a items <<< "$value"
  for cidr in "${items[@]}"; do
    cidr="${cidr// /}"
    [[ -n "$cidr" ]] || continue
    [[ "$cidr" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]] || fail "ALLOW_EXTRA_CIDRS contains an invalid entry: $cidr"
  done
}

validate_env() {
  local port
  local -a ports=()

  [[ "$WAN_INTERFACE" =~ ^[A-Za-z0-9_.:-]*$ ]] || fail "WAN_INTERFACE contains unsupported characters"
  [[ "$HTTP_PORTS" =~ ^[0-9]+(,[0-9]+)*$ ]] || fail "HTTP_PORTS must be a comma-separated list of ports"
  [[ "$CHAIN_NAME" =~ ^[A-Za-z0-9_]{1,28}$ ]] || fail "CHAIN_NAME must be 1-28 characters: letters, digits, underscore"
  [[ "$SERVICE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,40}$ ]] || fail "SERVICE_NAME contains unsupported characters"
  validate_bool REFRESH_TIMER "$REFRESH_TIMER"
  validate_cidr_list "$ALLOW_EXTRA_CIDRS"

  IFS=',' read -r -a ports <<< "$HTTP_PORTS"
  for port in "${ports[@]}"; do
    (( 10#$port >= 1 && 10#$port <= 65535 )) || fail "HTTP_PORTS contains an out-of-range port: $port"
  done
}

detect_interface() {
  ip -o -4 route show default 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

check_platform() {
  section "Platform"
  [[ -r /etc/os-release ]] || fail "/etc/os-release is missing"
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
    ok "Operating system: ${PRETTY_NAME:-Ubuntu 24.04}"
  else
    warn "This repository targets Ubuntu 24.04; detected ${PRETTY_NAME:-unknown}"
  fi

  require_cmd iptables
  require_cmd curl
  require_cmd ip
  require_cmd systemctl
  ok "Required commands are available: iptables, curl, ip, systemctl"

  if command -v ip6tables >/dev/null 2>&1; then
    ok "Command is available: ip6tables"
  else
    warn "ip6tables is unavailable; IPv6 traffic will not be restricted"
  fi

  [[ -f "$SCRIPT_DIR/$RULE_SCRIPT_NAME" ]] || fail "Rule script is missing: $SCRIPT_DIR/$RULE_SCRIPT_NAME"
  bash -n "$SCRIPT_DIR/$RULE_SCRIPT_NAME" || fail "Rule script has a syntax error: $SCRIPT_DIR/$RULE_SCRIPT_NAME"
  ok "Rule script is present and parses: $RULE_SCRIPT_NAME"
}

check_interface() {
  section "Interface"

  if [[ -z "$WAN_INTERFACE" ]]; then
    WAN_INTERFACE="$(detect_interface)"
    [[ -n "$WAN_INTERFACE" ]] || fail "Could not detect the default interface; set WAN_INTERFACE in the env file"
    log "Detected the default interface: $WAN_INTERFACE"
  fi

  ip link show "$WAN_INTERFACE" >/dev/null 2>&1 || fail "Interface does not exist: $WAN_INTERFACE; set WAN_INTERFACE in the env file"
  ok "Interface exists: $WAN_INTERFACE"
}

check_docker() {
  section "Docker"
  if iptables -nL DOCKER-USER >/dev/null 2>&1; then
    ok "The DOCKER-USER chain is present"
  else
    fail "The DOCKER-USER chain is missing; start Docker before running this module"
  fi
}

install_rule_script() {
  local target="$INSTALL_DIR/$SERVICE_NAME.sh"

  section "Rule script"
  install -d -m 0755 "$INSTALL_DIR"

  if [[ -f "$target" ]] && cmp -s "$SCRIPT_DIR/$RULE_SCRIPT_NAME" "$target"; then
    ok "Rule script is up to date: $target"
    return
  fi

  TEMP_FILE="$(mktemp "$INSTALL_DIR/.$SERVICE_NAME.sh.XXXXXX")"
  install -m 0755 "$SCRIPT_DIR/$RULE_SCRIPT_NAME" "$TEMP_FILE"
  mv -f -- "$TEMP_FILE" "$target"
  TEMP_FILE=""
  ok "Installed rule script: $target"
}

write_units() {
  local exec_start
  local timer_unit="$UNIT_DIR/$SERVICE_NAME.timer"
  local unit="$UNIT_DIR/$SERVICE_NAME.service"

  section "systemd units"

  exec_start="$INSTALL_DIR/$SERVICE_NAME.sh $WAN_INTERFACE $HTTP_PORTS $CHAIN_NAME"
  if [[ -n "$ALLOW_EXTRA_CIDRS" ]]; then
    exec_start="$exec_start $ALLOW_EXTRA_CIDRS"
  fi

  TEMP_FILE="$(mktemp "$UNIT_DIR/.$SERVICE_NAME.service.XXXXXX")"
  cat > "$TEMP_FILE" <<EOF
[Unit]
Description=Restrict Docker-published TCP $HTTP_PORTS to Cloudflare
Documentation=file:$INSTALL_DIR/$SERVICE_NAME.sh
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$exec_start
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$TEMP_FILE"
  mv -f -- "$TEMP_FILE" "$unit"
  TEMP_FILE=""
  ok "Wrote unit: $unit"

  if [[ "$REFRESH_TIMER" != "true" ]]; then
    if [[ -f "$timer_unit" ]]; then
      systemctl disable --now "$SERVICE_NAME.timer" >/dev/null 2>&1 || true
      rm -f -- "$timer_unit"
      warn "Refresh timer disabled and removed: $timer_unit"
    fi
    return
  fi

  TEMP_FILE="$(mktemp "$UNIT_DIR/.$SERVICE_NAME.timer.XXXXXX")"
  cat > "$TEMP_FILE" <<EOF
[Unit]
Description=Refresh the Cloudflare IP list for $SERVICE_NAME

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$TEMP_FILE"
  mv -f -- "$TEMP_FILE" "$timer_unit"
  TEMP_FILE=""
  ok "Wrote timer: $timer_unit"
}

enable_units() {
  section "Apply"

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME.service" >/dev/null 2>&1 || fail "Could not enable $SERVICE_NAME.service"
  systemctl restart "$SERVICE_NAME.service" || fail "Could not start $SERVICE_NAME.service"
  ok "Service is enabled and started: $SERVICE_NAME.service"

  if [[ "$REFRESH_TIMER" == "true" ]]; then
    systemctl enable --now "$SERVICE_NAME.timer" >/dev/null 2>&1 || fail "Could not enable $SERVICE_NAME.timer"
    ok "Timer is enabled and started: $SERVICE_NAME.timer"
  fi
}

verify_rules() {
  section "Verify"

  if iptables -C DOCKER-USER -i "$WAN_INTERFACE" -p tcp -m multiport --dports "$HTTP_PORTS" -j "$CHAIN_NAME" 2>/dev/null; then
    ok "IPv4 jump rule is present in DOCKER-USER: $HTTP_PORTS on $WAN_INTERFACE"
  else
    fail "IPv4 jump rule is missing from DOCKER-USER"
  fi

  if iptables -nL "$CHAIN_NAME" >/dev/null 2>&1; then
    ok "IPv4 chain exists: $CHAIN_NAME ($(iptables -nL "$CHAIN_NAME" | grep -c 'RETURN') allowed ranges)"
  else
    fail "IPv4 chain is missing: $CHAIN_NAME"
  fi

  if [[ ! -s /var/lib/cf-only-http/ips-v4 ]]; then
    fail "The cached Cloudflare IPv4 list is missing or empty"
  fi
  ok "Cached Cloudflare list: $(grep -c . /var/lib/cf-only-http/ips-v4) IPv4 ranges"

  if command -v ip6tables >/dev/null 2>&1 && ip6tables -nL DOCKER-USER >/dev/null 2>&1; then
    if ip6tables -C DOCKER-USER -i "$WAN_INTERFACE" -p tcp -m multiport --dports "$HTTP_PORTS" -j "$CHAIN_NAME" 2>/dev/null; then
      ok "IPv6 jump rule is present in DOCKER-USER"
    else
      warn "IPv6 jump rule is missing from DOCKER-USER"
    fi
  else
    warn "IPv6 is not restricted: ip6tables or its DOCKER-USER chain is unavailable"
  fi
}

main() {
  require_root
  load_env
  validate_env
  check_platform
  check_interface
  check_docker
  install_rule_script
  write_units
  enable_units
  verify_rules

  section "Done"
  log "Traffic to TCP $HTTP_PORTS on $WAN_INTERFACE is now accepted from Cloudflare only."
  log "Every other source is dropped, so the origin cannot be reached directly any more."
  log "Ranges are refreshed at boot and weekly; run: cd ~/ubuntu-scripts/cloudflare-http && bash check-setup.sh"
}

main "$@"
