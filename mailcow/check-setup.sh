#!/usr/bin/env bash
# The compact diagnostic predicates are safe because ok/warn/err always return zero.
# shellcheck disable=SC2015
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
ENV_FILE=""
CADDY_MANAGED_PREFIX="# BEGIN ubuntu-scripts mailcow"
ADMIN_ENV="/etc/mailcow/initial-admin.env"
PENDING_ADMIN_RESET="/var/lib/ubuntu-scripts-mailcow/pending-admin-reset"
MANAGED_INSTALL_STATE="/var/lib/ubuntu-scripts-mailcow/managed-install"
CERT_SYNC_SCRIPT="/usr/local/sbin/mailcow-sync-caddy-cert"
ERRORS=0
WARNINGS=0

timestamp() { date '+%F %T'; }
line() { local level="$1"; shift; printf '[%s] %-7s %s\n' "$(timestamp)" "$level" "$*"; }
ok() { line OK "$*"; }
info() { line INFO "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); line WARN "$*"; }
err() { ERRORS=$((ERRORS + 1)); line ERROR "$*"; }
section() { printf '\n'; line SECTION "$*"; }
summary() { section "Summary"; line INFO "$ERRORS error(s), $WARNINGS warning(s)"; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Run as root: cd ~/ubuntu-scripts/mailcow && bash check-setup.sh"; summary; exit 1; }; }

resolve_env_path() {
  local candidate="$1"
  if [[ "$candidate" = /* ]]; then printf '%s\n' "$candidate"
  elif [[ -f "$candidate" ]]; then printf '%s/%s\n' "$(cd -- "$(dirname -- "$candidate")" && pwd)" "$(basename -- "$candidate")"
  elif [[ -f "$SCRIPT_DIR/$candidate" ]]; then printf '%s/%s\n' "$SCRIPT_DIR" "$candidate"
  else printf '%s/%s\n' "$SCRIPT_DIR" "$candidate"; fi
}

load_env() {
  if [[ -n "$ENV_FILE_INPUT" ]]; then ENV_FILE="$(resolve_env_path "$ENV_FILE_INPUT")"; else ENV_FILE="$SCRIPT_DIR/.env"; fi
  MAILCOW_HOSTNAME=""; MAILCOW_MAIL_DOMAINS=""; MAILCOW_INSTALL_DIR=""; MAILCOW_TIMEZONE=""
  MAILCOW_VERSION=""; MAILCOW_GIT_COMMIT=""; MAILCOW_UPGRADE_CONFIRMED=""; MAILCOW_ADOPT_EXISTING=""
  MAILCOW_HTTP_BIND=""; MAILCOW_HTTP_PORT=""; MAILCOW_HTTPS_BIND=""; MAILCOW_HTTPS_PORT=""
  MAILCOW_ADDITIONAL_SERVER_NAMES=""; MAILCOW_SKIP_CLAMD=""; MAILCOW_SKIP_FTS=""
  MAILCOW_ENABLE_IPV6=""; MAILCOW_ALLOW_LOW_RESOURCES=""; MAILCOW_CONFIGURE_CADDY=""
  MAILCOW_CADDY_OVERWRITE_DOMAIN=""; MAILCOW_SYNC_CADDY_CERT=""; MAILCOW_CADDY_CERT_STORAGE=""; CADDYFILE=""
  if [[ -f "$ENV_FILE" ]]; then
    info "Loading environment from $ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  else
    warn "Environment file not found: $ENV_FILE"
  fi
  MAILCOW_INSTALL_DIR="${MAILCOW_INSTALL_DIR:-/opt/mailcow-dockerized}"
  MAILCOW_TIMEZONE="${MAILCOW_TIMEZONE:-Etc/UTC}"
  MAILCOW_VERSION="${MAILCOW_VERSION:-2026-07}"
  MAILCOW_GIT_COMMIT="${MAILCOW_GIT_COMMIT:-96a70652c320d1c76979610df13c71f363ecc2de}"
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
  MAILCOW_CONFIGURE_CADDY="${MAILCOW_CONFIGURE_CADDY:-true}"
  CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
  MAILCOW_SYNC_CADDY_CERT="${MAILCOW_SYNC_CADDY_CERT:-true}"
  MAILCOW_CADDY_CERT_STORAGE="${MAILCOW_CADDY_CERT_STORAGE:-/var/lib/caddy/.local/share/caddy/certificates}"
}

conf_value() { [[ -f "$MAILCOW_INSTALL_DIR/mailcow.conf" ]] || return 0; sed -n "s/^$1=//p" "$MAILCOW_INSTALL_DIR/mailcow.conf" | tail -n 1; }
compose() { (cd "$MAILCOW_INSTALL_DIR" && docker compose "$@"); }
check_cmd() { command -v "$1" >/dev/null 2>&1 && ok "Command found: $1" || err "Command not found: $1"; }
check_service() { systemctl is-active --quiet "$1" 2>/dev/null && ok "Service $1 is active" || err "Service $1 is not active"; }

check_system() {
  section "Base system"
  check_cmd awk; check_cmd df; check_cmd docker; check_cmd curl; check_cmd dig; check_cmd git; check_cmd jq; check_cmd openssl; check_cmd ss; check_cmd systemctl; check_cmd systemd-detect-virt; check_cmd timedatectl
  [[ "$MAILCOW_CONFIGURE_CADDY" == true ]] && check_cmd caddy
  [[ -r /etc/os-release ]] && grep -q '^VERSION_ID="\?24\.04"\?$' /etc/os-release && ok "Ubuntu 24.04 detected" || err "Ubuntu 24.04 was not detected"
  local virt memory_kb swap_kb free_kb
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  case "$virt" in lxc|openvz|systemd-nspawn|docker|podman) err "Unsupported container virtualization detected: $virt" ;; *) ok "Full virtualization or bare metal detected (${virt:-none})" ;; esac
  [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]] && ok "System clock is NTP-synchronized" || warn "System clock is not reported as NTP-synchronized"
  memory_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
  swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
  free_kb="$(df -Pk "$MAILCOW_INSTALL_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ "$memory_kb" =~ ^[0-9]+$ && "$memory_kb" -ge $((6 * 1024 * 1024)) ]] && ok "At least 6 GiB RAM is available" || warn "Less than 6 GiB RAM is available"
  [[ "$swap_kb" =~ ^[0-9]+$ && "$swap_kb" -ge $((1024 * 1024)) ]] && ok "At least 1 GiB swap is configured" || warn "Less than 1 GiB swap is configured"
  [[ "$free_kb" =~ ^[0-9]+$ && "$free_kb" -ge $((5 * 1024 * 1024)) ]] && ok "At least 5 GiB disk space remains" || warn "Less than 5 GiB disk space remains"
  command -v docker >/dev/null 2>&1 && check_service docker
  docker compose version >/dev/null 2>&1 && ok "Docker Compose plugin is available" || err "Docker Compose plugin is unavailable"
  local docker_major compose_major
  docker_major="$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1)"
  compose_major="$(docker compose version --short 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
  [[ "$docker_major" =~ ^[0-9]+$ && "$docker_major" -ge 24 ]] && ok "Docker version satisfies Mailcow requirements" || err "Docker 24 or newer is required"
  [[ "$compose_major" =~ ^[0-9]+$ && "$compose_major" -ge 2 ]] && ok "Docker Compose version satisfies Mailcow requirements" || err "Docker Compose 2 or newer is required"
}

check_files() {
  section "Checkout and configuration"
  if [[ -f "$ENV_FILE" ]]; then
    [[ "$(stat -c '%a' "$ENV_FILE" 2>/dev/null)" == 600 ]] && ok "Module environment mode is 0600" || warn "Module environment should use mode 0600"
  fi
  [[ -d "$MAILCOW_INSTALL_DIR/.git" ]] && ok "Mailcow Git checkout exists" || { err "Mailcow Git checkout is missing"; return; }
  [[ -f "$MANAGED_INSTALL_STATE" ]] && ok "Mailcow checkout is registered as module-managed" || err "Mailcow checkout has not been explicitly adopted by this module"
  local origin current
  origin="$(git -C "$MAILCOW_INSTALL_DIR" remote get-url origin 2>/dev/null || true)"
  [[ "$origin" == https://github.com/mailcow/mailcow-dockerized.git || "$origin" == https://github.com/mailcow/mailcow-dockerized ]] && ok "Mailcow checkout uses the official origin" || err "Mailcow checkout origin is unexpected"
  current="$(git -C "$MAILCOW_INSTALL_DIR" rev-parse HEAD 2>/dev/null || true)"
  [[ "$current" == "$MAILCOW_GIT_COMMIT" ]] && ok "Pinned Mailcow $MAILCOW_VERSION commit is installed" || warn "Installed Mailcow commit differs from the module pin (installed ${current:-unknown})"
  [[ -f "$MAILCOW_INSTALL_DIR/mailcow.conf" ]] && ok "mailcow.conf exists" || { err "mailcow.conf is missing"; return; }
  [[ "$(stat -c '%a' "$MAILCOW_INSTALL_DIR/mailcow.conf" 2>/dev/null)" == 600 ]] && ok "mailcow.conf mode is 0600" || err "mailcow.conf mode must be 0600"
  [[ -L "$MAILCOW_INSTALL_DIR/.env" && "$(readlink "$MAILCOW_INSTALL_DIR/.env")" == mailcow.conf ]] && ok ".env points to mailcow.conf" || err ".env must be a symlink to mailcow.conf"
  [[ "$(conf_value MAILCOW_HOSTNAME)" == "$MAILCOW_HOSTNAME" ]] && ok "Mailcow hostname matches the module environment" || err "Mailcow hostname does not match MAILCOW_HOSTNAME"
  [[ "$(conf_value HTTP_BIND)" == "$MAILCOW_HTTP_BIND" && "$(conf_value HTTP_PORT)" == "$MAILCOW_HTTP_PORT" ]] && ok "HTTP binds to the configured loopback endpoint" || err "HTTP binding does not match the module environment"
  [[ "$(conf_value HTTPS_BIND)" == "$MAILCOW_HTTPS_BIND" && "$(conf_value HTTPS_PORT)" == "$MAILCOW_HTTPS_PORT" ]] && ok "HTTPS binds to the configured loopback endpoint" || err "HTTPS binding does not match the module environment"
  [[ "$(conf_value HTTP_REDIRECT)" == n ]] && ok "Internal HTTP redirect is disabled behind Caddy" || err "HTTP_REDIRECT must be n behind Caddy"
  [[ "$(conf_value SKIP_LETS_ENCRYPT)" == y ]] && ok "Mailcow ACME is disabled" || err "SKIP_LETS_ENCRYPT must be y when Caddy owns certificates"
  [[ "$(conf_value ADDITIONAL_SERVER_NAMES)" == "$MAILCOW_ADDITIONAL_SERVER_NAMES" ]] && ok "Additional server names match" || err "ADDITIONAL_SERVER_NAMES does not match the module environment"
  local expected_clamd=n expected_fts=n
  [[ "$MAILCOW_SKIP_CLAMD" == true ]] && expected_clamd=y
  [[ "$MAILCOW_SKIP_FTS" == true ]] && expected_fts=y
  [[ "$(conf_value SKIP_CLAMD)" == "$expected_clamd" ]] && ok "ClamAV setting matches the module environment" || err "SKIP_CLAMD does not match MAILCOW_SKIP_CLAMD"
  [[ "$(conf_value SKIP_FTS)" == "$expected_fts" ]] && ok "Full-text search setting matches the module environment" || err "SKIP_FTS does not match MAILCOW_SKIP_FTS"
  [[ "$(conf_value ENABLE_IPV6)" == "$MAILCOW_ENABLE_IPV6" ]] && ok "Mailcow IPv6 setting matches the module environment" || err "ENABLE_IPV6 does not match MAILCOW_ENABLE_IPV6"
  [[ ! -f "$PENDING_ADMIN_RESET" ]] && ok "Initial Mailcow administrator reset is complete" || err "Initial administrator password reset is still pending; do not expose the UI"
  if [[ -f "$ADMIN_ENV" ]]; then
    [[ "$(stat -c '%a' "$ADMIN_ENV" 2>/dev/null)" == 600 ]] && ok "Initial administrator credentials mode is 0600" || err "Initial administrator credentials mode must be 0600"
    grep -Eq '^MAILCOW_ADMIN_PASSWORD=[_A-Za-z0-9-]{32}$' "$ADMIN_ENV" && ok "A generated administrator password is stored locally" || err "Generated administrator credential file is invalid"
  else
    info "Initial administrator credential file is absent; this is normal for adopted installations"
  fi
}

check_containers() {
  section "Mailcow containers"
  [[ -f "$MAILCOW_INSTALL_DIR/docker-compose.yml" && -f "$MAILCOW_INSTALL_DIR/mailcow.conf" ]] || return
  compose config >/dev/null 2>&1 && ok "Compose configuration is valid" || { err "Compose configuration is invalid"; return; }
  local service id state health
  while IFS= read -r service; do
    id="$(compose ps -q "$service" 2>/dev/null || true)"
    [[ -n "$id" ]] || { err "Container is missing: $service"; continue; }
    state="$(docker inspect --format '{{.State.Status}}' "$id" 2>/dev/null || true)"
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || true)"
    [[ "$state" == running ]] && ok "Container is running: $service" || err "Container $service state is ${state:-unknown}"
    [[ "$health" == healthy || "$health" == none ]] && ok "Container health is acceptable: $service" || err "Container $service health is ${health:-unknown}"
  done < <(compose config --services 2>/dev/null)
}

check_ports_and_http() {
  section "Ports and HTTP"
  local port code local_field
  for port in 25 110 143 465 587 993 995 4190; do
    ss -H -ltn "sport = :$port" 2>/dev/null | grep -q . && ok "Mail protocol TCP port is listening: $port" || err "Mail protocol TCP port is not listening: $port"
  done
  for port in 7654 13306 19991; do
    local_field="$(ss -H -ltn "sport = :$port" 2>/dev/null | awk 'NR==1 {print $4}')"
    [[ "$local_field" == "127.0.0.1:$port" ]] && ok "Mailcow internal TCP port is loopback-only: $port" || err "Mailcow internal port $port is missing or not loopback-only (${local_field:-none})"
  done
  local_field="$(ss -H -ltn "sport = :$MAILCOW_HTTP_PORT" 2>/dev/null | awk 'NR==1 {print $4}')"
  [[ "$local_field" == "${MAILCOW_HTTP_BIND}:${MAILCOW_HTTP_PORT}" ]] && ok "Mailcow HTTP is loopback-only" || err "Mailcow HTTP listener is missing or not loopback-only (${local_field:-none})"
  local_field="$(ss -H -ltn "sport = :$MAILCOW_HTTPS_PORT" 2>/dev/null | awk 'NR==1 {print $4}')"
  [[ "$local_field" == "${MAILCOW_HTTPS_BIND}:${MAILCOW_HTTPS_PORT}" ]] && ok "Mailcow HTTPS is loopback-only" || err "Mailcow HTTPS listener is missing or not loopback-only (${local_field:-none})"
  code="$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $MAILCOW_HOSTNAME" --connect-timeout 3 --max-time 10 "http://${MAILCOW_HTTP_BIND}:${MAILCOW_HTTP_PORT}/" 2>/dev/null || true)"
  [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]] && ok "Local Mailcow UI returned HTTP $code" || err "Local Mailcow UI is unavailable (HTTP ${code:-none})"
  if [[ "$MAILCOW_CONFIGURE_CADDY" == true ]]; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 20 "https://$MAILCOW_HOSTNAME/" 2>/dev/null || true)"
    [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]] && ok "Public Mailcow URL returned HTTP $code" || warn "Public Mailcow URL is not ready (HTTP ${code:-none}); check DNS and Caddy"
  fi
}

check_caddy_and_certificate() {
  section "Caddy and TLS certificate synchronization"
  [[ "$MAILCOW_CONFIGURE_CADDY" == true ]] || { info "Caddy integration is disabled"; return; }
  check_service caddy
  [[ -f "$CADDYFILE" ]] || { err "Caddyfile is missing"; return; }
  caddy validate --config "$CADDYFILE" >/dev/null 2>&1 && ok "Caddyfile is valid" || err "Caddyfile validation failed"
  grep -Fq "$CADDY_MANAGED_PREFIX $MAILCOW_HOSTNAME" "$CADDYFILE" && ok "Managed Mailcow Caddy block is present" || err "Managed Mailcow Caddy block is missing"
  grep -Fq "reverse_proxy ${MAILCOW_HTTP_BIND}:${MAILCOW_HTTP_PORT}" "$CADDYFILE" && ok "Caddy points to Mailcow" || err "Caddy upstream does not match Mailcow"
  [[ "$MAILCOW_SYNC_CADDY_CERT" == true ]] || { info "Caddy certificate synchronization is disabled"; return; }
  [[ -x "$CERT_SYNC_SCRIPT" ]] && ok "Certificate synchronization script is installed" || err "Certificate synchronization script is missing"
  systemctl is-enabled --quiet mailcow-sync-caddy-cert.timer 2>/dev/null && ok "Certificate synchronization timer is enabled" || err "Certificate synchronization timer is not enabled"
  systemctl is-active --quiet mailcow-sync-caddy-cert.timer 2>/dev/null && ok "Certificate synchronization timer is active" || err "Certificate synchronization timer is not active"
  local cert="$MAILCOW_INSTALL_DIR/data/assets/ssl/cert.pem" key="$MAILCOW_INSTALL_DIR/data/assets/ssl/key.pem" cert_pub key_pub issuer subject domains_file
  domains_file="$MAILCOW_INSTALL_DIR/data/assets/ssl/$MAILCOW_HOSTNAME/domains"
  [[ -f "$cert" && -f "$key" ]] || { err "Mailcow TLS certificate or key is missing"; return; }
  openssl x509 -in "$cert" -noout -checkhost "$MAILCOW_HOSTNAME" >/dev/null 2>&1 && ok "Mailcow certificate covers $MAILCOW_HOSTNAME" || err "Mailcow certificate does not cover $MAILCOW_HOSTNAME"
  openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1 && ok "Mailcow certificate remains valid for at least 24 hours" || err "Mailcow certificate is expired or expires within 24 hours"
  issuer="$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null || true)"; subject="$(openssl x509 -in "$cert" -noout -subject 2>/dev/null || true)"
  [[ -n "$issuer" && "$issuer" != *'Caddy Local Authority'* && "${issuer#issuer=}" != "${subject#subject=}" ]] && ok "Mailcow uses a publicly issued certificate" || err "Mailcow still uses a local or self-signed certificate"
  [[ -f "$domains_file" && "$(<"$domains_file")" == "$MAILCOW_HOSTNAME" ]] && ok "Mailcow hostname certificate metadata is present" || err "Mailcow hostname certificate metadata is missing or incorrect"
  cert_pub="$(mktemp)"; key_pub="$(mktemp)"
  openssl x509 -in "$cert" -pubkey -noout > "$cert_pub" 2>/dev/null
  openssl pkey -in "$key" -pubout > "$key_pub" 2>/dev/null
  cmp -s "$cert_pub" "$key_pub" && ok "Mailcow certificate and private key match" || err "Mailcow certificate and private key do not match"
  rm -f "$cert_pub" "$key_pub"
}

check_dns() {
  section "DNS"
  local addresses headers domain mx spf dmarc
  local -a domains=()
  addresses="$(dig +short A "$MAILCOW_HOSTNAME" 2>/dev/null; dig +short AAAA "$MAILCOW_HOSTNAME" 2>/dev/null)"
  [[ -n "$addresses" ]] && ok "$MAILCOW_HOSTNAME resolves in public DNS" || err "$MAILCOW_HOSTNAME has no public A or AAAA record"
  headers="$(curl -sS -I --connect-timeout 5 --max-time 15 "https://$MAILCOW_HOSTNAME/" 2>/dev/null || true)"
  if [[ -z "$headers" ]]; then warn "Could not inspect public HTTP headers for the Cloudflare proxy"
  elif grep -Fqi '^server: cloudflare' <<< "$headers"; then err "$MAILCOW_HOSTNAME appears Cloudflare Proxied; mail hostnames must be DNS-only"
  else ok "No Cloudflare HTTP proxy header was detected for the mail hostname"; fi
  [[ -n "$MAILCOW_MAIL_DOMAINS" ]] || { info "MAILCOW_MAIL_DOMAINS is empty; skipping domain DNS checks"; return; }
  IFS=',' read -r -a domains <<< "$MAILCOW_MAIL_DOMAINS"
  for domain in "${domains[@]}"; do
    mx="$(dig +short MX "$domain" 2>/dev/null | awk '{print $2}' | sed 's/\.$//' | tr '[:upper:]' '[:lower:]')"
    grep -Fxq "${MAILCOW_HOSTNAME,,}" <<< "$mx" && ok "$domain MX points to $MAILCOW_HOSTNAME" || err "$domain MX does not point to $MAILCOW_HOSTNAME"
    spf="$(dig +short TXT "$domain" 2>/dev/null | tr -d '"' | grep -i '^v=spf1' || true)"
    [[ -n "$spf" ]] && ok "$domain publishes SPF" || warn "$domain does not publish SPF"
    dmarc="$(dig +short TXT "_dmarc.$domain" 2>/dev/null | tr -d '"' | grep -i '^v=DMARC1' || true)"
    [[ -n "$dmarc" ]] && ok "$domain publishes DMARC" || warn "$domain does not publish DMARC"
  done
  info "Verify PTR/rDNS and the DKIM record shown in the Mailcow UI at the hosting provider"
}

check_firewall() {
  section "Firewall"
  if command -v ufw >/dev/null 2>&1; then
    ufw status 2>/dev/null | sed -n '1,20p' || true
    warn "Docker-published Mailcow ports can bypass ordinary UFW INPUT rules; enforce restrictions in the provider firewall or DOCKER-USER chain"
  else
    info "UFW is not installed"
  fi
  info "Required inbound TCP ports: 25, 80, 110, 143, 443, 465, 587, 993, 995, 4190"
}

main() {
  require_root
  load_env
  check_system
  check_files
  check_containers
  check_ports_and_http
  check_caddy_and_certificate
  check_dns
  check_firewall
  summary
  (( ERRORS == 0 ))
}

main "$@"
