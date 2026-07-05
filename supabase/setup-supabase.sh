#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_SOURCE_LIST="/etc/apt/sources.list.d/docker.list"
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts supabase"
CADDY_MANAGED_SUFFIX="# END ubuntu-scripts supabase"

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
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/supabase && bash setup-supabase.sh"; }
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
    return
  fi

  if [[ -f "$SCRIPT_DIR/.env" ]]; then
    ENV_FILE="$SCRIPT_DIR/.env"
    return
  fi

  fail "Environment file not found. Copy supabase/env.example to supabase/.env or run: cd supabase && cp env.example .env"
}

reset_env_vars() {
  SUPABASE_URL=""
  SUPABASE_SITE_URL=""
  SUPABASE_ADDITIONAL_REDIRECT_URLS=""
  SUPABASE_INSTALL_DIR=""
  SUPABASE_REPOSITORY=""
  SUPABASE_BRANCH=""
  SUPABASE_BIND_IP=""
  SUPABASE_KONG_HTTP_PORT=""
  SUPABASE_KONG_HTTPS_PORT=""
  SUPABASE_DB_BIND_IP=""
  SUPABASE_POSTGRES_PORT=""
  SUPABASE_POOLER_TRANSACTION_PORT=""
  SUPABASE_POOLER_TENANT_ID=""
  SUPABASE_DASHBOARD_USERNAME=""
  SUPABASE_DASHBOARD_PASSWORD=""
  SUPABASE_POSTGRES_PASSWORD=""
  SUPABASE_STUDIO_DEFAULT_ORGANIZATION=""
  SUPABASE_STUDIO_DEFAULT_PROJECT=""
  SUPABASE_OPENAI_API_KEY=""
  SUPABASE_DISABLE_SIGNUP=""
  SUPABASE_ENABLE_EMAIL_SIGNUP=""
  SUPABASE_ENABLE_EMAIL_AUTOCONFIRM=""
  SUPABASE_ENABLE_PHONE_SIGNUP=""
  SUPABASE_ENABLE_PHONE_AUTOCONFIRM=""
  SUPABASE_SMTP_ADMIN_EMAIL=""
  SUPABASE_SMTP_HOST=""
  SUPABASE_SMTP_PORT=""
  SUPABASE_SMTP_USER=""
  SUPABASE_SMTP_PASS=""
  SUPABASE_SMTP_SENDER_NAME=""
  SUPABASE_SYSTEM_USER=""
  SUPABASE_SYSTEM_PASSWORD=""
  SUPABASE_SYSTEM_SSH_PUB=""
  SUPABASE_ENABLE_LOGS=""
  SUPABASE_CONFIGURE_CADDY=""
  SUPABASE_CADDY_OVERWRITE_DOMAIN=""
  SUPABASE_FORCE_REGENERATE_SECRETS=""
  CADDYFILE=""
}

strip_trailing_slash() {
  local value="$1"
  while [[ "$value" == */ ]]; do
    value="${value%/}"
  done
  printf '%s\n' "$value"
}

