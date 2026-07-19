#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
IPV6_DISABLE_SYSCTL_FILE="/etc/sysctl.d/99-ubuntu-setup-disable-ipv6.conf"
IPV6_ENABLE_SYSCTL_FILE="/etc/sysctl.d/99-ubuntu-setup-enable-ipv6.conf"
UFW_DEFAULTS_FILE="/etc/default/ufw"
SSHD_DROPIN_FILE="/etc/ssh/sshd_config.d/00-ubuntu-setup.conf"
SSHD_LEGACY_DROPIN_FILE="/etc/ssh/sshd_config.d/99-ubuntu-setup.conf"
ERROR_COUNT=0

LOG_COLOR='\033[1;36m'
LOG_RESET='\033[0m'

timestamp() { date '+%F %T'; }
log_line() {
  local level="$1"
  shift
  printf '%b[%s] %-7s%b %s\n' "$LOG_COLOR" "$(timestamp)" "$level" "$LOG_RESET" "$*"
}

ok() { log_line "OK" "$*"; }
warn() { log_line "WARN" "$*"; }
err() {
  log_line "ERROR" "$*"
  ((ERROR_COUNT += 1))
}
info() { log_line "INFO" "$*"; }
section() { echo; log_line "SECTION" "$*"; }
fail() { log_line "ERROR" "$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/ubuntu && bash check-setup.sh"; }

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
  PORT_SSH=""
  DISABLE_IPV6=""
  IPV6_INTERFACE=""
}

load_env() {
  resolve_env_file
  reset_env_vars
  if [[ -z "$ENV_FILE" ]]; then
    warn "Environment file not found. Expected: $SCRIPT_DIR/.env"
    return
  fi

  if [[ -f "$ENV_FILE" ]]; then
    info "Loading environment from $ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  else
    warn "Environment file not found: $ENV_FILE"
  fi
}

check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    ok "Command found: $1"
  else
    err "Command not found: $1"
  fi
}

check_service_active() {
  local service="$1"
  if systemctl is-active --quiet "$service" 2>/dev/null; then
    ok "Service $service: active"
  else
    err "Service $service: NOT active"
  fi
}

ufw_has_tcp_port() {
  local port="$1"
  ufw status | grep -Eq "(^|[[:space:]])${port}/tcp([[:space:]]|$)"
}

resolve_ipv6_interface() {
  if [[ -n "${IPV6_INTERFACE:-}" ]]; then
    printf '%s\n' "$IPV6_INTERFACE"
    return
  fi

  local iface
  if command -v ip >/dev/null 2>&1; then
    iface="$(ip -o -6 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | sed -n '1p' || true)"
    if [[ -z "$iface" ]]; then
      iface="$(ip -o -4 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | sed -n '1p' || true)"
    fi
  fi

  if [[ -z "${iface:-}" && -d /sys/class/net/eth0 ]]; then
    iface="eth0"
  fi

  [[ -n "${iface:-}" ]] || return 1
  printf '%s\n' "$iface"
}

check_sysctl_value() {
  local setting="$1"
  local expected="$2"
  local value

  value="$(sysctl -n "$setting" 2>/dev/null || echo unknown)"
  if [[ "$value" == "$expected" ]]; then
    ok "$setting=$expected"
  else
    err "$setting expected $expected, got $value"
  fi
}

check_system() {
  section "Base system"
  check_cmd ssh
  check_cmd sshd
  check_cmd ufw
  check_cmd fail2ban-client
  check_cmd ip
  check_cmd ss
  check_cmd sysctl

  check_service_active fail2ban
  if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    ok "Service ssh/sshd: active"
  else
    err "Service ssh/sshd: NOT active"
  fi
}

