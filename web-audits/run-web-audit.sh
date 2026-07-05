#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
URL_INPUT="${2:-}"
TEST_INPUT="${3:-}"
NODE_KEYRING="/etc/apt/keyrings/nodesource.gpg"
NODE_SOURCE_LIST="/etc/apt/sources.list.d/nodesource.list"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_SOURCE_LIST="/etc/apt/sources.list.d/docker.list"
CHROME_KEYRING="/etc/apt/keyrings/google-chrome.gpg"
CHROME_SOURCE_LIST="/etc/apt/sources.list.d/google-chrome.list"
SUDO=()
DOCKER_CMD=()
LHCI_CMD=()
LHCI_RUNTIME_DIR=""
DOCKER_USED_IN_THIS_RUN=false
DOCKER_WAS_ACTIVE_BEFORE_RUN=true
REPORT_OWNER=""
REPORT_GROUP=""
REPORTS_NEED_CHOWN=false
AUDIT_SOURCE_HOSTNAME=""
AUDIT_SOURCE_PUBLIC_IP=""
AUDIT_SOURCE_LOCAL_IPS=""

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
fail() { log_line "ERROR" "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"; }
is_windows_interop_path() { [[ "$1" == /mnt/c/* || "$1" == *.exe ]]; }

find_linux_command() {
  local command_name="$1"
  local command_path
  local fixed_path

  for fixed_path in "/usr/local/bin/$command_name" "/usr/bin/$command_name" "/bin/$command_name"; do
    if [[ -x "$fixed_path" ]] && ! is_windows_interop_path "$fixed_path"; then
      printf '%s\n' "$fixed_path"
      return 0
    fi
  done

  command -v "$command_name" >/dev/null 2>&1 || return 1
  command_path="$(command -v "$command_name")"
  is_windows_interop_path "$command_path" && return 1

  printf '%s\n' "$command_path"
}

prefer_command_dirs() {
  local command_path

  for command_path in "$@"; do
    [[ -n "$command_path" ]] || continue
    PATH="$(dirname -- "$command_path"):$PATH"
  done
  export PATH
}

load_nvm_if_available() {
  local nvm_sh

  NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  for nvm_sh in "$NVM_DIR/nvm.sh" "$HOME/.nvm/nvm.sh"; do
    [[ -s "$nvm_sh" ]] || continue
    # shellcheck disable=SC1090
    . "$nvm_sh"
    return
  done
}

init_privileges() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    SUDO=()
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
      REPORT_OWNER="$SUDO_USER"
      REPORT_GROUP="$(id -gn "$SUDO_USER")"
      REPORTS_NEED_CHOWN=true
    fi
    return
  fi

  REPORT_OWNER="$(id -un)"
  REPORT_GROUP="$(id -gn)"

  if command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
  else
    SUDO=()
  fi
}

ensure_sudo() {
  local reason="$1"
  [[ ${EUID:-$(id -u)} -eq 0 ]] && return
  (( ${#SUDO[@]} > 0 )) || fail "$reason requires sudo, but sudo is not installed or not available for this user"

  if ! sudo -n true 2>/dev/null; then
    log "$reason requires sudo"
    sudo -v
  fi
}

run_apt_get() {
  local apt_options=(
    -o Acquire::Retries=1
    -o Acquire::http::Timeout=30
    -o Acquire::https::Timeout=30
  )

  ensure_sudo "Installing or updating system packages"
  "${SUDO[@]}" apt-get "${apt_options[@]}" "$@"
}

run_systemctl() {
  ensure_sudo "Managing the Docker system service"
  "${SUDO[@]}" systemctl "$@"
}

docker_cmd() {
  if (( ${#DOCKER_CMD[@]} > 0 )); then
    "${DOCKER_CMD[@]}" "$@"
    return
  fi

  if docker info >/dev/null 2>&1; then
    docker "$@"
    return
  fi

  if (( ${#SUDO[@]} > 0 )); then
    "${SUDO[@]}" docker "$@"
    return
  fi

  docker "$@"
}

set_docker_command() {
  if docker info >/dev/null 2>&1; then
    DOCKER_CMD=(docker)
  elif (( ${#SUDO[@]} > 0 )) && sudo docker info >/dev/null 2>&1; then
    DOCKER_CMD=(sudo docker)
  else
    fail "Docker daemon is not reachable. Check Docker service status and permissions."
  fi
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
    candidate_base="$(basename -- "$SCRIPT_DIR/$candidate")"
    printf '%s/%s\n' "$candidate_dir" "$candidate_base"
  else
    printf '%s/%s\n' "$SCRIPT_DIR" "$candidate"
  fi
}

absolute_module_path() {
  local value="$1"
  local value_dir
  local value_base

  if [[ "$value" = /* ]]; then
    printf '%s\n' "$value"
    return
  fi

  value_dir="$(cd -- "$SCRIPT_DIR/$(dirname -- "$value")" && pwd)"
  value_base="$(basename -- "$value")"
  printf '%s/%s\n' "$value_dir" "$value_base"
}

resolve_env_file() {
  if [[ -n "$ENV_FILE_INPUT" && "$ENV_FILE_INPUT" == *.env ]]; then
    ENV_FILE="$(resolve_env_path "$ENV_FILE_INPUT")"
    URL_INPUT="${2:-}"
    TEST_INPUT="${3:-}"
    return
  fi

  if [[ -f "$SCRIPT_DIR/.env" ]]; then
    ENV_FILE="$SCRIPT_DIR/.env"
  else
    ENV_FILE=""
  fi

  URL_INPUT="${1:-}"
  TEST_INPUT="${2:-}"
}

load_env() {
  resolve_env_file "$@"

  if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
    log "Loading environment from $ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  elif [[ -n "$ENV_FILE" ]]; then
    fail "Environment file not found: $ENV_FILE"
  else
    log "No .env file found; using built-in defaults. Copy env.example to .env to override settings."
  fi

  WEB_AUDIT_RESULTS_DIR="$(absolute_module_path "${WEB_AUDIT_RESULTS_DIR:-reports}")"
  WEB_AUDIT_DEFAULT_TEST="${WEB_AUDIT_DEFAULT_TEST:-all}"
  WEB_AUDIT_NODE_MAJOR="${WEB_AUDIT_NODE_MAJOR:-22}"
  WEB_AUDIT_CHROME_PATH="${WEB_AUDIT_CHROME_PATH:-}"
  WEB_AUDIT_LHCI_VERSION="${WEB_AUDIT_LHCI_VERSION:-latest}"
  WEB_AUDIT_LHCI_RUNS="${WEB_AUDIT_LHCI_RUNS:-1}"
  WEB_AUDIT_LHCI_CHROME_FLAGS="${WEB_AUDIT_LHCI_CHROME_FLAGS:---no-sandbox --disable-dev-shm-usage --disable-gpu --disable-setuid-sandbox}"
  WEB_AUDIT_LHCI_TIMEOUT="${WEB_AUDIT_LHCI_TIMEOUT:-10m}"
  WEB_AUDIT_LHCI_MAX_WAIT_FOR_LOAD="${WEB_AUDIT_LHCI_MAX_WAIT_FOR_LOAD:-45000}"
  WEB_AUDIT_LHCI_MAX_WAIT_FOR_FCP="${WEB_AUDIT_LHCI_MAX_WAIT_FOR_FCP:-30000}"
  WEB_AUDIT_SITESPEED_IMAGE="${WEB_AUDIT_SITESPEED_IMAGE:-sitespeedio/sitespeed.io:41.3.3}"
  WEB_AUDIT_SITESPEED_BROWSER="${WEB_AUDIT_SITESPEED_BROWSER:-chrome}"
  WEB_AUDIT_SITESPEED_RUNS="${WEB_AUDIT_SITESPEED_RUNS:-3}"
  WEB_AUDIT_SITESPEED_CONNECTIVITY="${WEB_AUDIT_SITESPEED_CONNECTIVITY:-native}"
  WEB_AUDIT_SITESPEED_DOCKER_SHM_SIZE="${WEB_AUDIT_SITESPEED_DOCKER_SHM_SIZE:-2g}"
  WEB_AUDIT_SITESPEED_MIN_FREE_GB="${WEB_AUDIT_SITESPEED_MIN_FREE_GB:-8}"
  WEB_AUDIT_SITESPEED_TIMEOUT="${WEB_AUDIT_SITESPEED_TIMEOUT:-30m}"
  WEB_AUDIT_SITESPEED_EXTRA_ARGS="${WEB_AUDIT_SITESPEED_EXTRA_ARGS:-}"
  WEB_AUDIT_CREATE_ZIP="${WEB_AUDIT_CREATE_ZIP:-true}"
  WEB_AUDIT_STOP_DOCKER_AFTER_RUN="${WEB_AUDIT_STOP_DOCKER_AFTER_RUN:-true}"
}

validate_bool() {
  local name="$1"
  local value="$2"
  [[ "$value" == "true" || "$value" == "false" ]] || fail "$name must be true or false"
}

validate_positive_int() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be numeric"
  (( value >= 1 )) || fail "$name must be greater than zero"
}

validate_timeout() {
  local name="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9]+[smhd]?$ ]] || fail "$name must be a timeout like 600, 10m, or 1h"
}

validate_env() {
  [[ "$WEB_AUDIT_DEFAULT_TEST" == "all" || "$WEB_AUDIT_DEFAULT_TEST" == "lighthouse" || "$WEB_AUDIT_DEFAULT_TEST" == "sitespeed" ]] || fail "WEB_AUDIT_DEFAULT_TEST must be all, lighthouse, or sitespeed"
  [[ "$WEB_AUDIT_NODE_MAJOR" =~ ^[0-9]+$ ]] || fail "WEB_AUDIT_NODE_MAJOR must be numeric"
  validate_positive_int WEB_AUDIT_LHCI_RUNS "$WEB_AUDIT_LHCI_RUNS"
  validate_timeout WEB_AUDIT_LHCI_TIMEOUT "$WEB_AUDIT_LHCI_TIMEOUT"
  validate_positive_int WEB_AUDIT_LHCI_MAX_WAIT_FOR_LOAD "$WEB_AUDIT_LHCI_MAX_WAIT_FOR_LOAD"
  validate_positive_int WEB_AUDIT_LHCI_MAX_WAIT_FOR_FCP "$WEB_AUDIT_LHCI_MAX_WAIT_FOR_FCP"
  validate_positive_int WEB_AUDIT_SITESPEED_RUNS "$WEB_AUDIT_SITESPEED_RUNS"
  validate_positive_int WEB_AUDIT_SITESPEED_MIN_FREE_GB "$WEB_AUDIT_SITESPEED_MIN_FREE_GB"
  validate_bool WEB_AUDIT_CREATE_ZIP "$WEB_AUDIT_CREATE_ZIP"
  validate_bool WEB_AUDIT_STOP_DOCKER_AFTER_RUN "$WEB_AUDIT_STOP_DOCKER_AFTER_RUN"
  [[ -n "$WEB_AUDIT_SITESPEED_IMAGE" ]] || fail "WEB_AUDIT_SITESPEED_IMAGE must not be empty"
  [[ -n "$WEB_AUDIT_SITESPEED_BROWSER" ]] || fail "WEB_AUDIT_SITESPEED_BROWSER must not be empty"
}

docker_was_active_before_run() {
  if systemctl is-active --quiet docker 2>/dev/null; then
    DOCKER_WAS_ACTIVE_BEFORE_RUN=true
  else
    DOCKER_WAS_ACTIVE_BEFORE_RUN=false
  fi
}

stop_sitespeed_container_if_running() {
  [[ -n "${SITESPEED_CONTAINER_NAME:-}" ]] || return 0
  command -v docker >/dev/null 2>&1 || return 0

  if docker_cmd ps --format '{{.Names}}' 2>/dev/null | grep -qx "$SITESPEED_CONTAINER_NAME"; then
    warn "Stopping sitespeed.io container: $SITESPEED_CONTAINER_NAME"
    docker_cmd stop "$SITESPEED_CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

stop_docker_if_started_by_this_run() {
  [[ "${WEB_AUDIT_STOP_DOCKER_AFTER_RUN:-true}" == "true" ]] || return 0
  [[ "${DOCKER_USED_IN_THIS_RUN:-false}" == "true" ]] || return 0
  [[ "${DOCKER_WAS_ACTIVE_BEFORE_RUN:-true}" == "false" ]] || return 0
  command -v docker >/dev/null 2>&1 || return 0

  local running_count
  running_count="$(docker_cmd ps -q 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$running_count" == "0" ]]; then
    log "Stopping Docker service because it was started only for this audit run"
    run_systemctl stop docker.socket >/dev/null 2>&1 || true
    run_systemctl stop docker >/dev/null 2>&1 || true
  else
    warn "Docker was started by this audit run, but other containers are running; leaving Docker active"
  fi
}

chown_reports_if_needed() {
  [[ "$REPORTS_NEED_CHOWN" == "true" ]] || return 0
  [[ -n "$REPORT_OWNER" && -n "$REPORT_GROUP" ]] || return 0
  [[ -d "${REPORT_ROOT:-}" ]] || return 0

  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    chown -R "$REPORT_OWNER:$REPORT_GROUP" "$REPORT_ROOT" >/dev/null 2>&1 || true
  elif (( ${#SUDO[@]} > 0 )); then
    "${SUDO[@]}" chown -R "$REPORT_OWNER:$REPORT_GROUP" "$REPORT_ROOT" >/dev/null 2>&1 || true
  else
    return
  fi

  if [[ -n "${ARCHIVE_FILE:-}" && -f "$ARCHIVE_FILE" ]]; then
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
      chown "$REPORT_OWNER:$REPORT_GROUP" "$ARCHIVE_FILE" >/dev/null 2>&1 || true
    else
      "${SUDO[@]}" chown "$REPORT_OWNER:$REPORT_GROUP" "$ARCHIVE_FILE" >/dev/null 2>&1 || true
    fi
  fi
}

cleanup() {
  local exit_code=$?
  mark_failed_metadata_if_needed "$exit_code"
  stop_sitespeed_container_if_running
  stop_docker_if_started_by_this_run
  cleanup_lhci_runtime
  return "$exit_code"
}

prompt_for_url() {
  local value="$URL_INPUT"
  if [[ -z "$value" ]]; then
    printf 'Domain or URL to test: '
    read -r value || value=""
  fi
  [[ -n "$value" ]] || fail "Domain or URL is required"
  TEST_URL="$(normalize_url "$value")"
}

prompt_for_test_type() {
  local value="$TEST_INPUT"
  if [[ -z "$value" ]]; then
    printf 'Test type [all/lighthouse/sitespeed] (default: %s): ' "$WEB_AUDIT_DEFAULT_TEST"
    read -r value || value=""
  fi
  TEST_TYPE="${value:-$WEB_AUDIT_DEFAULT_TEST}"
  [[ "$TEST_TYPE" == "all" || "$TEST_TYPE" == "lighthouse" || "$TEST_TYPE" == "sitespeed" ]] || fail "Test type must be all, lighthouse, or sitespeed"
}

normalize_url() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  [[ "$value" != *" "* ]] || fail "URL must not contain spaces"

  if [[ "$value" != http://* && "$value" != https://* ]]; then
    value="https://$value"
  fi
  [[ "$value" =~ ^https?://[^/]+.*$ ]] || fail "URL must look like https://example.com"
  printf '%s\n' "$value"
}

url_slug() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%#*}"
  value="${value%%\?*}"
  value="$(printf '%s' "$value" | sed -E 's#[^A-Za-z0-9._-]+#_#g; s#^_+##; s#_+$##')"
  [[ -n "$value" ]] || value="site"
  printf '%s\n' "$value"
}

install_base_packages() {
  local missing=()
  local cmd

  for cmd in curl jq openssl tar timeout zip; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if (( ${#missing[@]} == 0 )); then
    log "Base packages are already available"
    return
  fi

  log "Installing missing base packages: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a

  run_apt_get update
  run_apt_get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install ca-certificates coreutils curl gnupg jq openssl tar zip
}

install_node_if_missing() {
  local node_path
  local npm_path

  load_nvm_if_available

  if node_path="$(find_linux_command node)" && npm_path="$(find_linux_command npm)"; then
    prefer_command_dirs "$node_path" "$npm_path"
    log "Linux Node.js and npm are already installed: $("$node_path" --version)"
    log "Node path: $node_path"
    log "npm path: $npm_path"
    return
  fi

  if command -v node >/dev/null 2>&1; then
    warn "Ignoring non-Linux Node.js command on PATH: $(command -v node)"
  fi
  if command -v npm >/dev/null 2>&1; then
    warn "Ignoring non-Linux npm command on PATH: $(command -v npm)"
  fi

  log "Installing Node.js $WEB_AUDIT_NODE_MAJOR.x"
  ensure_sudo "Installing Node.js"
  export DEBIAN_FRONTEND=noninteractive
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a

  run_apt_get update
  run_apt_get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install ca-certificates curl gnupg

  "${SUDO[@]}" install -d -m 0755 /etc/apt/keyrings
  curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
    | "${SUDO[@]}" gpg --batch --yes --dearmor -o "$NODE_KEYRING"
  "${SUDO[@]}" chmod 0644 "$NODE_KEYRING"

  printf 'deb [signed-by=%s] https://deb.nodesource.com/node_%s.x nodistro main\n' "$NODE_KEYRING" "$WEB_AUDIT_NODE_MAJOR" \
    | "${SUDO[@]}" tee "$NODE_SOURCE_LIST" >/dev/null
  "${SUDO[@]}" chmod 0644 "$NODE_SOURCE_LIST"

  run_apt_get update
  run_apt_get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install nodejs

  node_path="$(find_linux_command node)" || fail "Linux Node.js was installed, but node still resolves to a Windows command. Check PATH."
  npm_path="$(find_linux_command npm)" || fail "Linux npm was installed, but npm still resolves to a Windows command. Check PATH."
  prefer_command_dirs "$node_path" "$npm_path"
}

find_linux_chrome() {
  local candidate
  local chrome_path

  for candidate in google-chrome-stable google-chrome chromium chromium-browser; do
    if command -v "$candidate" >/dev/null 2>&1; then
      chrome_path="$(command -v "$candidate")"
      is_windows_interop_path "$chrome_path" && continue
      printf '%s\n' "$chrome_path"
      return 0
    fi
  done

  return 1
}

chrome_command() {
  local chrome_path

  if [[ -n "$WEB_AUDIT_CHROME_PATH" ]]; then
    [[ -x "$WEB_AUDIT_CHROME_PATH" ]] || fail "WEB_AUDIT_CHROME_PATH is set but not executable: $WEB_AUDIT_CHROME_PATH"
    ! is_windows_interop_path "$WEB_AUDIT_CHROME_PATH" || fail "WEB_AUDIT_CHROME_PATH points to Windows Chrome. Install Linux Google Chrome inside WSL/Linux and use that path."
    printf '%s\n' "$WEB_AUDIT_CHROME_PATH"
    return
  fi

  if chrome_path="$(find_linux_chrome)"; then
    printf '%s\n' "$chrome_path"
    return
  fi

  fail "Linux Google Chrome/Chromium executable was not found. Install google-chrome-stable inside Linux/WSL, not Windows Chrome."
}

install_chrome_if_missing() {
  if [[ -n "$WEB_AUDIT_CHROME_PATH" ]]; then
    [[ -x "$WEB_AUDIT_CHROME_PATH" ]] || fail "WEB_AUDIT_CHROME_PATH is set but not executable: $WEB_AUDIT_CHROME_PATH"
    log "Using configured Chrome executable: $WEB_AUDIT_CHROME_PATH"
    return
  fi

  if find_linux_chrome >/dev/null 2>&1; then
    log "Linux Chrome/Chromium is already installed: $(find_linux_chrome)"
    return
  fi

  [[ "$(dpkg --print-architecture)" == "amd64" ]] || fail "Google Chrome apt package is only configured here for amd64. Use sitespeed.io Docker or install a compatible Chromium manually."

  log "Installing Google Chrome stable"
  ensure_sudo "Installing Google Chrome"
  export DEBIAN_FRONTEND=noninteractive
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a

  "${SUDO[@]}" install -d -m 0755 /etc/apt/keyrings
  curl -fsSL "https://dl.google.com/linux/linux_signing_key.pub" \
    | "${SUDO[@]}" gpg --batch --yes --dearmor -o "$CHROME_KEYRING"
  "${SUDO[@]}" chmod 0644 "$CHROME_KEYRING"

  printf 'deb [arch=amd64 signed-by=%s] http://dl.google.com/linux/chrome/deb/ stable main\n' "$CHROME_KEYRING" \
    | "${SUDO[@]}" tee "$CHROME_SOURCE_LIST" >/dev/null
  "${SUDO[@]}" chmod 0644 "$CHROME_SOURCE_LIST"

  run_apt_get update
  run_apt_get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install google-chrome-stable
}

install_lhci_if_missing() {
  local npm_path

  local lhci_dir="$SCRIPT_DIR/.tools/lhci"
  local lhci_bin="$lhci_dir/node_modules/.bin/lhci"

  if [[ -x "$lhci_bin" ]]; then
    log "Using local Lighthouse CI CLI: $lhci_bin"
    LHCI_CMD=("$lhci_bin")
    return
  fi

  log "Installing Lighthouse CI CLI locally: @lhci/cli@$WEB_AUDIT_LHCI_VERSION"
  install -d -m 0755 "$lhci_dir"
  npm_path="$(find_linux_command npm)" || fail "Linux npm command was not found"
  "$npm_path" install --prefix "$lhci_dir" "@lhci/cli@$WEB_AUDIT_LHCI_VERSION"
  LHCI_CMD=("$lhci_bin")
}

preflight_lighthouse() {
  local chrome_path
  local node_path
  local npm_path
  local smoke_log
  local smoke_status=0
  local chrome_flags=()

  chrome_path="$(chrome_command)"
  node_path="$(find_linux_command node)" || fail "Linux Node.js command was not found"
  npm_path="$(find_linux_command npm)" || fail "Linux npm command was not found"
  WEB_AUDIT_CHROME_PATH="$chrome_path"
  export CHROME_PATH="$chrome_path"

  smoke_log="$LOG_DIR/chrome-smoke.log"
  read -r -a chrome_flags <<< "$WEB_AUDIT_LHCI_CHROME_FLAGS"

  log "Node.js: $("$node_path" --version)"
  log "npm: $("$npm_path" --version)"
  log "Chrome: $("$chrome_path" --version)"
  log "Chrome path: $chrome_path"
  log "Lighthouse CI: $("${LHCI_CMD[@]}" --version)"
  log "Lighthouse runs: $WEB_AUDIT_LHCI_RUNS, timeout per run: $WEB_AUDIT_LHCI_TIMEOUT"
  log "Checking headless Chrome startup"

  timeout --foreground 30s "$chrome_path" \
    --headless=new \
    "${chrome_flags[@]}" \
    --disable-background-networking \
    --disable-component-update \
    --disable-sync \
    --metrics-recording-only \
    --no-default-browser-check \
    --no-first-run \
    --user-data-dir="$REPORT_ROOT/chrome-smoke-profile" \
    --dump-dom about:blank > "$smoke_log" 2>&1 || smoke_status=$?

  if (( smoke_status != 0 )); then
    if grep -q '<html' "$smoke_log"; then
      warn "Headless Chrome produced DOM but did not exit cleanly within 30s; continuing. See log: $smoke_log"
    else
      fail "Headless Chrome could not start within 30s. See log: $smoke_log"
    fi
  else
    log "Headless Chrome smoke test passed"
  fi

  rm -rf "$REPORT_ROOT/chrome-smoke-profile"
}

cleanup_lhci_runtime() {
  [[ -n "${LHCI_RUNTIME_DIR:-}" ]] || return 0
  [[ -d "$LHCI_RUNTIME_DIR" ]] || { LHCI_RUNTIME_DIR=""; return 0; }
  rm -rf "$LHCI_RUNTIME_DIR"
  LHCI_RUNTIME_DIR=""
}

prepare_lhci_runtime() {
  cleanup_lhci_runtime
  LHCI_RUNTIME_DIR="$(mktemp -d -t "web-audits-lhci-${RUN_ID}.XXXXXX")"
  install -d -m 0755 \
    "$LHCI_RUNTIME_DIR/tmp" \
    "$LHCI_RUNTIME_DIR/xdg-cache" \
    "$LHCI_RUNTIME_DIR/xdg-config" \
    "$LHCI_RUNTIME_DIR/chrome-profile"
}

run_lhci_with_timeout() {
  local command_timeout="$1"
  shift

  timeout --foreground "$command_timeout" env \
    TMPDIR="$LHCI_RUNTIME_DIR/tmp" \
    TMP="$LHCI_RUNTIME_DIR/tmp" \
    TEMP="$LHCI_RUNTIME_DIR/tmp" \
    XDG_CACHE_HOME="$LHCI_RUNTIME_DIR/xdg-cache" \
    XDG_CONFIG_HOME="$LHCI_RUNTIME_DIR/xdg-config" \
    CHROME_PATH="$WEB_AUDIT_CHROME_PATH" \
    "${LHCI_CMD[@]}" "$@"
}

count_saved_lhci_reports() {
  local target_dir="$1"

  find "$target_dir/.lighthouseci" -maxdepth 1 -type f -name 'lhr-*.json' 2>/dev/null | wc -l | tr -d ' '
}

remove_wsl_chrome_launcher_dirs() {
  local target_dir="$1"

  find "$target_dir" -maxdepth 1 -type d -name 'C:*' -exec rm -rf {} + 2>/dev/null || true
}

install_docker_if_missing() {
  docker_was_active_before_run

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker and Docker Compose are already installed"
    if ! docker info >/dev/null 2>&1 && ! { (( ${#SUDO[@]} > 0 )) && sudo docker info >/dev/null 2>&1; }; then
      run_systemctl enable --now docker
    fi
    DOCKER_USED_IN_THIS_RUN=true
    set_docker_command
    return
  fi

  log "Installing Docker Engine and Docker Compose plugin"
  ensure_sudo "Installing Docker"
  export DEBIAN_FRONTEND=noninteractive
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a

  run_apt_get update
  run_apt_get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install ca-certificates curl gnupg

  "${SUDO[@]}" install -d -m 0755 /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" \
    | "${SUDO[@]}" gpg --batch --yes --dearmor -o "$DOCKER_KEYRING"
  "${SUDO[@]}" chmod 0644 "$DOCKER_KEYRING"

  # shellcheck disable=SC1091
  source /etc/os-release
  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/ubuntu %s stable\n' "$(dpkg --print-architecture)" "$DOCKER_KEYRING" "$VERSION_CODENAME" \
    | "${SUDO[@]}" tee "$DOCKER_SOURCE_LIST" >/dev/null
  "${SUDO[@]}" chmod 0644 "$DOCKER_SOURCE_LIST"

  run_apt_get update
  run_apt_get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  run_systemctl enable --now docker
  DOCKER_USED_IN_THIS_RUN=true
  set_docker_command
}

check_docker_free_space() {
  local docker_root
  local check_path
  local available_kb
  local available_gb
  local required_kb

  [[ "$WEB_AUDIT_SITESPEED_MIN_FREE_GB" =~ ^[0-9]+$ ]] || fail "WEB_AUDIT_SITESPEED_MIN_FREE_GB must be numeric"
  docker_root="$(docker_cmd info --format '{{.DockerRootDir}}' 2>/dev/null || printf '/var/lib/docker')"
  check_path="$docker_root"
  [[ -d "$check_path" ]] || check_path="/var/lib/docker"
  [[ -d /var/lib/containerd ]] && check_path="/var/lib/containerd"

  available_kb="$(df -Pk "$check_path" | awk 'NR == 2 {print $4}')"
  required_kb=$(( WEB_AUDIT_SITESPEED_MIN_FREE_GB * 1024 * 1024 ))
  available_gb=$(( available_kb / 1024 / 1024 ))

  if (( available_kb < required_kb )); then
    fail "Not enough free disk space for sitespeed.io Docker image. Need at least ${WEB_AUDIT_SITESPEED_MIN_FREE_GB}GB free on $check_path, available: ${available_gb}GB. Run lighthouse-only or free disk space."
  fi
}

pull_sitespeed_image_if_missing() {
  if docker_cmd image inspect "$WEB_AUDIT_SITESPEED_IMAGE" >/dev/null 2>&1; then
    log "sitespeed.io Docker image is already present: $WEB_AUDIT_SITESPEED_IMAGE"
    return
  fi

  log "Pulling sitespeed.io Docker image: $WEB_AUDIT_SITESPEED_IMAGE"
  docker_cmd pull "$WEB_AUDIT_SITESPEED_IMAGE"
}

prepare_report_dir() {
  SITE_SLUG="$(url_slug "$TEST_URL")"
  RUN_ID="$(date '+%Y%m%d-%H%M%S')"
  REPORT_ROOT="$WEB_AUDIT_RESULTS_DIR/$SITE_SLUG/$RUN_ID"
  LOG_DIR="$REPORT_ROOT/logs"

  install -d -m 0755 "$REPORT_ROOT" "$LOG_DIR"
}

detect_audit_source() {
  AUDIT_SOURCE_HOSTNAME="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"
  AUDIT_SOURCE_PUBLIC_IP="$(
    curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null \
      || curl -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null \
      || true
  )"
  AUDIT_SOURCE_LOCAL_IPS="$(hostname -I 2>/dev/null | tr -s ' ' ' ' | sed -E 's/^ //; s/ $//' || true)"

  [[ -n "$AUDIT_SOURCE_PUBLIC_IP" ]] || AUDIT_SOURCE_PUBLIC_IP="unknown"
  [[ -n "$AUDIT_SOURCE_LOCAL_IPS" ]] || AUDIT_SOURCE_LOCAL_IPS="unknown"
}

write_metadata() {
  local status="$1"
  jq -n \
    --arg url "$TEST_URL" \
    --arg testType "$TEST_TYPE" \
    --arg runId "$RUN_ID" \
    --arg status "$status" \
    --arg createdAt "$(date -Iseconds)" \
    --arg sourceHostname "$AUDIT_SOURCE_HOSTNAME" \
    --arg sourcePublicIp "$AUDIT_SOURCE_PUBLIC_IP" \
    --arg sourceLocalIps "$AUDIT_SOURCE_LOCAL_IPS" \
    --arg lighthouseRuns "$WEB_AUDIT_LHCI_RUNS" \
    --arg sitespeedRuns "$WEB_AUDIT_SITESPEED_RUNS" \
    --arg sitespeedImage "$WEB_AUDIT_SITESPEED_IMAGE" \
    '{
      url: $url,
      testType: $testType,
      runId: $runId,
      status: $status,
      updatedAt: $createdAt,
      auditSource: {
        hostname: $sourceHostname,
        publicIp: $sourcePublicIp,
        localIps: $sourceLocalIps
      },
      lighthouseRuns: ($lighthouseRuns | tonumber),
      sitespeedRuns: ($sitespeedRuns | tonumber),
      sitespeedImage: $sitespeedImage
    }' > "$REPORT_ROOT/metadata.json"
}

mark_failed_metadata_if_needed() {
  local exit_code="$1"

  (( exit_code != 0 )) || return 0
  [[ -n "${REPORT_ROOT:-}" && -d "${REPORT_ROOT:-}" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  write_metadata "failed" >/dev/null 2>&1 || true
}

write_lhci_config() {
  local target_dir="$1"
  local node_path

  node_path="$(find_linux_command node)" || fail "Linux Node.js command was not found"
  TEST_URL="$TEST_URL" \
  WEB_AUDIT_LHCI_CHROME_FLAGS="$WEB_AUDIT_LHCI_CHROME_FLAGS" \
  WEB_AUDIT_LHCI_CHROME_USER_DATA_DIR="${LHCI_RUNTIME_DIR:-}/chrome-profile" \
  WEB_AUDIT_CHROME_PATH="$WEB_AUDIT_CHROME_PATH" \
  WEB_AUDIT_LHCI_MAX_WAIT_FOR_LOAD="$WEB_AUDIT_LHCI_MAX_WAIT_FOR_LOAD" \
  WEB_AUDIT_LHCI_MAX_WAIT_FOR_FCP="$WEB_AUDIT_LHCI_MAX_WAIT_FOR_FCP" \
    "$node_path" <<'NODE' > "$target_dir/lighthouserc.json"
const chromeFlags = [
  process.env.WEB_AUDIT_LHCI_CHROME_FLAGS ||
    '--no-sandbox --disable-dev-shm-usage --disable-gpu --disable-setuid-sandbox',
  process.env.WEB_AUDIT_LHCI_CHROME_USER_DATA_DIR
    ? `--user-data-dir=${process.env.WEB_AUDIT_LHCI_CHROME_USER_DATA_DIR}`
    : '',
].filter(Boolean).join(' ');

const config = {
  ci: {
    collect: {
      url: [process.env.TEST_URL],
      numberOfRuns: 1,
      chromePath: process.env.WEB_AUDIT_CHROME_PATH,
      settings: {
        chromeFlags,
        maxWaitForLoad: Number(process.env.WEB_AUDIT_LHCI_MAX_WAIT_FOR_LOAD || 45000),
        maxWaitForFcp: Number(process.env.WEB_AUDIT_LHCI_MAX_WAIT_FOR_FCP || 30000)
      }
    },
    upload: {
      target: 'filesystem',
      outputDir: './reports',
      reportFilenamePattern: '%%HOSTNAME%%-%%PATHNAME%%-%%DATETIME%%.report.%%EXTENSION%%'
    }
  }
};

process.stdout.write(`${JSON.stringify(config, null, 2)}\n`);
NODE
}

run_lighthouse_ci() {
  local target_dir="$REPORT_ROOT/lighthouse-ci"
  local log_file="$LOG_DIR/lighthouse-ci.log"
  local lhci_status
  local saved_report_count
  local run_number
  local collect_args=()

  install_node_if_missing
  install_chrome_if_missing
  install_lhci_if_missing
  preflight_lighthouse

  install -d -m 0755 "$target_dir"
  prepare_lhci_runtime
  write_lhci_config "$target_dir"

  log "Running Lighthouse CI for $TEST_URL"
  set +e
  (
    cd "$target_dir"
    printf 'LHCI runtime directory: %s\n' "$LHCI_RUNTIME_DIR"

    for (( run_number = 1; run_number <= WEB_AUDIT_LHCI_RUNS; run_number++ )); do
      printf 'Lighthouse run %s/%s timeout: %s\n' "$run_number" "$WEB_AUDIT_LHCI_RUNS" "$WEB_AUDIT_LHCI_TIMEOUT"
      collect_args=(collect --config=lighthouserc.json)
      if (( run_number > 1 )); then
        collect_args+=(--additive)
      fi

      if ! run_lhci_with_timeout "$WEB_AUDIT_LHCI_TIMEOUT" "${collect_args[@]}"; then
        printf 'Lighthouse CI collect run %s/%s failed or timed out after %s.\n' "$run_number" "$WEB_AUDIT_LHCI_RUNS" "$WEB_AUDIT_LHCI_TIMEOUT"
        exit 1
      fi
    done

    remove_wsl_chrome_launcher_dirs "$target_dir"
    saved_report_count="$(count_saved_lhci_reports "$target_dir")"
    if (( saved_report_count < WEB_AUDIT_LHCI_RUNS )); then
      printf 'Lighthouse CI collect finished, but saved only %s/%s LHR files in %s/.lighthouseci.\n' "$saved_report_count" "$WEB_AUDIT_LHCI_RUNS" "$target_dir"
      exit 1
    fi

    if ! run_lhci_with_timeout "$WEB_AUDIT_LHCI_TIMEOUT" upload --config=lighthouserc.json; then
      printf 'Lighthouse CI upload failed or timed out after %s.\n' "$WEB_AUDIT_LHCI_TIMEOUT"
      exit 1
    fi
  ) 2>&1 | tee "$log_file"
  lhci_status=${PIPESTATUS[0]}
  set -e

  remove_wsl_chrome_launcher_dirs "$target_dir"
  if (( lhci_status != 0 )); then
    fail "Lighthouse CI failed or timed out. Each Lighthouse run has timeout $WEB_AUDIT_LHCI_TIMEOUT. See log: $log_file"
  fi

  [[ -f "$target_dir/reports/manifest.json" ]] || fail "Lighthouse CI report manifest was not created: $target_dir/reports/manifest.json"
  jq -e 'type == "array" and length > 0' "$target_dir/reports/manifest.json" >/dev/null \
    || fail "Lighthouse CI report manifest is empty. See log: $log_file"
  cleanup_lhci_runtime
}

run_sitespeed() {
  local target_dir="$REPORT_ROOT/sitespeed"
  local log_file="$LOG_DIR/sitespeed.log"
  local extra_args=()

  install_docker_if_missing
  check_docker_free_space
  pull_sitespeed_image_if_missing

  install -d -m 0755 "$target_dir"
  REPORTS_NEED_CHOWN=true
  SITESPEED_CONTAINER_NAME="web-audits-sitespeed-$RUN_ID"

  if [[ -n "$WEB_AUDIT_SITESPEED_EXTRA_ARGS" ]]; then
    # shellcheck disable=SC2206
    extra_args=($WEB_AUDIT_SITESPEED_EXTRA_ARGS)
  fi

  log "Running sitespeed.io for $TEST_URL"
  if ! timeout --foreground "$WEB_AUDIT_SITESPEED_TIMEOUT" "${DOCKER_CMD[@]}" run \
    --shm-size "$WEB_AUDIT_SITESPEED_DOCKER_SHM_SIZE" \
    --rm \
    --name "$SITESPEED_CONTAINER_NAME" \
    --label ubuntu-scripts.module=web-audits \
    --label ubuntu-scripts.tool=sitespeed \
    --label ubuntu-scripts.run-id="$RUN_ID" \
    -v "$target_dir:/sitespeed.io" \
    -v /etc/localtime:/etc/localtime:ro \
    "$WEB_AUDIT_SITESPEED_IMAGE" \
    -b "$WEB_AUDIT_SITESPEED_BROWSER" \
    -n "$WEB_AUDIT_SITESPEED_RUNS" \
    -c "$WEB_AUDIT_SITESPEED_CONNECTIVITY" \
    "${extra_args[@]}" \
    "$TEST_URL" 2>&1 | tee "$log_file"; then
    fail "sitespeed.io failed or timed out after $WEB_AUDIT_SITESPEED_TIMEOUT. See log: $log_file"
  fi

  SITESPEED_CONTAINER_NAME=""
  chown_reports_if_needed
}

create_zip_archive() {
  [[ "$WEB_AUDIT_CREATE_ZIP" == "true" ]] || return 0

  ARCHIVE_FILE="$WEB_AUDIT_RESULTS_DIR/$SITE_SLUG/$RUN_ID.zip"
  log "Creating zip archive: $ARCHIVE_FILE"
  (
    cd "$WEB_AUDIT_RESULTS_DIR/$SITE_SLUG"
    zip -qr "$RUN_ID.zip" "$RUN_ID"
  )
  chown_reports_if_needed
}

write_summary() {
  local summary_file="$REPORT_ROOT/summary.txt"
  local ssh_user_hint="${REPORT_OWNER:-root}"
  {
    printf 'URL: %s\n' "$TEST_URL"
    printf 'Test type: %s\n' "$TEST_TYPE"
    printf 'Run ID: %s\n' "$RUN_ID"
    printf 'Audit source hostname: %s\n' "$AUDIT_SOURCE_HOSTNAME"
    printf 'Audit source public IP: %s\n' "$AUDIT_SOURCE_PUBLIC_IP"
    printf 'Audit source local IPs: %s\n' "$AUDIT_SOURCE_LOCAL_IPS"
    printf 'Report directory: %s\n' "$REPORT_ROOT"
    if [[ -n "${ARCHIVE_FILE:-}" ]]; then
      printf 'Zip archive: %s\n' "$ARCHIVE_FILE"
    fi
    printf '\n'
    printf 'Download from Windows PowerShell:\n'
    printf 'scp %s@SERVER_IP:%s C:\\Users\\YOUR_USER\\Downloads\\\n' "$ssh_user_hint" "${ARCHIVE_FILE:-$REPORT_ROOT}"
    printf '\n'
    printf 'If SSH uses a custom port:\n'
    printf 'scp -P PORT %s@SERVER_IP:%s C:\\Users\\YOUR_USER\\Downloads\\\n' "$ssh_user_hint" "${ARCHIVE_FILE:-$REPORT_ROOT}"
  } > "$summary_file"
}

main() {
  trap cleanup EXIT INT TERM

  init_privileges
  load_env "$@"
  validate_env
  prompt_for_url
  prompt_for_test_type
  install_base_packages
  require_cmd jq
  require_cmd timeout
  prepare_report_dir
  detect_audit_source
  write_metadata "running"

  case "$TEST_TYPE" in
    all)
      run_lighthouse_ci
      run_sitespeed
      ;;
    lighthouse)
      run_lighthouse_ci
      ;;
    sitespeed)
      run_sitespeed
      ;;
  esac

  write_metadata "completed"
  create_zip_archive
  write_summary

  log "Web audit complete"
  log "Report directory: $REPORT_ROOT"
  if [[ -n "${ARCHIVE_FILE:-}" ]]; then
    log "Zip archive: $ARCHIVE_FILE"
  fi
}

main "$@"