load_env() {
  resolve_env_file
  [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
  log "Loading environment from $ENV_FILE"
  reset_env_vars
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  SUPABASE_URL="$(strip_trailing_slash "${SUPABASE_URL:-}")"
  SUPABASE_SITE_URL="$(strip_trailing_slash "${SUPABASE_SITE_URL:-$SUPABASE_URL}")"
  SUPABASE_INSTALL_DIR="${SUPABASE_INSTALL_DIR:-/opt/supabase}"
  SUPABASE_REPOSITORY="${SUPABASE_REPOSITORY:-https://github.com/supabase/supabase.git}"
  SUPABASE_BRANCH="${SUPABASE_BRANCH:-master}"
  SUPABASE_BIND_IP="${SUPABASE_BIND_IP:-127.0.0.1}"
  SUPABASE_KONG_HTTP_PORT="${SUPABASE_KONG_HTTP_PORT:-8000}"
  SUPABASE_KONG_HTTPS_PORT="${SUPABASE_KONG_HTTPS_PORT:-8443}"
  SUPABASE_DB_BIND_IP="${SUPABASE_DB_BIND_IP:-127.0.0.1}"
  SUPABASE_POSTGRES_PORT="${SUPABASE_POSTGRES_PORT:-5432}"
  SUPABASE_POOLER_TRANSACTION_PORT="${SUPABASE_POOLER_TRANSACTION_PORT:-6543}"
  SUPABASE_POOLER_TENANT_ID="${SUPABASE_POOLER_TENANT_ID:-default}"
  SUPABASE_DASHBOARD_USERNAME="${SUPABASE_DASHBOARD_USERNAME:-supabase}"
  SUPABASE_STUDIO_DEFAULT_ORGANIZATION="${SUPABASE_STUDIO_DEFAULT_ORGANIZATION:-DefaultOrganization}"
  SUPABASE_STUDIO_DEFAULT_PROJECT="${SUPABASE_STUDIO_DEFAULT_PROJECT:-DefaultProject}"
  SUPABASE_DISABLE_SIGNUP="${SUPABASE_DISABLE_SIGNUP:-false}"
  SUPABASE_ENABLE_EMAIL_SIGNUP="${SUPABASE_ENABLE_EMAIL_SIGNUP:-true}"
  SUPABASE_ENABLE_EMAIL_AUTOCONFIRM="${SUPABASE_ENABLE_EMAIL_AUTOCONFIRM:-false}"
  SUPABASE_ENABLE_PHONE_SIGNUP="${SUPABASE_ENABLE_PHONE_SIGNUP:-false}"
  SUPABASE_ENABLE_PHONE_AUTOCONFIRM="${SUPABASE_ENABLE_PHONE_AUTOCONFIRM:-false}"
  SUPABASE_SMTP_ADMIN_EMAIL="${SUPABASE_SMTP_ADMIN_EMAIL:-admin@example.com}"
  SUPABASE_SMTP_HOST="${SUPABASE_SMTP_HOST:-supabase-mail}"
  SUPABASE_SMTP_PORT="${SUPABASE_SMTP_PORT:-2500}"
  SUPABASE_SMTP_USER="${SUPABASE_SMTP_USER:-fake_mail_user}"
  SUPABASE_SMTP_PASS="${SUPABASE_SMTP_PASS:-fake_mail_password}"
  SUPABASE_SMTP_SENDER_NAME="${SUPABASE_SMTP_SENDER_NAME:-fake_sender}"
  SUPABASE_SYSTEM_USER="${SUPABASE_SYSTEM_USER:-}"
  SUPABASE_SYSTEM_PASSWORD="${SUPABASE_SYSTEM_PASSWORD:-}"
  SUPABASE_SYSTEM_SSH_PUB="${SUPABASE_SYSTEM_SSH_PUB:-}"
  SUPABASE_ENABLE_LOGS="${SUPABASE_ENABLE_LOGS:-false}"
  SUPABASE_CONFIGURE_CADDY="${SUPABASE_CONFIGURE_CADDY:-true}"
  SUPABASE_CADDY_OVERWRITE_DOMAIN="${SUPABASE_CADDY_OVERWRITE_DOMAIN:-ask}"
  SUPABASE_FORCE_REGENERATE_SECRETS="${SUPABASE_FORCE_REGENERATE_SECRETS:-false}"
  CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
}

require_vars() {
  local missing=()
  for var in SUPABASE_URL SUPABASE_DASHBOARD_PASSWORD SUPABASE_POSTGRES_PASSWORD SUPABASE_POOLER_TENANT_ID; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  if (( ${#missing[@]} > 0 )); then
    fail "Missing required variables in $ENV_FILE: ${missing[*]}"
  fi
}

validate_bool() {
  local name="$1"
  local value="$2"
  [[ "$value" == "true" || "$value" == "false" ]] || fail "$name must be true or false"
}

validate_port() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be numeric"
  (( value >= 1024 && value <= 65535 )) || fail "$name must be between 1024 and 65535"
}

validate_safe_alnum_secret() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[A-Za-z0-9]+$ ]] || fail "$name must contain only letters and digits"
  [[ "$value" =~ [A-Za-z] ]] || fail "$name must contain at least one letter"
}

reject_placeholder() {
  local name="$1"
  local value="$2"
  case "$value" in
    change_me*|this_password_is_insecure*)
      fail "$name still contains a placeholder value. Change it in $ENV_FILE before running setup."
      ;;
  esac
}

