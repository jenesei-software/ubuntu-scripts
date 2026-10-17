#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
SUDOERS_FILE="/etc/sudoers.d/90-coolify-node"

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
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/coolify-node && bash setup-coolify-node.sh"; }
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
  COOLIFY_SSH_PUBLIC_KEY=""
  COOLIFY_USER=""
  COOLIFY_SSH_PORT=""
  COOLIFY_ALLOW_SUDO_NOPASSWD=""
}

# True when the env file has an assignment whose value contains whitespace but is not quoted.
# Such a line would be executed as a command by `source`, so the file is parsed instead.
env_needs_plain_parse() {
  local line

  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*[A-Z_][A-Z0-9_]*= ]] || continue
    line="${line#*=}"
    [[ -z "$line" ]] && continue
    case "$line" in
      \"* | \'*) continue ;;
    esac
    [[ "$line" == *[[:space:]]* ]] && return 0
  done < "$ENV_FILE"

  return 1
}

# Used only when the env file cannot be executed: an unquoted value with spaces turns into a command.
# Reads plain KEY=value pairs, strips one pair of surrounding quotes, ignores everything else.
parse_env_fallback() {
  local line
  local key
  local value

  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
    key="${line%%=*}"
    key="${key//[[:space:]]/}"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    value="${line#*=}"
    value="${value%\'}"
    value="${value#\'}"
    value="${value%\"}"
    value="${value#\"}"
    printf -v "$key" '%s' "$value"
  done < "$ENV_FILE"
}

