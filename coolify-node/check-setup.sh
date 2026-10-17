#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
SUDOERS_FILE="/etc/sudoers.d/90-coolify-node"
USER_HOME=""
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
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/coolify-node && bash check-setup.sh"; }

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
  COOLIFY_SSH_PUBLIC_KEY=""
  COOLIFY_USER="coolify"
  COOLIFY_SSH_PORT=""
  COOLIFY_ALLOW_SUDO_NOPASSWD="true"

  if [[ -z "$ENV_FILE" ]]; then
    warn "Environment file not found; checking with defaults"
  else
    info "Loading environment from $ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
    COOLIFY_SSH_PUBLIC_KEY="${COOLIFY_SSH_PUBLIC_KEY:-}"
    COOLIFY_USER="${COOLIFY_USER:-coolify}"
    COOLIFY_SSH_PORT="${COOLIFY_SSH_PORT:-}"
    COOLIFY_ALLOW_SUDO_NOPASSWD="${COOLIFY_ALLOW_SUDO_NOPASSWD:-true}"
  fi

  COOLIFY_SSH_PUBLIC_KEY="$(printf '%s' "$COOLIFY_SSH_PUBLIC_KEY" | tr -d '\r' | sed 's/[[:space:]]*$//')"
}

detect_ssh_port() {
  local port=""

  if command -v sshd >/dev/null 2>&1; then
    port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
  fi

  printf '%s\n' "${port:-22}"
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

  if command -v docker >/dev/null 2>&1; then
    ok "Docker is installed: $(docker --version 2>/dev/null | head -n 1)"
  else
    warn "Docker is not installed; the panel installs it on Validate"
  fi
}

check_user() {
  section "User"

  if ! getent passwd "$COOLIFY_USER" >/dev/null 2>&1; then
    err "User does not exist: $COOLIFY_USER"
    return
  fi

  ok "User exists: $COOLIFY_USER"

  if id -nG "$COOLIFY_USER" | tr ' ' '\n' | grep -qx sudo; then
    ok "User is in the sudo group: $COOLIFY_USER"
  else
    err "User is not in the sudo group: $COOLIFY_USER"
  fi

  USER_HOME="$(getent passwd "$COOLIFY_USER" | cut -d: -f6)"
  if [[ -n "$USER_HOME" && -d "$USER_HOME" ]]; then
    ok "Home directory: $USER_HOME"
  else
    err "Home directory is missing for $COOLIFY_USER"
  fi
}

check_keys() {
  local ssh_dir="$USER_HOME/.ssh"
  local auth_keys="$ssh_dir/authorized_keys"
  local mode

  section "SSH keys"

  if [[ -z "$USER_HOME" ]]; then
    err "Cannot check SSH keys: the home directory is unknown"
    return
  fi

  if [[ ! -d "$ssh_dir" ]]; then
    err "SSH directory is missing: $ssh_dir"
    return
  fi

  mode="$(stat -c '%a' "$ssh_dir")"
  if [[ "$mode" == "700" ]]; then
    ok "Directory mode is 700: $ssh_dir"
  else
    err "Directory mode is $mode, expected 700: $ssh_dir"
  fi

  if [[ ! -f "$auth_keys" ]]; then
    err "authorized_keys is missing: $auth_keys"
    return
  fi

  mode="$(stat -c '%a' "$auth_keys")"
  if [[ "$mode" == "600" ]]; then
    ok "File mode is 600: $auth_keys"
  else
    err "File mode is $mode, expected 600: $auth_keys"
  fi

  if [[ "$(stat -c '%U' "$auth_keys")" == "$COOLIFY_USER" ]]; then
    ok "File owner is $COOLIFY_USER"
  else
    err "File owner is $(stat -c '%U' "$auth_keys"), expected $COOLIFY_USER"
  fi

  if [[ -z "$COOLIFY_SSH_PUBLIC_KEY" ]]; then
    warn "COOLIFY_SSH_PUBLIC_KEY is not set; the key from the panel cannot be compared"
    return
  fi

  if grep -qxF -- "$COOLIFY_SSH_PUBLIC_KEY" "$auth_keys"; then
    ok "The panel key is authorized for $COOLIFY_USER"
  else
    err "The panel key from the env file is not authorized for $COOLIFY_USER"
  fi
}

check_sudo() {
  section "sudo"

  if [[ "$COOLIFY_ALLOW_SUDO_NOPASSWD" != "true" ]]; then
    info "Passwordless sudo is disabled in the env file"
    return
  fi

  if [[ ! -f "$SUDOERS_FILE" ]]; then
    err "Sudoers entry is missing: $SUDOERS_FILE"
    return
  fi

  if [[ "$(stat -c '%a' "$SUDOERS_FILE")" == "440" ]]; then
    ok "Sudoers file mode is 440: $SUDOERS_FILE"
  else
    err "Sudoers file mode is $(stat -c '%a' "$SUDOERS_FILE"), expected 440"
  fi

  if visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
    ok "Sudoers file passes visudo"
  else
    err "Sudoers file is invalid: $SUDOERS_FILE"
  fi

  if runuser -u "$COOLIFY_USER" -- sudo -n true 2>/dev/null; then
    ok "Passwordless sudo works for $COOLIFY_USER"
  else
    err "Passwordless sudo does not work for $COOLIFY_USER"
  fi
}

check_sshd() {
  section "sshd"

  if ! command -v sshd >/dev/null 2>&1; then
    err "sshd is not installed"
    return
  fi

  if sshd -T 2>/dev/null | grep -qi '^pubkeyauthentication yes'; then
    ok "Public key authentication is enabled"
  else
    err "sshd does not report 'PubkeyAuthentication yes'"
  fi

  local port
  port="$(detect_ssh_port)"

  if [[ -n "$COOLIFY_SSH_PORT" ]]; then
    if [[ "$port" == "$COOLIFY_SSH_PORT" ]]; then
      ok "Configured SSH port matches sshd: $port"
    else
      err "COOLIFY_SSH_PORT is $COOLIFY_SSH_PORT, but sshd listens on $port"
    fi
  else
    info "SSH port from sshd: $port"
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    if ufw status | grep -qE "^${port}/tcp[[:space:]]+ALLOW"; then
      ok "UFW allows TCP $port"
    else
      err "UFW shows no allow rule for $port/tcp"
    fi
  else
    info "UFW is not active"
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
  check_user
  check_keys
  check_sudo
  check_sshd
  summary
}

main "$@"