validate_system_user_env() {
  [[ -z "$SUPABASE_SYSTEM_USER" ]] && return
  [[ "$SUPABASE_SYSTEM_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail "SUPABASE_SYSTEM_USER must be a valid Linux user name"
  [[ "$SUPABASE_SYSTEM_USER" != "root" ]] || fail "SUPABASE_SYSTEM_USER must not be root"
  [[ "$SUPABASE_SYSTEM_PASSWORD" != *:* ]] || fail "SUPABASE_SYSTEM_PASSWORD must not contain a colon"
  [[ "$SUPABASE_SYSTEM_PASSWORD" != *$'\n'* ]] || fail "SUPABASE_SYSTEM_PASSWORD must not contain a newline"
}

validate_env() {
  [[ "$SUPABASE_URL" =~ ^https?://[^/]+$ ]] || fail "SUPABASE_URL must be a full site URL, for example https://supabase.example.com"
  [[ "$SUPABASE_SITE_URL" =~ ^https?://[^/]+$ ]] || fail "SUPABASE_SITE_URL must be a full site URL, for example https://app.example.com"
  [[ "$SUPABASE_BIND_IP" =~ ^[A-Za-z0-9_.:-]+$ ]] || fail "SUPABASE_BIND_IP contains unsupported characters"
  [[ "$SUPABASE_DB_BIND_IP" =~ ^[A-Za-z0-9_.:-]+$ ]] || fail "SUPABASE_DB_BIND_IP contains unsupported characters"
  validate_port SUPABASE_KONG_HTTP_PORT "$SUPABASE_KONG_HTTP_PORT"
  validate_port SUPABASE_KONG_HTTPS_PORT "$SUPABASE_KONG_HTTPS_PORT"
  validate_port SUPABASE_POSTGRES_PORT "$SUPABASE_POSTGRES_PORT"
  validate_port SUPABASE_POOLER_TRANSACTION_PORT "$SUPABASE_POOLER_TRANSACTION_PORT"
  [[ "$SUPABASE_POOLER_TENANT_ID" =~ ^[A-Za-z0-9_-]+$ ]] || fail "SUPABASE_POOLER_TENANT_ID must contain only letters, digits, underscores, and dashes"
  [[ "$SUPABASE_DASHBOARD_USERNAME" =~ ^[A-Za-z0-9_-]+$ ]] || fail "SUPABASE_DASHBOARD_USERNAME must contain only letters, digits, underscores, and dashes"
  reject_placeholder SUPABASE_DASHBOARD_PASSWORD "$SUPABASE_DASHBOARD_PASSWORD"
  reject_placeholder SUPABASE_POSTGRES_PASSWORD "$SUPABASE_POSTGRES_PASSWORD"
  validate_safe_alnum_secret SUPABASE_DASHBOARD_PASSWORD "$SUPABASE_DASHBOARD_PASSWORD"
  validate_safe_alnum_secret SUPABASE_POSTGRES_PASSWORD "$SUPABASE_POSTGRES_PASSWORD"
  validate_bool SUPABASE_DISABLE_SIGNUP "$SUPABASE_DISABLE_SIGNUP"
  validate_bool SUPABASE_ENABLE_EMAIL_SIGNUP "$SUPABASE_ENABLE_EMAIL_SIGNUP"
  validate_bool SUPABASE_ENABLE_EMAIL_AUTOCONFIRM "$SUPABASE_ENABLE_EMAIL_AUTOCONFIRM"
  validate_bool SUPABASE_ENABLE_PHONE_SIGNUP "$SUPABASE_ENABLE_PHONE_SIGNUP"
  validate_bool SUPABASE_ENABLE_PHONE_AUTOCONFIRM "$SUPABASE_ENABLE_PHONE_AUTOCONFIRM"
  validate_bool SUPABASE_ENABLE_LOGS "$SUPABASE_ENABLE_LOGS"
  validate_bool SUPABASE_CONFIGURE_CADDY "$SUPABASE_CONFIGURE_CADDY"
  validate_bool SUPABASE_FORCE_REGENERATE_SECRETS "$SUPABASE_FORCE_REGENERATE_SECRETS"
  [[ "$SUPABASE_CADDY_OVERWRITE_DOMAIN" == "ask" || "$SUPABASE_CADDY_OVERWRITE_DOMAIN" == "true" || "$SUPABASE_CADDY_OVERWRITE_DOMAIN" == "false" ]] || fail "SUPABASE_CADDY_OVERWRITE_DOMAIN must be ask, true, or false"
  validate_system_user_env
}

service_user_enabled() {
  [[ -n "${SUPABASE_SYSTEM_USER:-}" ]]
}

service_user_home() {
  local home
  home="$(getent passwd "$SUPABASE_SYSTEM_USER" | cut -d: -f6)"
  [[ -n "$home" ]] || home="/home/$SUPABASE_SYSTEM_USER"
  printf '%s\n' "$home"
}

run_as_service_user() {
  if service_user_enabled; then
    runuser -u "$SUPABASE_SYSTEM_USER" -- env HOME="$(service_user_home)" "$@"
  else
    "$@"
  fi
}

run_supabase_command() {
  if service_user_enabled; then
    runuser -u "$SUPABASE_SYSTEM_USER" -- env HOME="$(service_user_home)" bash -c 'cd "$1" && shift && "$@"' _ "$SUPABASE_INSTALL_DIR" "$@"
  else
    (cd "$SUPABASE_INSTALL_DIR" && "$@")
  fi
}

supabase_host() {
  local value="$SUPABASE_URL"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  printf '%s\n' "$value"
}

caddy_block_for_host() {
  local host="$1"
  [[ -f "$CADDYFILE" ]] || return 0

  awk -v host="$host" '
    function count_char(value, char, i, total) {
      total = 0
      for (i = 1; i <= length(value); i++) {
        if (substr(value, i, 1) == char) total++
      }
      return total
    }
    {
      original = $0
      trimmed = original
      gsub(/^[ \t]+|[ \t]+$/, "", trimmed)
      if (!in_block && trimmed ~ /\{$/) {
        labels = trimmed
        sub(/[ \t]*\{$/, "", labels)
        gsub(/[ \t]/, "", labels)
        n = split(labels, parts, ",")
        for (i = 1; i <= n; i++) {
          if (parts[i] == host) {
            in_block = 1
            break
          }
        }
      }
      if (in_block) {
        print original
        depth += count_char(original, "{") - count_char(original, "}")
        if (depth <= 0) exit
        next
      }
    }
  ' "$CADDYFILE"
}

caddy_block_points_to_supabase() {
  local block="$1"
  local upstream="${SUPABASE_BIND_IP}:${SUPABASE_KONG_HTTP_PORT}"

  grep -Fq "reverse_proxy $upstream" <<< "$block" && return 0
  grep -Fq "reverse_proxy http://$upstream" <<< "$block" && return 0
  [[ "$SUPABASE_BIND_IP" == "127.0.0.1" ]] && grep -Fq "reverse_proxy localhost:$SUPABASE_KONG_HTTP_PORT" <<< "$block" && return 0
  [[ "$SUPABASE_BIND_IP" == "127.0.0.1" ]] && grep -Fq "reverse_proxy http://localhost:$SUPABASE_KONG_HTTP_PORT" <<< "$block" && return 0
  return 1
}

confirm_caddy_overwrite() {
  local host="$1"
  local answer

  case "$SUPABASE_CADDY_OVERWRITE_DOMAIN" in
    true)
      log "Caddy domain $host is occupied and will be replaced because SUPABASE_CADDY_OVERWRITE_DOMAIN=true"
      return 0
      ;;
    false)
      return 1
      ;;
  esac

  printf 'Caddy domain %s already exists and points somewhere else. Replace it with Supabase? [y/N] ' "$host"
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES|Yes)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

preflight_caddy() {
  [[ "$SUPABASE_CONFIGURE_CADDY" == "true" ]] || return

  require_cmd caddy
  local host block begin_marker
  host="$(supabase_host)"
  begin_marker="$CADDY_MANAGED_PREFIX $host"

  [[ -f "$CADDYFILE" ]] || return

  if grep -Fq "$begin_marker" "$CADDYFILE"; then
    log "Managed Caddy block already exists for $host and will be updated"
    return
  fi

  block="$(caddy_block_for_host "$host")"
  [[ -z "$block" ]] && return

  if caddy_block_points_to_supabase "$block"; then
    log "Caddy already routes $host to Supabase upstream ${SUPABASE_BIND_IP}:${SUPABASE_KONG_HTTP_PORT}; keeping existing block"
    SUPABASE_CADDY_ALREADY_CONFIGURED=true
    return
  fi

  if confirm_caddy_overwrite "$host"; then
    log "Caddy block for $host will be replaced with Supabase reverse proxy"
    SUPABASE_CADDY_REPLACE_EXISTING_BLOCK=true
    return
  fi

  fail "Caddyfile already contains an unmanaged block for $host. Setup stopped without replacing it."
}

install_prerequisites() {
  log "Installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a

  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install ca-certificates curl git gnupg jq openssl
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker and Docker Compose are already installed"
    systemctl enable --now docker
    return
  fi

  log "Installing Docker Engine and Docker Compose plugin"
  export DEBIAN_FRONTEND=noninteractive
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a

  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install ca-certificates curl gnupg

  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" \
    | gpg --batch --yes --dearmor -o "$DOCKER_KEYRING"
  chmod 0644 "$DOCKER_KEYRING"

  # shellcheck disable=SC1091
  source /etc/os-release
  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/ubuntu %s stable\n' "$(dpkg --print-architecture)" "$DOCKER_KEYRING" "$VERSION_CODENAME" \
    > "$DOCKER_SOURCE_LIST"
  chmod 0644 "$DOCKER_SOURCE_LIST"

  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
}

create_or_update_service_user() {
  service_user_enabled || return
  require_cmd runuser

  local ssh_dir auth_keys

  if id "$SUPABASE_SYSTEM_USER" >/dev/null 2>&1; then
    log "Service user already exists: $SUPABASE_SYSTEM_USER"
  else
    log "Creating service user: $SUPABASE_SYSTEM_USER"
    adduser --disabled-password --gecos "" "$SUPABASE_SYSTEM_USER"
  fi

  if [[ -n "$SUPABASE_SYSTEM_PASSWORD" ]]; then
    log "Updating password for service user: $SUPABASE_SYSTEM_USER"
    printf '%s:%s\n' "$SUPABASE_SYSTEM_USER" "$SUPABASE_SYSTEM_PASSWORD" | chpasswd
  fi

  getent group docker >/dev/null 2>&1 || groupadd docker
  usermod -aG docker "$SUPABASE_SYSTEM_USER"

  if [[ -n "${SUPABASE_SYSTEM_SSH_PUB:-}" ]]; then
    ssh_dir="$(service_user_home)/.ssh"
    auth_keys="$ssh_dir/authorized_keys"

    install -d -m 0700 "$ssh_dir"
    chown "$SUPABASE_SYSTEM_USER:" "$ssh_dir"
    touch "$auth_keys"
    chmod 0600 "$auth_keys"
    chown "$SUPABASE_SYSTEM_USER:" "$auth_keys"

    if ! grep -Fqx "$SUPABASE_SYSTEM_SSH_PUB" "$auth_keys"; then
      log "Adding SSH public key for $SUPABASE_SYSTEM_USER"
      printf '%s\n' "$SUPABASE_SYSTEM_SSH_PUB" >> "$auth_keys"
      chown "$SUPABASE_SYSTEM_USER:" "$auth_keys"
    else
      log "SSH public key is already present for $SUPABASE_SYSTEM_USER"
    fi
  fi

  if ! run_as_service_user docker info >/dev/null 2>&1; then
    fail "Service user $SUPABASE_SYSTEM_USER cannot access Docker. Check docker group membership and Docker socket permissions."
  fi
}

prepare_supabase_project() {
  if [[ -f "$SUPABASE_INSTALL_DIR/docker-compose.yml" && -f "$SUPABASE_INSTALL_DIR/run.sh" ]]; then
    log "Using existing Supabase project: $SUPABASE_INSTALL_DIR"
    if [[ ! -f "$SUPABASE_INSTALL_DIR/.env" && -f "$SUPABASE_INSTALL_DIR/.env.example" ]]; then
      cp "$SUPABASE_INSTALL_DIR/.env.example" "$SUPABASE_INSTALL_DIR/.env"
    fi
    if service_user_enabled; then
      chown -R "$SUPABASE_SYSTEM_USER:" "$SUPABASE_INSTALL_DIR"
    fi
    return
  fi

  if [[ -d "$SUPABASE_INSTALL_DIR" ]] && [[ -n "$(find "$SUPABASE_INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    fail "$SUPABASE_INSTALL_DIR exists but does not look like a Supabase Docker project. Move it or choose another SUPABASE_INSTALL_DIR."
  fi

  log "Fetching Supabase Docker files from $SUPABASE_REPOSITORY ($SUPABASE_BRANCH)"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  git clone --depth 1 --filter=blob:none --sparse --branch "$SUPABASE_BRANCH" "$SUPABASE_REPOSITORY" "$tmp_dir/supabase"
  (cd "$tmp_dir/supabase" && git sparse-checkout set docker)

  install -d -m 0755 "$SUPABASE_INSTALL_DIR"
  cp -a "$tmp_dir/supabase/docker/." "$SUPABASE_INSTALL_DIR/"
  rm -rf "$tmp_dir"

  [[ -f "$SUPABASE_INSTALL_DIR/.env.example" ]] || fail "Supabase .env.example was not copied into $SUPABASE_INSTALL_DIR"
  cp "$SUPABASE_INSTALL_DIR/.env.example" "$SUPABASE_INSTALL_DIR/.env"
  if service_user_enabled; then
    chown -R "$SUPABASE_SYSTEM_USER:" "$SUPABASE_INSTALL_DIR"
  fi
  SUPABASE_FRESH_INSTALL=true
}

env_var_value() {
  local file="$1"
  local name="$2"
  grep -E "^${name}=" "$file" | head -n1 | cut -d= -f2- | tr -d '\r' || true
}

needs_secret_generation() {
  local env_file="$SUPABASE_INSTALL_DIR/.env"
  local jwt_secret
  [[ "$SUPABASE_FORCE_REGENERATE_SECRETS" == "true" ]] && return 0
  [[ "${SUPABASE_FRESH_INSTALL:-false}" == "true" ]] && return 0

  jwt_secret="$(env_var_value "$env_file" JWT_SECRET)"
  [[ -z "$jwt_secret" || "$jwt_secret" == your-super-secret* ]] && return 0
  return 1
}

needs_auth_key_generation() {
  local env_file="$SUPABASE_INSTALL_DIR/.env"
  local publishable_key secret_key jwt_keys
  [[ "$SUPABASE_FORCE_REGENERATE_SECRETS" == "true" ]] && return 0

  publishable_key="$(env_var_value "$env_file" SUPABASE_PUBLISHABLE_KEY)"
  secret_key="$(env_var_value "$env_file" SUPABASE_SECRET_KEY)"
  jwt_keys="$(env_var_value "$env_file" JWT_KEYS)"
  [[ -z "$publishable_key" || -z "$secret_key" || -z "$jwt_keys" ]] && return 0
  return 1
}

generate_supabase_secrets() {
  [[ -f "$SUPABASE_INSTALL_DIR/.env" ]] || fail "Supabase .env is missing: $SUPABASE_INSTALL_DIR/.env"

  if needs_secret_generation; then
    log "Generating Supabase JWT, API, storage, and database secrets"
    run_supabase_command sh utils/generate-keys.sh --update-env
  else
    log "Existing Supabase generated secrets are kept"
  fi

  if needs_auth_key_generation; then
    log "Generating Supabase asymmetric auth keys and opaque API keys"
    run_supabase_command sh utils/add-new-auth-keys.sh --update-env
  else
    log "Existing Supabase auth keys are kept"
  fi

  rm -f "$SUPABASE_INSTALL_DIR/.env.old" "$SUPABASE_INSTALL_DIR/docker-compose.yml.old"
}

escape_sed_replacement() {
  sed -e 's/[\/&|]/\\&/g'
}

set_env_var() {
  local file="$1"
  local name="$2"
  local value="$3"
  local escaped
  escaped="$(printf '%s' "$value" | escape_sed_replacement)"

  if grep -Eq "^${name}=" "$file"; then
    sed -i -e "s|^${name}=.*$|${name}=${escaped}|" "$file"
  else
    printf '\n%s=%s\n' "$name" "$value" >> "$file"
  fi
}

configure_supabase_env() {
  local env_file="$SUPABASE_INSTALL_DIR/.env"
  log "Writing Supabase environment: $env_file"

  set_env_var "$env_file" COMPOSE_FILE "docker-compose.yml"
  set_env_var "$env_file" SUPABASE_PUBLIC_URL "$SUPABASE_URL"
  set_env_var "$env_file" API_EXTERNAL_URL "$SUPABASE_URL"
  set_env_var "$env_file" SITE_URL "$SUPABASE_SITE_URL"
  set_env_var "$env_file" ADDITIONAL_REDIRECT_URLS "$SUPABASE_ADDITIONAL_REDIRECT_URLS"
  set_env_var "$env_file" DASHBOARD_USERNAME "$SUPABASE_DASHBOARD_USERNAME"
  set_env_var "$env_file" DASHBOARD_PASSWORD "$SUPABASE_DASHBOARD_PASSWORD"
  set_env_var "$env_file" POSTGRES_PASSWORD "$SUPABASE_POSTGRES_PASSWORD"
  set_env_var "$env_file" POSTGRES_PORT "$SUPABASE_POSTGRES_PORT"
  set_env_var "$env_file" POOLER_PROXY_PORT_TRANSACTION "$SUPABASE_POOLER_TRANSACTION_PORT"
  set_env_var "$env_file" POOLER_TENANT_ID "$SUPABASE_POOLER_TENANT_ID"
  set_env_var "$env_file" KONG_HTTP_PORT "$SUPABASE_KONG_HTTP_PORT"
  set_env_var "$env_file" KONG_HTTPS_PORT "$SUPABASE_KONG_HTTPS_PORT"
  set_env_var "$env_file" SUPABASE_BIND_IP "$SUPABASE_BIND_IP"
  set_env_var "$env_file" SUPABASE_DB_BIND_IP "$SUPABASE_DB_BIND_IP"
  set_env_var "$env_file" STUDIO_DEFAULT_ORGANIZATION "$SUPABASE_STUDIO_DEFAULT_ORGANIZATION"
  set_env_var "$env_file" STUDIO_DEFAULT_PROJECT "$SUPABASE_STUDIO_DEFAULT_PROJECT"
  set_env_var "$env_file" OPENAI_API_KEY "$SUPABASE_OPENAI_API_KEY"
  set_env_var "$env_file" DISABLE_SIGNUP "$SUPABASE_DISABLE_SIGNUP"
  set_env_var "$env_file" ENABLE_EMAIL_SIGNUP "$SUPABASE_ENABLE_EMAIL_SIGNUP"
  set_env_var "$env_file" ENABLE_EMAIL_AUTOCONFIRM "$SUPABASE_ENABLE_EMAIL_AUTOCONFIRM"
  set_env_var "$env_file" ENABLE_PHONE_SIGNUP "$SUPABASE_ENABLE_PHONE_SIGNUP"
  set_env_var "$env_file" ENABLE_PHONE_AUTOCONFIRM "$SUPABASE_ENABLE_PHONE_AUTOCONFIRM"
  set_env_var "$env_file" SMTP_ADMIN_EMAIL "$SUPABASE_SMTP_ADMIN_EMAIL"
  set_env_var "$env_file" SMTP_HOST "$SUPABASE_SMTP_HOST"
  set_env_var "$env_file" SMTP_PORT "$SUPABASE_SMTP_PORT"
  set_env_var "$env_file" SMTP_USER "$SUPABASE_SMTP_USER"
  set_env_var "$env_file" SMTP_PASS "$SUPABASE_SMTP_PASS"
  set_env_var "$env_file" SMTP_SENDER_NAME "$SUPABASE_SMTP_SENDER_NAME"
  set_env_var "$env_file" PROXY_DOMAIN "$(supabase_host)"

  if service_user_enabled; then
    chown -R "$SUPABASE_SYSTEM_USER:" "$SUPABASE_INSTALL_DIR"
  fi
}

patch_compose_ports() {
  local compose_file="$SUPABASE_INSTALL_DIR/docker-compose.yml"
  log "Restricting Supabase published ports to local bind addresses"

  sed -i \
    -e 's|^\([[:space:]]*-[[:space:]]*\)${KONG_HTTP_PORT}:8000/tcp|\1${SUPABASE_BIND_IP:-127.0.0.1}:${KONG_HTTP_PORT}:8000/tcp|' \
    -e 's|^\([[:space:]]*-[[:space:]]*\)${KONG_HTTPS_PORT}:8443/tcp|\1${SUPABASE_BIND_IP:-127.0.0.1}:${KONG_HTTPS_PORT}:8443/tcp|' \
    -e 's|^\([[:space:]]*-[[:space:]]*\)${POSTGRES_PORT}:5432|\1${SUPABASE_DB_BIND_IP:-127.0.0.1}:${POSTGRES_PORT}:5432|' \
    -e 's|^\([[:space:]]*-[[:space:]]*\)${POOLER_PROXY_PORT_TRANSACTION}:6543|\1${SUPABASE_DB_BIND_IP:-127.0.0.1}:${POOLER_PROXY_PORT_TRANSACTION}:6543|' \
    "$compose_file"

  if grep -Eq '^[[:space:]]*-[[:space:]]*\$\{KONG_HTTP_PORT\}:8000/tcp' "$compose_file" \
    || grep -Eq '^[[:space:]]*-[[:space:]]*\$\{KONG_HTTPS_PORT\}:8443/tcp' "$compose_file" \
    || grep -Eq '^[[:space:]]*-[[:space:]]*\$\{POSTGRES_PORT\}:5432' "$compose_file" \
    || grep -Eq '^[[:space:]]*-[[:space:]]*\$\{POOLER_PROXY_PORT_TRANSACTION\}:6543' "$compose_file"; then
    fail "Could not patch all Supabase port bindings in $compose_file"
  fi

  if service_user_enabled; then
    chown -R "$SUPABASE_SYSTEM_USER:" "$SUPABASE_INSTALL_DIR"
  fi
}

configure_optional_services() {
  if [[ "$SUPABASE_ENABLE_LOGS" == "true" ]]; then
    log "Enabling Supabase logs and analytics override"
    run_supabase_command sh run.sh config add logs
  else
    log "Supabase logs and analytics override is disabled"
  fi
}

validate_compose() {
  log "Validating Supabase Docker Compose config"
  run_supabase_command docker compose config >/dev/null
}

start_supabase() {
  log "Pulling Supabase Docker images"
  run_supabase_command sh run.sh pull
  log "Starting Supabase stack"
  run_supabase_command sh run.sh start
}

managed_caddy_block() {
  local host="$1"
  cat <<EOF
$CADDY_MANAGED_PREFIX $host
$host {
    encode zstd gzip
    reverse_proxy ${SUPABASE_BIND_IP}:${SUPABASE_KONG_HTTP_PORT}
}
$CADDY_MANAGED_SUFFIX $host
EOF
}

replace_managed_caddy_block() {
  local host="$1"
  local tmp_file block_file
  tmp_file="$(mktemp)"
  block_file="$(mktemp)"
  managed_caddy_block "$host" > "$block_file"

  awk -v begin="$CADDY_MANAGED_PREFIX $host" -v end="$CADDY_MANAGED_SUFFIX $host" -v block_file="$block_file" '
    $0 == begin {
      while ((getline line < block_file) > 0) print line
      close(block_file)
      skip = 1
      next
    }
    skip && $0 == end {
      skip = 0
      next
    }
    !skip { print }
  ' "$CADDYFILE" > "$tmp_file"

  cp "$tmp_file" "$CADDYFILE"
  rm -f "$tmp_file" "$block_file"
}

remove_caddy_block_for_host() {
  local host="$1"
  local tmp_file
  tmp_file="$(mktemp)"

  awk -v host="$host" '
    function count_char(value, char, i, total) {
      total = 0
      for (i = 1; i <= length(value); i++) {
        if (substr(value, i, 1) == char) total++
      }
      return total
    }
    {
      original = $0
      line = $0
      gsub(/^[ \t]+|[ \t]+$/, "", line)

      if (!skip && line ~ /\{$/) {
        labels = line
        sub(/[ \t]*\{$/, "", labels)
        gsub(/[ \t]/, "", labels)
        n = split(labels, parts, ",")
        for (i = 1; i <= n; i++) {
          if (parts[i] == host) {
            skip = 1
            depth = count_char(original, "{") - count_char(original, "}")
            if (depth <= 0) skip = 0
            next
          }
        }
      }

      if (skip) {
        depth += count_char(original, "{") - count_char(original, "}")
        if (depth <= 0) skip = 0
        next
      }

      if (!skip) print original
    }
  ' "$CADDYFILE" > "$tmp_file"

  cp "$tmp_file" "$CADDYFILE"
  rm -f "$tmp_file"
}

configure_caddy() {
  [[ "$SUPABASE_CONFIGURE_CADDY" == "true" ]] || {
    log "Skipping Caddy configuration because SUPABASE_CONFIGURE_CADDY=false"
    return
  }
  [[ "${SUPABASE_CADDY_ALREADY_CONFIGURED:-false}" != "true" ]] || return

  local host
  local backup_file=""
  host="$(supabase_host)"
  log "Configuring Caddy for $host -> ${SUPABASE_BIND_IP}:${SUPABASE_KONG_HTTP_PORT}"

  install -d -m 0755 "$(dirname -- "$CADDYFILE")"
  if [[ -f "$CADDYFILE" ]]; then
    backup_file="${CADDYFILE}.bak.$(date +%s)"
    cp "$CADDYFILE" "$backup_file"
  else
    touch "$CADDYFILE"
  fi

  if grep -Fq "$CADDY_MANAGED_PREFIX $host" "$CADDYFILE"; then
    replace_managed_caddy_block "$host"
  else
    if [[ "${SUPABASE_CADDY_REPLACE_EXISTING_BLOCK:-false}" == "true" ]]; then
      remove_caddy_block_for_host "$host"
    fi
    managed_caddy_block "$host" | tee -a "$CADDYFILE" >/dev/null
  fi

  if ! caddy validate --config "$CADDYFILE"; then
    if [[ -n "$backup_file" ]]; then
      cp "$backup_file" "$CADDYFILE"
      fail "Caddy validation failed. Restored backup: $backup_file"
    fi
    rm -f "$CADDYFILE"
    fail "Caddy validation failed. Removed newly created Caddyfile."
  fi

  systemctl reload caddy 2>/dev/null || systemctl restart caddy
}

main() {
  require_root
  load_env
  require_vars
  validate_env
  preflight_caddy
  install_prerequisites
  install_docker
  create_or_update_service_user
  prepare_supabase_project
  generate_supabase_secrets
  configure_supabase_env
  patch_compose_ports
  configure_optional_services
  validate_compose
  start_supabase
  configure_caddy

  log "Done. Supabase URL: $SUPABASE_URL"
  log "Studio basic auth: $SUPABASE_DASHBOARD_USERNAME / value from SUPABASE_DASHBOARD_PASSWORD"
  log "Client URL: $SUPABASE_URL"
}

main "$@"
