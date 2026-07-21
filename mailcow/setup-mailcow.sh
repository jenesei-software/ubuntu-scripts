#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_SOURCE_LIST="/etc/apt/sources.list.d/docker.list"
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts mailcow"
CADDY_MANAGED_SUFFIX="# END ubuntu-scripts mailcow"
MAILCOW_REPOSITORY="https://github.com/mailcow/mailcow-dockerized.git"
ADMIN_DIR="/etc/mailcow"
ADMIN_ENV="$ADMIN_DIR/initial-admin.env"
STATE_DIR="/var/lib/ubuntu-scripts-mailcow"
PENDING_ADMIN_RESET="$STATE_DIR/pending-admin-reset"
MANAGED_INSTALL_STATE="$STATE_DIR/managed-install"
CERT_SYNC_SCRIPT="/usr/local/sbin/mailcow-sync-caddy-cert"
CERT_SYNC_SERVICE="/etc/systemd/system/mailcow-sync-caddy-cert.service"
CERT_SYNC_TIMER="/etc/systemd/system/mailcow-sync-caddy-cert.timer"
CLONE_TMP=""
CLONE_PARENT=""

timestamp() { date '+%F %T'; }
log_line() { local level="$1"; shift; printf '[%s] %-7s %s\n' "$(timestamp)" "$level" "$*"; }
log() { log_line INFO "$*"; }
warn() { log_line WARN "$*"; }
fail() { log_line ERROR "$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/mailcow && bash setup-mailcow.sh"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"; }
cleanup() {
  local resolved_tmp resolved_parent tmp_name
  [[ -n "$CLONE_TMP" && -n "$CLONE_PARENT" && -d "$CLONE_TMP" && -d "$CLONE_PARENT" ]] || return
  resolved_tmp="$(readlink -f -- "$CLONE_TMP" 2>/dev/null || true)"
  resolved_parent="$(readlink -f -- "$CLONE_PARENT" 2>/dev/null || true)"
  tmp_name="$(basename -- "$resolved_tmp")"
  if [[ -n "$resolved_tmp" && -n "$resolved_parent" && "$(dirname -- "$resolved_tmp")" == "$resolved_parent" && "$tmp_name" =~ ^\.mailcow-clone\.[A-Za-z0-9]{6}$ ]]; then
    rm -rf -- "$resolved_tmp"
  else
    warn "Refusing to remove an unexpected temporary checkout path: ${CLONE_TMP:-empty}"
  fi
}
trap cleanup EXIT

resolve_env_path() {
  local candidate="$1"
  if [[ "$candidate" = /* ]]; then
    printf '%s\n' "$candidate"
  elif [[ -f "$candidate" ]]; then
    printf '%s/%s\n' "$(cd -- "$(dirname -- "$candidate")" && pwd)" "$(basename -- "$candidate")"
  elif [[ -f "$SCRIPT_DIR/$candidate" ]]; then
    printf '%s/%s\n' "$SCRIPT_DIR" "$candidate"
  else
    printf '%s/%s\n' "$SCRIPT_DIR" "$candidate"
  fi
}

load_env() {
  if [[ -n "$ENV_FILE_INPUT" ]]; then ENV_FILE="$(resolve_env_path "$ENV_FILE_INPUT")"; else ENV_FILE="$SCRIPT_DIR/.env"; fi
  [[ -f "$ENV_FILE" ]] || fail "Environment file not found. Copy mailcow/env.example to mailcow/.env first."
  [[ "$(stat -c '%a' "$ENV_FILE" 2>/dev/null)" == 600 ]] || fail "Environment file must have mode 0600: chmod 600 $ENV_FILE"

  MAILCOW_HOSTNAME=""; MAILCOW_MAIL_DOMAINS=""; MAILCOW_INSTALL_DIR=""; MAILCOW_TIMEZONE=""
  MAILCOW_VERSION=""; MAILCOW_GIT_COMMIT=""; MAILCOW_UPGRADE_CONFIRMED=""; MAILCOW_ADOPT_EXISTING=""
  MAILCOW_HTTP_BIND=""; MAILCOW_HTTP_PORT=""; MAILCOW_HTTPS_BIND=""; MAILCOW_HTTPS_PORT=""
  MAILCOW_ADDITIONAL_SERVER_NAMES=""; MAILCOW_SKIP_CLAMD=""; MAILCOW_SKIP_FTS=""
  MAILCOW_ENABLE_IPV6=""; MAILCOW_ALLOW_LOW_RESOURCES=""; MAILCOW_CONFIGURE_CADDY=""
  MAILCOW_CADDY_OVERWRITE_DOMAIN=""; MAILCOW_SYNC_CADDY_CERT=""; MAILCOW_CADDY_CERT_STORAGE=""; CADDYFILE=""
  set -a
  # shellcheck disable=SC1090
  trap - EXIT
  source "$ENV_FILE"
  CLONE_TMP=""; CLONE_PARENT=""
  trap cleanup EXIT
  set +a

  MAILCOW_INSTALL_DIR="${MAILCOW_INSTALL_DIR:-/opt/mailcow-dockerized}"
  MAILCOW_TIMEZONE="${MAILCOW_TIMEZONE:-Etc/UTC}"
  MAILCOW_VERSION="${MAILCOW_VERSION:-2026-07}"
  MAILCOW_GIT_COMMIT="${MAILCOW_GIT_COMMIT:-96a70652c320d1c76979610df13c71f363ecc2de}"
  MAILCOW_UPGRADE_CONFIRMED="${MAILCOW_UPGRADE_CONFIRMED:-false}"
  MAILCOW_ADOPT_EXISTING="${MAILCOW_ADOPT_EXISTING:-false}"
  MAILCOW_HTTP_BIND="${MAILCOW_HTTP_BIND:-127.0.0.1}"
  MAILCOW_HTTP_PORT="${MAILCOW_HTTP_PORT:-8080}"
  MAILCOW_HTTPS_BIND="${MAILCOW_HTTPS_BIND:-127.0.0.1}"
  MAILCOW_HTTPS_PORT="${MAILCOW_HTTPS_PORT:-8443}"
  MAILCOW_ADDITIONAL_SERVER_NAMES="${MAILCOW_ADDITIONAL_SERVER_NAMES:-}"
  MAILCOW_MAIL_DOMAINS="${MAILCOW_MAIL_DOMAINS:-}"
  MAILCOW_SKIP_CLAMD="${MAILCOW_SKIP_CLAMD:-false}"
  MAILCOW_SKIP_FTS="${MAILCOW_SKIP_FTS:-false}"
  MAILCOW_ENABLE_IPV6="${MAILCOW_ENABLE_IPV6:-false}"
  MAILCOW_ALLOW_LOW_RESOURCES="${MAILCOW_ALLOW_LOW_RESOURCES:-false}"
  MAILCOW_CONFIGURE_CADDY="${MAILCOW_CONFIGURE_CADDY:-true}"
  CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
  MAILCOW_CADDY_OVERWRITE_DOMAIN="${MAILCOW_CADDY_OVERWRITE_DOMAIN:-ask}"
  MAILCOW_SYNC_CADDY_CERT="${MAILCOW_SYNC_CADDY_CERT:-true}"
  MAILCOW_CADDY_CERT_STORAGE="${MAILCOW_CADDY_CERT_STORAGE:-/var/lib/caddy/.local/share/caddy/certificates}"
}

validate_bool() { [[ "$2" == true || "$2" == false ]] || fail "$1 must be true or false"; }
validate_port() {
  [[ "$2" =~ ^[0-9]+$ ]] || fail "$1 must be numeric"
  (( 10#$2 >= 1 && 10#$2 <= 65535 )) || fail "$1 must be between 1 and 65535"
}
validate_fqdn() {
  local name="$1" value="$2" label
  local -a labels=()
  [[ ${#value} -le 253 && "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || fail "$name must be a valid FQDN"
  [[ "$value" == "${value,,}" ]] || fail "$name must use lowercase DNS names"
  IFS='.' read -r -a labels <<< "$value"
  for label in "${labels[@]}"; do (( ${#label} <= 63 )) || fail "$name contains a DNS label longer than 63 characters"; done
  [[ "$value" != example.com && "$value" != *.example.com ]] || fail "$name still contains the example.com placeholder"
}
validate_fqdn_list() {
  local name="$1" value="$2" item
  local -a items=()
  local -A seen=()
  [[ "$value" != *' '* && "$value" != *, && "$value" != ,* && "$value" != *,,* ]] || fail "$name must be comma-separated without spaces or empty items"
  [[ -z "$value" ]] && return
  IFS=',' read -r -a items <<< "$value"
  for item in "${items[@]}"; do
    validate_fqdn "$name entry" "$item"
    [[ -z "${seen[$item]:-}" ]] || fail "$name contains duplicate entry $item"
    seen["$item"]=1
  done
}

validate_env() {
  validate_fqdn MAILCOW_HOSTNAME "$MAILCOW_HOSTNAME"
  validate_fqdn_list MAILCOW_MAIL_DOMAINS "$MAILCOW_MAIL_DOMAINS"
  validate_fqdn_list MAILCOW_ADDITIONAL_SERVER_NAMES "$MAILCOW_ADDITIONAL_SERVER_NAMES"
  [[ ",$MAILCOW_ADDITIONAL_SERVER_NAMES," != *",$MAILCOW_HOSTNAME,"* ]] || fail "MAILCOW_ADDITIONAL_SERVER_NAMES must not repeat MAILCOW_HOSTNAME"
  [[ "$MAILCOW_INSTALL_DIR" = /* && "$MAILCOW_INSTALL_DIR" != / && "$MAILCOW_INSTALL_DIR" != /opt ]] || fail "MAILCOW_INSTALL_DIR must be a dedicated absolute path"
  [[ "/$MAILCOW_INSTALL_DIR/" != */../* && "/$MAILCOW_INSTALL_DIR/" != */./* ]] || fail "MAILCOW_INSTALL_DIR must not contain . or .. path segments"
  [[ "$MAILCOW_INSTALL_DIR" != *$'\n'* && "$MAILCOW_INSTALL_DIR" != *$'\r'* ]] || fail "MAILCOW_INSTALL_DIR contains an invalid newline"
  [[ "$MAILCOW_TIMEZONE" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f "/usr/share/zoneinfo/$MAILCOW_TIMEZONE" ]] || fail "MAILCOW_TIMEZONE must be a valid IANA timezone"
  [[ "$MAILCOW_VERSION" =~ ^[0-9]{4}-[0-9]{2}([a-z0-9.-]*)?$ ]] || fail "MAILCOW_VERSION must be a pinned release tag"
  [[ "$MAILCOW_GIT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "MAILCOW_GIT_COMMIT must be a full 40-character commit hash"
  validate_port MAILCOW_HTTP_PORT "$MAILCOW_HTTP_PORT"
  validate_port MAILCOW_HTTPS_PORT "$MAILCOW_HTTPS_PORT"
  [[ "$MAILCOW_HTTP_PORT" != "$MAILCOW_HTTPS_PORT" ]] || fail "Mailcow HTTP and HTTPS ports must differ"
  local web_port reserved_port
  for web_port in "$MAILCOW_HTTP_PORT" "$MAILCOW_HTTPS_PORT"; do
    for reserved_port in 25 110 143 465 587 993 995 4190 7654 8081 9081 9082 13306 19991 65510; do
      [[ "$web_port" != "$reserved_port" ]] || fail "Mailcow web ports must not use service-reserved port $reserved_port"
    done
  done
  [[ "$MAILCOW_HTTP_BIND" == 127.0.0.1 && "$MAILCOW_HTTPS_BIND" == 127.0.0.1 ]] || fail "Mailcow web bindings must remain 127.0.0.1 behind Caddy"
  validate_bool MAILCOW_UPGRADE_CONFIRMED "$MAILCOW_UPGRADE_CONFIRMED"
  validate_bool MAILCOW_ADOPT_EXISTING "$MAILCOW_ADOPT_EXISTING"
  validate_bool MAILCOW_SKIP_CLAMD "$MAILCOW_SKIP_CLAMD"
  validate_bool MAILCOW_SKIP_FTS "$MAILCOW_SKIP_FTS"
  validate_bool MAILCOW_ENABLE_IPV6 "$MAILCOW_ENABLE_IPV6"
  validate_bool MAILCOW_ALLOW_LOW_RESOURCES "$MAILCOW_ALLOW_LOW_RESOURCES"
  validate_bool MAILCOW_CONFIGURE_CADDY "$MAILCOW_CONFIGURE_CADDY"
  validate_bool MAILCOW_SYNC_CADDY_CERT "$MAILCOW_SYNC_CADDY_CERT"
  [[ "$MAILCOW_CADDY_OVERWRITE_DOMAIN" == ask || "$MAILCOW_CADDY_OVERWRITE_DOMAIN" == true || "$MAILCOW_CADDY_OVERWRITE_DOMAIN" == false ]] || fail "MAILCOW_CADDY_OVERWRITE_DOMAIN must be ask, true, or false"
  if [[ "$MAILCOW_SYNC_CADDY_CERT" == true ]]; then
    [[ "$MAILCOW_CONFIGURE_CADDY" == true ]] || fail "MAILCOW_SYNC_CADDY_CERT=true requires MAILCOW_CONFIGURE_CADDY=true"
    [[ "$MAILCOW_CADDY_CERT_STORAGE" = /* && "$MAILCOW_CADDY_CERT_STORAGE" != / ]] || fail "MAILCOW_CADDY_CERT_STORAGE must be a specific absolute directory"
    [[ "/$MAILCOW_CADDY_CERT_STORAGE/" != */../* && "/$MAILCOW_CADDY_CERT_STORAGE/" != */./* && "$MAILCOW_CADDY_CERT_STORAGE" != *$'\n'* && "$MAILCOW_CADDY_CERT_STORAGE" != *$'\r'* ]] || fail "MAILCOW_CADDY_CERT_STORAGE is not a safe absolute path"
  fi
  if [[ "$MAILCOW_CONFIGURE_CADDY" == true ]]; then
    [[ "$CADDYFILE" = /* && "$CADDYFILE" != / ]] || fail "CADDYFILE must be a specific absolute file path"
    [[ "/$CADDYFILE/" != */../* && "/$CADDYFILE/" != */./* && "$CADDYFILE" != *$'\n'* && "$CADDYFILE" != *$'\r'* ]] || fail "CADDYFILE is not a safe absolute path"
  fi
}

mailcow_hosts() {
  printf '%s\n' "$MAILCOW_HOSTNAME"
  [[ -z "$MAILCOW_ADDITIONAL_SERVER_NAMES" ]] || tr ',' '\n' <<< "$MAILCOW_ADDITIONAL_SERVER_NAMES"
}

is_mailcow_host() {
  local expected
  while IFS= read -r expected; do [[ "$1" == "$expected" ]] && return 0; done < <(mailcow_hosts)
  return 1
}

caddy_block_for_host() {
  local host="$1"
  [[ -f "$CADDYFILE" ]] || return 0
  awk -v host="$host" '
    function chars(value, char, i, total) { total=0; for (i=1; i<=length(value); i++) if (substr(value,i,1)==char) total++; return total }
    {
      original=$0; line=$0; gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (!inside && line ~ /\{$/) {
        labels=line; sub(/[ \t]*\{$/, "", labels); gsub(/,/, " ", labels)
        count=split(labels, parts, /[ \t]+/)
        for (i=1; i<=count; i++) {
          candidate=parts[i]; sub(/^https?:\/\//, "", candidate); sub(/:443$/, "", candidate); sub(/:80$/, "", candidate)
          if (candidate==host) { inside=1; depth=chars(original,"{")-chars(original,"}"); break }
        }
      }
      if (inside) { print original; if (printed++) depth+=chars(original,"{")-chars(original,"}"); if (depth<=0) exit }
    }
  ' "$CADDYFILE"
}

managed_caddy_section() {
  [[ -f "$CADDYFILE" ]] || return 0
  awk -v begin="$CADDY_MANAGED_PREFIX $MAILCOW_HOSTNAME" -v end="$CADDY_MANAGED_SUFFIX $MAILCOW_HOSTNAME" '
    $0 == begin { inside=1 }
    inside { print }
    inside && $0 == end { exit }
  ' "$CADDYFILE"
}

ensure_replaceable_caddy_block() {
  local block="$1" first labels label
  local -a parsed=()
  first="$(awk 'NF && $0 !~ /^[[:space:]]*#/ {print; exit}' <<< "$block")"
  labels="${first%\{}"; labels="${labels//,/ }"
  read -r -a parsed <<< "$labels"
  for label in "${parsed[@]}"; do
    label="${label#http://}"; label="${label#https://}"; label="${label%:80}"; label="${label%:443}"
    is_mailcow_host "$label" || fail "Caddy host $label shares a block with a Mailcow hostname; refusing to remove that shared block"
  done
}

confirm_caddy_replace() {
  local host="$1" answer
  case "$MAILCOW_CADDY_OVERWRITE_DOMAIN" in
    true) warn "Caddy host $host will be replaced because MAILCOW_CADDY_OVERWRITE_DOMAIN=true"; return 0 ;;
    false) return 1 ;;
  esac
  printf 'Caddy already has an unmanaged block for %s. Replace it with Mailcow? [y/N] ' "$host"
  read -r answer || answer=""
  [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

preflight_caddy() {
  CADDY_REPLACE_HOSTS=()
  [[ "$MAILCOW_CONFIGURE_CADDY" == true ]] || return
  require_cmd caddy; require_cmd systemctl
  systemctl is-active --quiet caddy || fail "Caddy is not active. Install or repair the caddy/ module before Mailcow."
  [[ ! -f "$CADDYFILE" ]] || caddy validate --config "$CADDYFILE" >/dev/null || fail "Existing Caddyfile is invalid; repair it before Mailcow setup"
  local host block managed
  managed="$(managed_caddy_section)"
  while IFS= read -r host; do
    block="$(caddy_block_for_host "$host")"
    [[ -n "$block" ]] || continue
    [[ -n "$managed" && "$managed" == *"$block"* ]] && continue
    ensure_replaceable_caddy_block "$block"
    confirm_caddy_replace "$host" || fail "Caddy already owns $host; setup stopped without changing it"
    CADDY_REPLACE_HOSTS+=("$host")
  done < <(mailcow_hosts)
}

preflight_system() {
  [[ -r /etc/os-release ]] || fail "/etc/os-release is unavailable"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || fail "This module supports Ubuntu 24.04 only"
  case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) fail "Unsupported architecture: $(uname -m)" ;; esac
  require_cmd awk; require_cmd df; require_cmd nproc; require_cmd ss; require_cmd systemd-detect-virt; require_cmd timedatectl
  local virt
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  case "$virt" in lxc|openvz|systemd-nspawn|docker|podman) fail "Mailcow requires a full VM or bare metal; unsupported virtualization: $virt" ;; esac
  [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]] || warn "System clock is not reported as NTP-synchronized; correct time is required for TLS, TOTP, and mail delivery"

  local memory_kb swap_kb available_kb cpu disk_path
  memory_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
  cpu="$(nproc)"
  disk_path="$(dirname -- "$MAILCOW_INSTALL_DIR")"
  while [[ ! -d "$disk_path" && "$disk_path" != / ]]; do disk_path="$(dirname -- "$disk_path")"; done
  available_kb="$(df -Pk "$disk_path" | awk 'NR==2 {print $4}')"
  log "Resources: $cpu CPU, $((memory_kb / 1024 / 1024)) GiB RAM, $((swap_kb / 1024 / 1024)) GiB swap, $((available_kb / 1024 / 1024)) GiB free"
  local -a problems=()
  (( memory_kb >= 6 * 1024 * 1024 )) || problems+=("at least 6 GiB RAM is required for the default configuration")
  (( swap_kb >= 1024 * 1024 )) || problems+=("at least 1 GiB swap is required")
  (( available_kb >= 20 * 1024 * 1024 )) || problems+=("at least 20 GiB free disk space is required before storing mail")
  if (( ${#problems[@]} )); then
    printf ' - %s\n' "${problems[@]}" >&2
    [[ "$MAILCOW_ALLOW_LOW_RESOURCES" == true ]] || fail "Resource preflight failed"
    warn "Continuing because MAILCOW_ALLOW_LOW_RESOURCES=true"
  fi

  if [[ ! -d "$MAILCOW_INSTALL_DIR/.git" ]]; then
    local port
    for port in 25 110 143 465 587 993 995 4190 7654 13306 19991 "$MAILCOW_HTTP_PORT" "$MAILCOW_HTTPS_PORT"; do
      ss -H -ltn "sport = :$port" 2>/dev/null | grep -q . && fail "TCP port $port is already occupied"
    done
  fi
}

install_packages_and_docker() {
  log "Installing Mailcow prerequisites"
  export DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 NEEDRESTART_MODE=a
  apt-get update
  apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install \
    ca-certificates curl dnsutils gawk git gnupg coreutils grep iproute2 jq openssl

  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    log "Installing Docker Engine and Compose from Docker's official repository"
    install -d -m 0755 /etc/apt/keyrings
    local key_tmp fingerprint
    key_tmp="$(mktemp)"
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location https://download.docker.com/linux/ubuntu/gpg -o "$key_tmp"
    fingerprint="$(gpg --batch --show-keys --with-colons "$key_tmp" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
    [[ "$fingerprint" == 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 ]] || { rm -f "$key_tmp"; fail "Docker repository signing key fingerprint is unexpected"; }
    gpg --batch --yes --dearmor -o "$DOCKER_KEYRING" "$key_tmp"
    rm -f "$key_tmp"; chmod 0644 "$DOCKER_KEYRING"
    # shellcheck disable=SC1091
    source /etc/os-release
    printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/ubuntu %s stable\n' "$(dpkg --print-architecture)" "$DOCKER_KEYRING" "$VERSION_CODENAME" > "$DOCKER_SOURCE_LIST"
    chmod 0644 "$DOCKER_SOURCE_LIST"
    apt-get update
    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  systemctl enable --now docker

  local docker_major compose_major
  docker_major="$(docker version --format '{{.Server.Version}}' | cut -d. -f1)"
  compose_major="$(docker compose version --short | sed 's/^v//' | cut -d. -f1)"
  [[ "$docker_major" =~ ^[0-9]+$ && "$docker_major" -ge 24 ]] || fail "Mailcow requires Docker 24 or newer"
  [[ "$compose_major" =~ ^[0-9]+$ && "$compose_major" -ge 2 ]] || fail "Mailcow requires Docker Compose 2 or newer"
}

verify_remote_release() {
  local remote_commit
  remote_commit="$(git ls-remote --exit-code "$MAILCOW_REPOSITORY" "refs/tags/$MAILCOW_VERSION" "refs/tags/$MAILCOW_VERSION^{}" \
    | awk '$2 ~ /\^\{\}$/ {peeled=$1} $2 !~ /\^\{\}$/ {direct=$1} END {print peeled ? peeled : direct}')" \
    || fail "Mailcow release tag was not found: $MAILCOW_VERSION"
  [[ "$remote_commit" == "$MAILCOW_GIT_COMMIT" ]] || fail "MAILCOW_GIT_COMMIT does not match official tag $MAILCOW_VERSION"
}

prepare_checkout() {
  verify_remote_release
  if [[ ! -e "$MAILCOW_INSTALL_DIR" ]]; then
    local parent
    parent="$(dirname -- "$MAILCOW_INSTALL_DIR")"
    install -d -m 0755 "$parent" "$STATE_DIR"
    install -m 0600 /dev/null "$PENDING_ADMIN_RESET"
    install -m 0600 /dev/null "$MANAGED_INSTALL_STATE"
    CLONE_PARENT="$parent"
    CLONE_TMP="$(mktemp -d "$CLONE_PARENT/.mailcow-clone.XXXXXX")"
    log "Cloning Mailcow $MAILCOW_VERSION"
    git clone --depth 1 --single-branch --branch "$MAILCOW_VERSION" "$MAILCOW_REPOSITORY" "$CLONE_TMP/repository"
    [[ "$(git -C "$CLONE_TMP/repository" rev-parse HEAD)" == "$MAILCOW_GIT_COMMIT" ]] || fail "Cloned Mailcow commit failed verification"
    mv -- "$CLONE_TMP/repository" "$MAILCOW_INSTALL_DIR"
    rmdir -- "$CLONE_TMP"; CLONE_TMP=""; CLONE_PARENT=""
    return
  fi

  [[ -d "$MAILCOW_INSTALL_DIR/.git" ]] || fail "$MAILCOW_INSTALL_DIR exists but is not the official Mailcow Git checkout"
  [[ "$(git -C "$MAILCOW_INSTALL_DIR" remote get-url origin)" == "$MAILCOW_REPOSITORY" || "$(git -C "$MAILCOW_INSTALL_DIR" remote get-url origin)" == "${MAILCOW_REPOSITORY%.git}" ]] || fail "Existing Mailcow checkout has an unexpected origin"
  if [[ ! -f "$MANAGED_INSTALL_STATE" ]]; then
    [[ "$MAILCOW_ADOPT_EXISTING" == true ]] || fail "Existing Mailcow checkout is not managed by this module; verify its backup and administrator credentials, then set MAILCOW_ADOPT_EXISTING=true for one run"
    install -d -m 0755 "$STATE_DIR"
    install -m 0600 /dev/null "$MANAGED_INSTALL_STATE"
    if [[ ! -f "$MAILCOW_INSTALL_DIR/mailcow.conf" ]]; then
      install -m 0600 /dev/null "$PENDING_ADMIN_RESET"
    else
      warn "Adopting an existing configured Mailcow installation without rotating its administrator password"
    fi
  fi
  local current
  current="$(git -C "$MAILCOW_INSTALL_DIR" rev-parse HEAD)"
  [[ "$current" != "$MAILCOW_GIT_COMMIT" ]] || return
  if [[ "$MAILCOW_UPGRADE_CONFIRMED" != true ]]; then
    warn "Existing Mailcow commit $current is preserved; set MAILCOW_UPGRADE_CONFIRMED=true only for an intentional upgrade to $MAILCOW_VERSION"
    return
  fi
  [[ -z "$(git -C "$MAILCOW_INSTALL_DIR" status --porcelain --untracked-files=no)" ]] || fail "Tracked Mailcow files are modified; refusing an automated upgrade"
  [[ -f "$MAILCOW_INSTALL_DIR/mailcow.conf" ]] || fail "Existing Mailcow configuration is missing"
  cp -a "$MAILCOW_INSTALL_DIR/mailcow.conf" "$MAILCOW_INSTALL_DIR/mailcow.conf.bak.$(date +%Y%m%d%H%M%S)"
  log "Checking out verified Mailcow release $MAILCOW_VERSION"
  git -C "$MAILCOW_INSTALL_DIR" fetch --depth 1 origin "refs/tags/$MAILCOW_VERSION:refs/tags/$MAILCOW_VERSION"
  git -C "$MAILCOW_INSTALL_DIR" checkout --detach "$MAILCOW_GIT_COMMIT"
}

generate_initial_config() {
  [[ ! -f "$MAILCOW_INSTALL_DIR/mailcow.conf" ]] || return
  log "Generating the initial Mailcow configuration"
  local generator clamd_value
  generator="$MAILCOW_INSTALL_DIR/.ubuntu-scripts-generate-config.$$"
  clamd_value=n; [[ "$MAILCOW_SKIP_CLAMD" == true ]] && clamd_value=y
  awk '$0 == "configure_ipv6" { print "IPV6_BOOL=false"; next } { print }' "$MAILCOW_INSTALL_DIR/generate_config.sh" > "$generator"
  chmod 0700 "$generator"
  if ! (
    cd "$MAILCOW_INSTALL_DIR"
    env MAILCOW_HOSTNAME="$MAILCOW_HOSTNAME" MAILCOW_TZ="$MAILCOW_TIMEZONE" SKIP_CLAMD="$clamd_value" FORCE=y bash "$generator" --dev
  ); then
    rm -f "$generator" "$MAILCOW_INSTALL_DIR/mailcow.conf"
    fail "Mailcow's official configuration generator failed"
  fi
  rm -f "$generator"
  [[ -s "$MAILCOW_INSTALL_DIR/mailcow.conf" ]] || fail "Mailcow configuration was not generated"
}

set_mailcow_conf() {
  local key="$1" value="$2" file="$MAILCOW_INSTALL_DIR/mailcow.conf" tmp
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  awk -v key="$key" -v value="$value" '
    index($0, key "=") == 1 { if (!done) print key "=" value; done=1; next }
    { print }
    END { if (!done) print key "=" value }
  ' "$file" > "$tmp"
  chmod 0600 "$tmp"; mv -f -- "$tmp" "$file"
}

configure_mailcow() {
  local config="$MAILCOW_INSTALL_DIR/mailcow.conf" clamd_value=n fts_value=n
  [[ -f "$config" ]] || fail "Mailcow configuration is missing: $config"
  local existing_hostname
  existing_hostname="$(sed -n 's/^MAILCOW_HOSTNAME=//p' "$config" | tail -n 1)"
  [[ -z "$existing_hostname" || "$existing_hostname" == "$MAILCOW_HOSTNAME" ]] || fail "Existing Mailcow hostname is $existing_hostname; hostname changes require Mailcow's documented migration procedure"
  cp -a "$config" "$config.bak.$(date +%Y%m%d%H%M%S).$$"
  [[ "$MAILCOW_SKIP_CLAMD" == true ]] && clamd_value=y
  [[ "$MAILCOW_SKIP_FTS" == true ]] && fts_value=y
  set_mailcow_conf MAILCOW_HOSTNAME "$MAILCOW_HOSTNAME"
  set_mailcow_conf HTTP_BIND "$MAILCOW_HTTP_BIND"
  set_mailcow_conf HTTP_PORT "$MAILCOW_HTTP_PORT"
  set_mailcow_conf HTTPS_BIND "$MAILCOW_HTTPS_BIND"
  set_mailcow_conf HTTPS_PORT "$MAILCOW_HTTPS_PORT"
  set_mailcow_conf HTTP_REDIRECT n
  set_mailcow_conf SKIP_LETS_ENCRYPT y
  set_mailcow_conf AUTODISCOVER_SAN n
  set_mailcow_conf ADDITIONAL_SERVER_NAMES "$MAILCOW_ADDITIONAL_SERVER_NAMES"
  set_mailcow_conf SKIP_CLAMD "$clamd_value"
  set_mailcow_conf SKIP_FTS "$fts_value"
  set_mailcow_conf ENABLE_IPV6 "$MAILCOW_ENABLE_IPV6"
  set_mailcow_conf TZ "$MAILCOW_TIMEZONE"
  chmod 0600 "$config"
  [[ -L "$MAILCOW_INSTALL_DIR/.env" && "$(readlink "$MAILCOW_INSTALL_DIR/.env")" == mailcow.conf ]] || fail "Mailcow .env symlink must point to mailcow.conf"
}

compose() { (cd "$MAILCOW_INSTALL_DIR" && docker compose "$@"); }

start_mailcow() {
  log "Validating Mailcow Compose configuration"
  compose config >/dev/null
  log "Pulling Mailcow images"
  compose pull
  log "Starting Mailcow"
  compose up -d

  local deadline=$((SECONDS + 600)) service id state health pending
  while (( SECONDS < deadline )); do
    pending=0
    while IFS= read -r service; do
      id="$(compose ps -q "$service" 2>/dev/null || true)"
      [[ -n "$id" ]] || { pending=1; continue; }
      state="$(docker inspect --format '{{.State.Status}}' "$id" 2>/dev/null || true)"
      health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || true)"
      [[ "$state" != exited && "$state" != dead ]] || fail "Mailcow service $service entered state $state"
      [[ "$health" != unhealthy ]] || fail "Mailcow service $service is unhealthy"
      [[ "$state" == running && ( "$health" == healthy || "$health" == none ) ]] || pending=1
    done < <(compose config --services)
    (( pending == 0 )) && break
    sleep 5
  done
  (( pending == 0 )) || fail "Mailcow did not become healthy within 600 seconds"

  deadline=$((SECONDS + 180))
  local code=""
  while (( SECONDS < deadline )); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $MAILCOW_HOSTNAME" --connect-timeout 3 --max-time 10 "http://${MAILCOW_HTTP_BIND}:${MAILCOW_HTTP_PORT}/" 2>/dev/null || true)"
    [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]] && return
    sleep 5
  done
  fail "Mailcow web UI did not become ready (last HTTP status: ${code:-none})"
}

reset_initial_admin() {
  [[ -f "$PENDING_ADMIN_RESET" ]] || return
  log "Replacing Mailcow's default administrator password"
  local helper output password tmp
  helper="$(mktemp)"; output="$(mktemp)"; tmp="$(mktemp)"
  sed 's/docker exec -it/docker exec -i/g' "$MAILCOW_INSTALL_DIR/helper-scripts/mailcow-reset-admin.sh" > "$helper"
  chmod 0700 "$helper"
  if ! (cd "$MAILCOW_INSTALL_DIR" && bash "$helper" --yes 32) > "$output" 2>&1; then
    rm -f "$helper" "$output" "$tmp"
    fail "The official Mailcow administrator reset helper failed; the UI remains loopback-only"
  fi
  password="$(sed -n 's/^Password: //p' "$output" | tail -n 1)"
  rm -f "$helper" "$output"
  [[ "$password" =~ ^[_A-Za-z0-9-]{32}$ ]] || { rm -f "$tmp"; fail "Could not capture the generated Mailcow administrator password"; }
  install -d -m 0700 "$ADMIN_DIR"
  printf 'MAILCOW_ADMIN_USERNAME=admin\nMAILCOW_ADMIN_PASSWORD=%s\n' "$password" > "$tmp"
  install -m 0600 "$tmp" "$ADMIN_ENV"; rm -f "$tmp"
  rm -f "$PENDING_ADMIN_RESET"
  log "Initial administrator credentials were stored in $ADMIN_ENV with mode 0600"
}

managed_caddy_block() {
  local labels="$MAILCOW_HOSTNAME" host
  while IFS= read -r host; do [[ "$host" == "$MAILCOW_HOSTNAME" ]] || labels+=", $host"; done < <(mailcow_hosts)
  cat <<EOF
$CADDY_MANAGED_PREFIX $MAILCOW_HOSTNAME
$labels {
    encode zstd gzip
    reverse_proxy ${MAILCOW_HTTP_BIND}:${MAILCOW_HTTP_PORT}
}
$CADDY_MANAGED_SUFFIX $MAILCOW_HOSTNAME
EOF
}

remove_caddy_block_for_host() {
  local host="$1" tmp
  tmp="$(mktemp)"
  awk -v host="$host" '
    function chars(value, char, i, total) { total=0; for (i=1; i<=length(value); i++) if (substr(value,i,1)==char) total++; return total }
    {
      original=$0; line=$0; gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (!skip && line ~ /\{$/) {
        labels=line; sub(/[ \t]*\{$/, "", labels); gsub(/,/, " ", labels); count=split(labels,parts,/[ \t]+/)
        for (i=1; i<=count; i++) {
          candidate=parts[i]; sub(/^https?:\/\//, "", candidate); sub(/:443$/, "", candidate); sub(/:80$/, "", candidate)
          if (candidate==host) { skip=1; depth=chars(original,"{")-chars(original,"}"); next }
        }
      }
      if (skip) { depth+=chars(original,"{")-chars(original,"}"); if (depth<=0) skip=0; next }
      print original
    }
  ' "$CADDYFILE" > "$tmp"
  cp "$tmp" "$CADDYFILE"; rm -f "$tmp"
}

replace_managed_caddy_block() {
  local tmp block
  tmp="$(mktemp)"; block="$(mktemp)"; managed_caddy_block > "$block"
  awk -v begin="$CADDY_MANAGED_PREFIX $MAILCOW_HOSTNAME" -v end="$CADDY_MANAGED_SUFFIX $MAILCOW_HOSTNAME" -v block="$block" '
    $0==begin { while ((getline line < block)>0) print line; close(block); skip=1; next }
    skip && $0==end { skip=0; next }
    !skip { print }
  ' "$CADDYFILE" > "$tmp"
  cp "$tmp" "$CADDYFILE"; rm -f "$tmp" "$block"
}

configure_caddy() {
  [[ "$MAILCOW_CONFIGURE_CADDY" == true ]] || { warn "Caddy configuration is disabled; expose the Mailcow UI through your reverse proxy before use"; return; }
  local backup="" host
  install -d -m 0755 "$(dirname -- "$CADDYFILE")"
  if [[ -f "$CADDYFILE" ]]; then backup="$CADDYFILE.bak.$(date +%Y%m%d%H%M%S).$$"; cp -a "$CADDYFILE" "$backup"; else touch "$CADDYFILE"; fi
  for host in "${CADDY_REPLACE_HOSTS[@]:-}"; do [[ -z "$host" ]] || remove_caddy_block_for_host "$host"; done
  if grep -Fq "$CADDY_MANAGED_PREFIX $MAILCOW_HOSTNAME" "$CADDYFILE"; then
    replace_managed_caddy_block
  else
    printf '\n' >> "$CADDYFILE"; managed_caddy_block >> "$CADDYFILE"
  fi
  if ! caddy validate --config "$CADDYFILE"; then
    if [[ -n "$backup" ]]; then cp -a "$backup" "$CADDYFILE"; else rm -f "$CADDYFILE"; fi
    fail "Caddy validation failed; the previous Caddyfile was restored"
  fi
  if ! systemctl reload caddy; then
    if [[ -n "$backup" ]]; then cp -a "$backup" "$CADDYFILE"; else rm -f "$CADDYFILE"; fi
    caddy validate --config "$CADDYFILE" >/dev/null && systemctl reload caddy
    fail "Caddy reload failed; the previous Caddyfile was restored"
  fi
}

install_certificate_sync() {
  [[ "$MAILCOW_SYNC_CADDY_CERT" == true ]] || return
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
hostname='$MAILCOW_HOSTNAME'
storage='$MAILCOW_CADDY_CERT_STORAGE'
install_dir='$MAILCOW_INSTALL_DIR'
ssl_dir="\$install_dir/data/assets/ssl"
candidate=''
while IFS= read -r cert_path; do
  issuer="\$(openssl x509 -in "\$cert_path" -noout -issuer 2>/dev/null || true)"
  subject="\$(openssl x509 -in "\$cert_path" -noout -subject 2>/dev/null || true)"
  [[ -n "\$issuer" && "\$issuer" != *'Caddy Local Authority'* && "\${issuer#issuer=}" != "\${subject#subject=}" ]] || continue
  candidate="\$cert_path"
  break
done < <(find "\$storage" -type f -path "*/\$hostname/\$hostname.crt" -printf '%T@ %p\\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
[[ -n "\$candidate" && -f "\$candidate" ]] || { echo "Caddy certificate for \$hostname was not found under \$storage" >&2; exit 1; }
key="\${candidate%.crt}.key"
[[ -f "\$key" ]] || { echo "Caddy private key for \$hostname is missing" >&2; exit 1; }
openssl x509 -in "\$candidate" -noout -checkhost "\$hostname" >/dev/null
openssl x509 -in "\$candidate" -noout -checkend 86400 >/dev/null
cert_pub="\$(mktemp)"; key_pub="\$(mktemp)"
cleanup() { rm -f "\$cert_pub" "\$key_pub"; }
trap cleanup EXIT
openssl x509 -in "\$candidate" -pubkey -noout > "\$cert_pub"
openssl pkey -in "\$key" -pubout > "\$key_pub" 2>/dev/null
cmp -s "\$cert_pub" "\$key_pub" || { echo 'Caddy certificate and key do not match' >&2; exit 1; }
if [[ -f "\$ssl_dir/cert.pem" && -f "\$ssl_dir/key.pem" && -f "\$ssl_dir/\$hostname/cert.pem" && -f "\$ssl_dir/\$hostname/key.pem" && -f "\$ssl_dir/\$hostname/domains" ]] \
  && cmp -s "\$candidate" "\$ssl_dir/cert.pem" && cmp -s "\$key" "\$ssl_dir/key.pem" \
  && cmp -s "\$candidate" "\$ssl_dir/\$hostname/cert.pem" && cmp -s "\$key" "\$ssl_dir/\$hostname/key.pem" \
  && [[ "\$(<"\$ssl_dir/\$hostname/domains")" == "\$hostname" ]]; then exit 0; fi
install -d -m 0755 "\$ssl_dir/\$hostname"
install -m 0644 "\$candidate" "\$ssl_dir/.cert.pem.new"
install -m 0600 "\$key" "\$ssl_dir/.key.pem.new"
mv -f "\$ssl_dir/.cert.pem.new" "\$ssl_dir/cert.pem"
mv -f "\$ssl_dir/.key.pem.new" "\$ssl_dir/key.pem"
install -m 0644 "\$candidate" "\$ssl_dir/\$hostname/.cert.pem.new"
install -m 0600 "\$key" "\$ssl_dir/\$hostname/.key.pem.new"
mv -f "\$ssl_dir/\$hostname/.cert.pem.new" "\$ssl_dir/\$hostname/cert.pem"
mv -f "\$ssl_dir/\$hostname/.key.pem.new" "\$ssl_dir/\$hostname/key.pem"
printf '%s\\n' "\$hostname" > "\$ssl_dir/\$hostname/domains"
chmod 0644 "\$ssl_dir/\$hostname/domains"
cd "\$install_dir"
docker compose restart postfix-mailcow dovecot-mailcow nginx-mailcow >/dev/null
EOF
  install -m 0755 "$tmp" "$CERT_SYNC_SCRIPT"; rm -f "$tmp"

  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
[Unit]
Description=Synchronize Caddy certificate into Mailcow
After=network-online.target docker.service caddy.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$CERT_SYNC_SCRIPT
User=root
Group=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$MAILCOW_INSTALL_DIR/data/assets/ssl
EOF
  install -m 0644 "$tmp" "$CERT_SYNC_SERVICE"; rm -f "$tmp"

  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
[Unit]
Description=Synchronize Caddy certificate into Mailcow periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
RandomizedDelaySec=1min
Persistent=true
Unit=mailcow-sync-caddy-cert.service

[Install]
WantedBy=timers.target
EOF
  install -m 0644 "$tmp" "$CERT_SYNC_TIMER"; rm -f "$tmp"
  systemctl daemon-reload
  systemctl enable --now mailcow-sync-caddy-cert.timer
  if ! systemctl start mailcow-sync-caddy-cert.service; then
    warn "Caddy has not issued the certificate yet; the timer will retry automatically"
  fi
}

main() {
  require_root
  load_env
  validate_env
  preflight_system
  preflight_caddy
  install_packages_and_docker
  prepare_checkout
  generate_initial_config
  configure_mailcow
  start_mailcow
  reset_initial_admin
  configure_caddy
  install_certificate_sync
  log "Mailcow is installed: https://$MAILCOW_HOSTNAME"
  [[ -f "$ADMIN_ENV" ]] && log "Read the initial admin credentials locally: sudo sed -n '1,2p' $ADMIN_ENV"
  log "Diagnostics: cd ~/ubuntu-scripts/mailcow && sudo bash check-setup.sh"
  warn "Keep $MAILCOW_HOSTNAME and all mail DNS records DNS-only in Cloudflare; the normal proxy does not carry SMTP or IMAP"
  warn "Open the required mail ports at the provider firewall and complete MX, PTR, SPF, DKIM, and DMARC before sending mail"
}

main "$@"