load_env() {
  resolve_env_file
  reset_env_vars

  if [[ -z "$ENV_FILE" ]]; then
    fail "Environment file not found: copy env.example to .env in $SCRIPT_DIR and fill COOLIFY_SSH_PUBLIC_KEY"
  fi

  [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
  log "Loading environment from $ENV_FILE"

  if env_needs_plain_parse; then
    warn "$ENV_FILE has unquoted values with spaces; reading plain KEY=value pairs instead"
    warn "Quote them, for example: COOLIFY_SSH_PUBLIC_KEY='ssh-ed25519 AAAA... panel'"
    reset_env_vars
    parse_env_fallback
  else
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi

  COOLIFY_SSH_PUBLIC_KEY="${COOLIFY_SSH_PUBLIC_KEY:-}"
  COOLIFY_USER="${COOLIFY_USER:-coolify}"
  COOLIFY_SSH_PORT="${COOLIFY_SSH_PORT:-}"
  COOLIFY_ALLOW_SUDO_NOPASSWD="${COOLIFY_ALLOW_SUDO_NOPASSWD:-true}"

  COOLIFY_SSH_PUBLIC_KEY="$(printf '%s' "$COOLIFY_SSH_PUBLIC_KEY" | tr -d '\r' | sed 's/[[:space:]]*$//')"
}

validate_env() {
  [[ -n "$COOLIFY_SSH_PUBLIC_KEY" ]] \
    || fail "COOLIFY_SSH_PUBLIC_KEY is empty: first create the key in the panel (Settings > Keys & Tokens > + Add), then copy its public part into the env file"

  [[ "$COOLIFY_SSH_PUBLIC_KEY" =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521))[[:space:]]+[A-Za-z0-9+/=]+ ]] \
    || fail "COOLIFY_SSH_PUBLIC_KEY does not look like an OpenSSH public key"

  [[ "$COOLIFY_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || fail "COOLIFY_USER must be a valid lowercase Linux user name"

  [[ "$COOLIFY_USER" != "root" ]] \
    || fail "COOLIFY_USER must not be root: use an unprivileged user with sudo"

  if [[ -n "$COOLIFY_SSH_PORT" ]]; then
    [[ "$COOLIFY_SSH_PORT" =~ ^[0-9]+$ ]] || fail "COOLIFY_SSH_PORT must be numeric"
    (( 10#$COOLIFY_SSH_PORT >= 1 && 10#$COOLIFY_SSH_PORT <= 65535 )) || fail "COOLIFY_SSH_PORT is out of range"
  fi

  case "$COOLIFY_ALLOW_SUDO_NOPASSWD" in
    true | false) ;;
    *) fail "COOLIFY_ALLOW_SUDO_NOPASSWD must be true or false" ;;
  esac
}

detect_ssh_port() {
  local port=""

  if command -v sshd >/dev/null 2>&1; then
    port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
  fi

  printf '%s\n' "${port:-22}"
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

  require_cmd useradd
  require_cmd usermod
  require_cmd visudo
  require_cmd getent
  require_cmd runuser
  ok "Required commands are available: useradd, usermod, visudo, getent, runuser"

  if ! command -v sshd >/dev/null 2>&1; then
    fail "sshd is not installed; the panel cannot connect to this server"
  fi
  ok "Command is available: sshd"

  if command -v docker >/dev/null 2>&1; then
    ok "Docker is already installed"
  else
    log "Docker is not installed yet; the panel installs it on Validate"
  fi
}

ensure_user() {
  section "User"

  if getent passwd "$COOLIFY_USER" >/dev/null 2>&1; then
    ok "User already exists: $COOLIFY_USER"
  else
    useradd --create-home --shell /bin/bash "$COOLIFY_USER"
    ok "Created user: $COOLIFY_USER"
  fi

  if id -nG "$COOLIFY_USER" | tr ' ' '\n' | grep -qx sudo; then
    ok "User is in the sudo group: $COOLIFY_USER"
  else
    usermod -aG sudo "$COOLIFY_USER"
    ok "Added $COOLIFY_USER to the sudo group"
  fi

  USER_HOME="$(getent passwd "$COOLIFY_USER" | cut -d: -f6)"
  [[ -n "$USER_HOME" && -d "$USER_HOME" ]] || fail "Home directory is missing for $COOLIFY_USER"
  ok "Home directory: $USER_HOME"
}

install_key() {
  local ssh_dir="$USER_HOME/.ssh"
  local auth_keys="$ssh_dir/authorized_keys"
  local backup

  section "SSH key"

  install -d -m 700 -o "$COOLIFY_USER" -g "$COOLIFY_USER" "$ssh_dir"
  [[ -f "$auth_keys" ]] || install -m 600 -o "$COOLIFY_USER" -g "$COOLIFY_USER" /dev/null "$auth_keys"
  chmod 600 "$auth_keys"
  chown "$COOLIFY_USER:$COOLIFY_USER" "$auth_keys"

  if grep -qxF -- "$COOLIFY_SSH_PUBLIC_KEY" "$auth_keys"; then
    ok "Key is already authorized for $COOLIFY_USER"
    return
  fi

  if [[ -s "$auth_keys" ]]; then
    backup="$auth_keys.bak.$(date +%Y%m%d%H%M%S)"
    cp -p -- "$auth_keys" "$backup"
    log "Backed up existing keys: $backup"
  fi

  printf '%s\n' "$COOLIFY_SSH_PUBLIC_KEY" >> "$auth_keys"
  ok "Authorized the panel key for $COOLIFY_USER"
  ok "Authorized keys in total: $(grep -c . "$auth_keys")"
}

write_sudoers() {
  local desired

  section "sudo"

  if [[ "$COOLIFY_ALLOW_SUDO_NOPASSWD" != "true" ]]; then
    warn "Skipping passwordless sudo; the panel cannot install Docker or manage the proxy"
    return
  fi

  desired="$COOLIFY_USER ALL=(ALL) NOPASSWD:ALL"

  if [[ -f "$SUDOERS_FILE" ]] && [[ "$(cat "$SUDOERS_FILE")" == "$desired" ]]; then
    ok "Sudoers entry is up to date: $SUDOERS_FILE"
    return
  fi

  TEMP_FILE="$(mktemp /etc/sudoers.d/.90-coolify-node.XXXXXX)"
  printf '%s\n' "$desired" > "$TEMP_FILE"
  chmod 0440 "$TEMP_FILE"
  visudo -cf "$TEMP_FILE" >/dev/null || fail "Generated sudoers file is invalid; nothing was changed"
  mv -f -- "$TEMP_FILE" "$SUDOERS_FILE"
  TEMP_FILE=""
  ok "Wrote sudoers entry: $SUDOERS_FILE"
}

verify_access() {
  section "Verify"

  if sudo -l -U "$COOLIFY_USER" 2>/dev/null | grep -q 'NOPASSWD'; then
    ok "Passwordless sudo is visible for $COOLIFY_USER"
  else
    warn "Passwordless sudo is not visible for $COOLIFY_USER; check $SUDOERS_FILE"
  fi

  if runuser -u "$COOLIFY_USER" -- sudo -n true 2>/dev/null; then
    ok "Passwordless sudo works for $COOLIFY_USER"
  else
    warn "Could not run sudo without a password as $COOLIFY_USER"
  fi

  if sshd -T 2>/dev/null | grep -qi '^pubkeyauthentication yes'; then
    ok "sshd accepts public key authentication"
  else
    warn "sshd does not report 'PubkeyAuthentication yes'; the panel will not connect"
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    if ufw status | grep -qE "^${SSH_PORT}/tcp[[:space:]]+ALLOW"; then
      ok "UFW allows TCP $SSH_PORT"
    else
      warn "UFW shows no allow rule for $SSH_PORT/tcp; the ubuntu module owns that rule"
    fi
  else
    log "UFW is not active; no local firewall rule to check"
  fi
}

main() {
  require_root
  load_env
  validate_env

  SSH_PORT="$COOLIFY_SSH_PORT"
  if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT="$(detect_ssh_port)"
  fi

  check_platform
  ensure_user
  install_key
  write_sudoers
  verify_access

  section "Done"
  log "This server is ready to be added to the panel:"
  log "  Address: <public IP of this server>"
  log "  Port:    $SSH_PORT"
  log "  User:    $COOLIFY_USER"
  log "  Key:     the key whose public part is in $ENV_FILE"
  log "In Coolify: Servers -> + Add, fill the four fields, then Validate."
  log "After Validate: Docker -> Install Docker, Proxy -> Start Proxy."
  log "Recheck any time: cd ~/ubuntu-scripts/coolify-node && bash check-setup.sh"
}

main "$@"