check_ipv6() {
  section "IPv6"

  if [[ -z "${DISABLE_IPV6:-}" ]]; then
    info "DISABLE_IPV6 is empty; current IPv6 state was intentionally not managed"
    return
  fi

  local ipv6_all ipv6_default ipv6_lo iface
  ipv6_all="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo unknown)"
  ipv6_default="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo unknown)"
  ipv6_lo="$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || echo unknown)"

  if [[ "$DISABLE_IPV6" == "true" ]]; then
    [[ "$ipv6_all" == "1" ]] && ok "net.ipv6.conf.all.disable_ipv6=1" || err "IPv6 all disable flag expected 1, got $ipv6_all"
    [[ "$ipv6_default" == "1" ]] && ok "net.ipv6.conf.default.disable_ipv6=1" || err "IPv6 default disable flag expected 1, got $ipv6_default"
    [[ "$ipv6_lo" == "1" ]] && ok "net.ipv6.conf.lo.disable_ipv6=1" || err "IPv6 lo disable flag expected 1, got $ipv6_lo"
    [[ -f "$IPV6_DISABLE_SYSCTL_FILE" ]] && ok "IPv6 disable config is present" || warn "IPv6 disable config is missing: $IPV6_DISABLE_SYSCTL_FILE"
    [[ ! -f "$IPV6_ENABLE_SYSCTL_FILE" ]] && ok "IPv6 enable config is absent" || warn "IPv6 enable config still exists: $IPV6_ENABLE_SYSCTL_FILE"
    return
  fi

  if [[ "$DISABLE_IPV6" == "false" ]]; then
    if iface="$(resolve_ipv6_interface)"; then
      ok "IPv6 network interface: $iface"
    else
      err "Could not detect IPv6 network interface. Set IPV6_INTERFACE in .env."
    fi

    check_sysctl_value net.ipv6.conf.all.disable_ipv6 0
    check_sysctl_value net.ipv6.conf.default.disable_ipv6 0
    check_sysctl_value net.ipv6.conf.lo.disable_ipv6 0
    check_sysctl_value net.ipv6.conf.all.forwarding 1
    check_sysctl_value net.ipv6.conf.all.addr_gen_mode 0

    if [[ -n "${iface:-}" ]]; then
      check_sysctl_value "net.ipv6.conf.${iface}.disable_ipv6" 0
      check_sysctl_value "net.ipv6.conf.${iface}.accept_ra" 2
      check_sysctl_value "net.ipv6.conf.${iface}.use_tempaddr" 0
    fi

    [[ -f /proc/net/if_inet6 ]] && ok "IPv6 kernel support is active" || err "IPv6 kernel support is not active"
    [[ -f "$IPV6_ENABLE_SYSCTL_FILE" ]] && ok "IPv6 enable config is present" || err "IPv6 enable config is missing: $IPV6_ENABLE_SYSCTL_FILE"
    [[ ! -f "$IPV6_DISABLE_SYSCTL_FILE" ]] && ok "IPv6 disable config is absent" || err "IPv6 disable config still exists: $IPV6_DISABLE_SYSCTL_FILE"

    if [[ -f "$UFW_DEFAULTS_FILE" ]] && grep -qE '^IPV6=yes$' "$UFW_DEFAULTS_FILE"; then
      ok "UFW IPv6 support is enabled"
    else
      warn "Could not confirm IPV6=yes in $UFW_DEFAULTS_FILE"
    fi
  fi
}

check_ssh() {
  section "SSH"
  local sshd_config="/etc/ssh/sshd_config"
  local effective_config
  local key expected actual
  [[ -f "$sshd_config" ]] || { err "File not found: $sshd_config"; return; }

  if ! command -v sshd >/dev/null 2>&1; then
    err "Cannot inspect effective SSH settings because sshd is not available"
    return
  fi

  if ! sshd -t; then
    err "SSH configuration syntax validation failed"
    return
  fi
  ok "SSH configuration syntax is valid"

  if ! effective_config="$(sshd -T 2>&1)"; then
    err "Could not read the effective SSH configuration"
    return
  fi

  if [[ -n "${PORT_SSH:-}" ]] && ss -tln "( sport = :$PORT_SSH )" | grep -q LISTEN; then
    ok "SSHD is listening on PORT_SSH: $PORT_SSH"
  else
    warn "Could not confirm SSH listener from PORT_SSH"
  fi

  while read -r key expected; do
    actual="$(awk -v key="$key" 'tolower($1) == key { print tolower($2); exit }' <<< "$effective_config")"
    if [[ "$actual" == "$expected" ]]; then
      ok "Effective SSH setting: $key=$expected"
    else
      err "Effective SSH setting $key expected $expected, got ${actual:-missing}"
    fi
  done <<EOF
permitrootlogin no
pubkeyauthentication yes
passwordauthentication no
kbdinteractiveauthentication no
permitemptypasswords no
EOF

  if [[ -n "${PORT_SSH:-}" ]]; then
    actual="$(awk 'tolower($1) == "port" { print $2; exit }' <<< "$effective_config")"
    [[ "$actual" == "$PORT_SSH" ]] && ok "Effective SSH port: $PORT_SSH" || err "Effective SSH port expected $PORT_SSH, got ${actual:-missing}"
  fi

  [[ -f "$SSHD_DROPIN_FILE" ]] && ok "Managed SSH drop-in is present: $SSHD_DROPIN_FILE" || err "Managed SSH drop-in is missing: $SSHD_DROPIN_FILE"
  [[ ! -f "$SSHD_LEGACY_DROPIN_FILE" ]] && ok "Obsolete SSH drop-in is absent" || warn "Obsolete SSH drop-in is still present: $SSHD_LEGACY_DROPIN_FILE"
}

check_ufw() {
  section "UFW"
  if ufw status | grep -q "Status: active"; then
    ok "UFW is active"
  else
    err "UFW is not active"
  fi

  if [[ -n "${PORT_SSH:-}" ]] && ufw_has_tcp_port "$PORT_SSH"; then
    ok "SSH port is open in UFW: $PORT_SSH/tcp"
  else
    warn "SSH port was not found in UFW"
  fi

  echo
  info "All UFW rules:"
  ufw status numbered || true
}

main() {
  require_root
  load_env
  check_system
  check_ipv6
  check_ssh
  check_ufw

  section "Summary"
  if (( ERROR_COUNT > 0 )); then
    log_line "ERROR" "$ERROR_COUNT required check(s) failed"
    return 1
  fi
  ok "All required checks passed"
}

main "$@"
