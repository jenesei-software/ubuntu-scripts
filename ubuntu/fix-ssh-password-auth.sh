#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN_FILE="$SSHD_DROPIN_DIR/00-ubuntu-setup.conf"
SSHD_LEGACY_DROPIN_FILE="$SSHD_DROPIN_DIR/99-ubuntu-setup.conf"

LOG_COLOR='\033[1;36m'
LOG_RESET='\033[0m'

TEMP_FILE=""
BACKUP_DIR=""
CONFIG_CHANGED=false
SERVICE_TOUCHED=false
COMPLETED=false

timestamp() { date '+%F %T'; }
log_line() {
  local level="$1"
  shift
  printf '%b[%s] %-7s%b %s\n' "$LOG_COLOR" "$(timestamp)" "$level" "$LOG_RESET" "$*"
}

log() { log_line "INFO" "$*"; }
ok() { log_line "OK" "$*"; }
fail() { log_line "ERROR" "$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/ubuntu && sudo bash fix-ssh-password-auth.sh"; }
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
  else
    ENV_FILE="$SCRIPT_DIR/.env"
  fi
}

load_env() {
  resolve_env_file
  [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"

  PORT_SSH=""
  USER_NAME=""
  SSH_PUB=""

  log "Loading environment from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

validate_env() {
  [[ -n "$PORT_SSH" ]] || fail "PORT_SSH is missing in $ENV_FILE"
  [[ "$PORT_SSH" =~ ^[0-9]+$ ]] || fail "PORT_SSH must be numeric"
  (( PORT_SSH >= 10001 && PORT_SSH <= 65535 )) || fail "PORT_SSH must be between 10001 and 65535"
  [[ -n "$USER_NAME" ]] || fail "USER_NAME is missing in $ENV_FILE"
  [[ -n "$SSH_PUB" ]] || fail "SSH_PUB is missing in $ENV_FILE"
  id "$USER_NAME" >/dev/null 2>&1 || fail "Configured user does not exist: $USER_NAME"
}

check_authorized_key() {
  local user_home
  local authorized_keys

  user_home="$(getent passwd "$USER_NAME" | awk -F: 'NR == 1 { print $6 }')"
  [[ -n "$user_home" ]] || fail "Could not resolve the home directory for $USER_NAME"
  authorized_keys="$user_home/.ssh/authorized_keys"
  [[ -f "$authorized_keys" ]] || fail "Authorized keys file not found for $USER_NAME: $authorized_keys"
  grep -Fqx "$SSH_PUB" "$authorized_keys" || fail "SSH_PUB from $ENV_FILE is not installed for $USER_NAME"
  ok "Configured public key is installed for $USER_NAME"
}

effective_sshd_value() {
  local effective_config="$1"
  local key="$2"
  awk -v key="$key" 'tolower($1) == key { print tolower($2); exit }' <<< "$effective_config"
}

verify_sshd_effective_config() {
  local effective_config
  local key expected actual
  local invalid=0

  if ! effective_config="$(sshd -T 2>&1)"; then
    log_line "ERROR" "Could not read the effective SSH configuration"
    return 1
  fi

  while read -r key expected; do
    actual="$(effective_sshd_value "$effective_config" "$key")"
    if [[ "$actual" == "$expected" ]]; then
      ok "Effective SSH setting: $key=$expected"
    else
      log_line "ERROR" "Effective SSH setting $key must be $expected, got ${actual:-missing}"
      invalid=1
    fi
  done <<EOF
port $PORT_SSH
permitrootlogin no
pubkeyauthentication yes
passwordauthentication no
kbdinteractiveauthentication no
permitemptypasswords no
EOF

  (( invalid == 0 ))
}

restore_managed_files() {
  rm -f "$SSHD_DROPIN_FILE" "$SSHD_LEGACY_DROPIN_FILE"

  if [[ -f "$BACKUP_DIR/sshd_config.d/$(basename -- "$SSHD_DROPIN_FILE")" ]]; then
    cp -a "$BACKUP_DIR/sshd_config.d/$(basename -- "$SSHD_DROPIN_FILE")" "$SSHD_DROPIN_FILE"
  fi

  if [[ -f "$BACKUP_DIR/sshd_config.d/$(basename -- "$SSHD_LEGACY_DROPIN_FILE")" ]]; then
    cp -a "$BACKUP_DIR/sshd_config.d/$(basename -- "$SSHD_LEGACY_DROPIN_FILE")" "$SSHD_LEGACY_DROPIN_FILE"
  fi
}

cleanup() {
  local exit_code=$?

  if [[ -n "$TEMP_FILE" && -f "$TEMP_FILE" ]]; then
    rm -f "$TEMP_FILE"
  fi

  if [[ "$COMPLETED" != "true" && "$CONFIG_CHANGED" == "true" ]]; then
    log_line "WARN" "Repair did not complete; restoring the previous managed SSH files"
    restore_managed_files || true
  fi

  if [[ "$COMPLETED" != "true" && "$SERVICE_TOUCHED" == "true" ]]; then
    sshd -t && systemctl daemon-reload && systemctl restart ssh.service || true
  fi

  return "$exit_code"
}

preflight() {
  local current_config
  local current_port

  require_cmd awk
  require_cmd cmp
  require_cmd getent
  require_cmd grep
  require_cmd install
  require_cmd mktemp
  require_cmd ss
  require_cmd sshd
  require_cmd systemctl

  install -d -m 0755 /run/sshd
  sshd -t || fail "Current SSH configuration is invalid"
  current_config="$(sshd -T)"
  current_port="$(effective_sshd_value "$current_config" port)"
  [[ "$current_port" == "$PORT_SSH" ]] || fail "PORT_SSH in $ENV_FILE is $PORT_SSH, but the effective SSH port is ${current_port:-unknown}"

  check_authorized_key
}

back_up_ssh_config() {
  install -d -m 0755 "$SSHD_DROPIN_DIR"
  BACKUP_DIR="$(mktemp -d /root/ssh-config-backup.XXXXXXXX)"
  chmod 0700 "$BACKUP_DIR"
  cp -a /etc/ssh/sshd_config "$BACKUP_DIR/"
  cp -a "$SSHD_DROPIN_DIR" "$BACKUP_DIR/"
  log "SSH configuration backup: $BACKUP_DIR"
}

write_managed_config() {
  TEMP_FILE="$(mktemp "$SSHD_DROPIN_DIR/.00-ubuntu-setup.conf.XXXXXX")"
  chmod 0644 "$TEMP_FILE"
  cat > "$TEMP_FILE" <<EOF
Port $PORT_SSH
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
EOF

  if [[ ! -f "$SSHD_DROPIN_FILE" ]] || ! cmp -s "$TEMP_FILE" "$SSHD_DROPIN_FILE"; then
    mv -f "$TEMP_FILE" "$SSHD_DROPIN_FILE"
    TEMP_FILE=""
    CONFIG_CHANGED=true
  else
    rm -f "$TEMP_FILE"
    TEMP_FILE=""
  fi

  if [[ -f "$SSHD_LEGACY_DROPIN_FILE" ]]; then
    rm -f "$SSHD_LEGACY_DROPIN_FILE"
    CONFIG_CHANGED=true
  fi
}

restart_and_verify() {
  sshd -t || fail "Generated SSH configuration is invalid"
  verify_sshd_effective_config || fail "Generated SSH configuration did not disable password authentication"

  SERVICE_TOUCHED=true
  systemctl daemon-reload
  systemctl restart ssh.service || fail "SSH service restart failed"

  verify_sshd_effective_config || fail "Effective SSH settings changed unexpectedly after restart"
  ss -tln "( sport = :$PORT_SSH )" | grep -q LISTEN || fail "SSHD is not listening on port $PORT_SSH"
}

main() {
  trap cleanup EXIT
  require_root
  load_env
  validate_env
  preflight
  back_up_ssh_config
  write_managed_config
  restart_and_verify

  COMPLETED=true
  ok "SSH password and keyboard-interactive login are disabled"
  log "Keep the current session open and verify a new key-based login before disconnecting"
  log "Backup: $BACKUP_DIR"
}

main "$@"
