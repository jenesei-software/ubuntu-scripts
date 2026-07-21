#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
API_HEADER_FILE=""
CLIENT_SECRET_FILE=""
CUSTOM_MAPPING_ID=""

timestamp() { date '+%F %T'; }
log_line() { local level="$1"; shift; printf '[%s] %-7s %s\n' "$(timestamp)" "$level" "$*"; }
log() { log_line INFO "$*"; }
warn() { log_line WARN "$*"; }
fail() { log_line ERROR "$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/authentik && bash setup-mailcow-oidc.sh"; }
cleanup() {
  [[ -z "$API_HEADER_FILE" ]] || rm -f "$API_HEADER_FILE"
  [[ -z "$CLIENT_SECRET_FILE" ]] || rm -f "$CLIENT_SECRET_FILE"
}
trap cleanup EXIT

resolve_env_path() {
  local value="$1"
  if [[ "$value" = /* ]]; then printf '%s\n' "$value"
  elif [[ -f "$value" ]]; then printf '%s/%s\n' "$(cd -- "$(dirname -- "$value")" && pwd)" "$(basename -- "$value")"
  elif [[ -f "$SCRIPT_DIR/$value" ]]; then printf '%s/%s\n' "$SCRIPT_DIR" "$value"
  else printf '%s/%s\n' "$SCRIPT_DIR" "$value"; fi
}

load_env() {
  if [[ -n "$ENV_FILE_INPUT" ]]; then ENV_FILE="$(resolve_env_path "$ENV_FILE_INPUT")"; else ENV_FILE="$SCRIPT_DIR/.env"; fi
  [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
  AUTHENTIK_URL=""; AUTHENTIK_INSTALL_DIR=""; MAILCOW_URL=""; AUTHENTIK_MAILCOW_APP_NAME=""
  AUTHENTIK_MAILCOW_APP_SLUG=""; AUTHENTIK_MAILCOW_CLIENT_ID=""; AUTHENTIK_MAILCOW_TEMPLATE_ATTRIBUTE=""
  MAILCOW_OIDC_REDIRECT_URI=""; AUTHENTIK_ADMIN_PASSWORD=""
  set -a
  # shellcheck disable=SC1090
  trap - EXIT
  source "$ENV_FILE"
  API_HEADER_FILE=""; CLIENT_SECRET_FILE=""
  trap cleanup EXIT
  set +a
  unset AUTHENTIK_ADMIN_PASSWORD
  AUTHENTIK_INSTALL_DIR="${AUTHENTIK_INSTALL_DIR:-/opt/authentik}"
  AUTHENTIK_MAILCOW_APP_NAME="${AUTHENTIK_MAILCOW_APP_NAME:-Mailcow}"
  AUTHENTIK_MAILCOW_APP_SLUG="${AUTHENTIK_MAILCOW_APP_SLUG:-mailcow}"
  AUTHENTIK_MAILCOW_CLIENT_ID="${AUTHENTIK_MAILCOW_CLIENT_ID:-mailcow}"
  AUTHENTIK_MAILCOW_TEMPLATE_ATTRIBUTE="${AUTHENTIK_MAILCOW_TEMPLATE_ATTRIBUTE:-default}"
  MAILCOW_OIDC_REDIRECT_URI="${MAILCOW_OIDC_REDIRECT_URI:-${MAILCOW_URL%/}}"
  RUNTIME_ENV="$AUTHENTIK_INSTALL_DIR/.env"
  INTEGRATION_DIR="$AUTHENTIK_INSTALL_DIR/integrations"
  INTEGRATION_ENV="$INTEGRATION_DIR/mailcow-oidc.env"
}

validate_env() {
  local url host label
  local -a labels=()
  for url in "$AUTHENTIK_URL" "$MAILCOW_URL"; do
    [[ "$url" =~ ^https://[A-Za-z0-9.-]+/?$ ]] || fail "AUTHENTIK_URL and MAILCOW_URL must be HTTPS site URLs without paths or ports"
    host="${url#https://}"; host="${host%/}"
    [[ ${#host} -le 253 && "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || fail "Invalid FQDN in URL: $url"
    [[ "$host" == "${host,,}" ]] || fail "Use lowercase DNS names in URLs: $url"
    IFS='.' read -r -a labels <<< "$host"
    for label in "${labels[@]}"; do (( ${#label} <= 63 )) || fail "URL contains a DNS label longer than 63 characters: $url"; done
    [[ "$host" != example.com && "$host" != *.example.com ]] || fail "Replace the example.com placeholder before running setup"
  done
  [[ "${AUTHENTIK_URL%/}" != "${MAILCOW_URL%/}" ]] || fail "Authentik and Mailcow must use different hostnames"
  [[ "$AUTHENTIK_INSTALL_DIR" = /* && "$AUTHENTIK_INSTALL_DIR" != / && "/$AUTHENTIK_INSTALL_DIR/" != */../* && "/$AUTHENTIK_INSTALL_DIR/" != */./* ]] || fail "AUTHENTIK_INSTALL_DIR must be a dedicated absolute path without . or .. segments"
  [[ "$AUTHENTIK_INSTALL_DIR" != *$'\n'* && "$AUTHENTIK_INSTALL_DIR" != *$'\r'* ]] || fail "AUTHENTIK_INSTALL_DIR contains an invalid newline"
  [[ "$AUTHENTIK_MAILCOW_APP_NAME" != *$'\n'* && "$AUTHENTIK_MAILCOW_APP_NAME" != *$'\r'* && -n "$AUTHENTIK_MAILCOW_APP_NAME" ]] || fail "AUTHENTIK_MAILCOW_APP_NAME is invalid"
  [[ "$AUTHENTIK_MAILCOW_APP_SLUG" =~ ^[-A-Za-z0-9_]+$ ]] || fail "AUTHENTIK_MAILCOW_APP_SLUG is invalid"
  [[ "$AUTHENTIK_MAILCOW_CLIENT_ID" =~ ^[-A-Za-z0-9_.]+$ ]] || fail "AUTHENTIK_MAILCOW_CLIENT_ID is invalid"
  [[ "$AUTHENTIK_MAILCOW_TEMPLATE_ATTRIBUTE" =~ ^[-A-Za-z0-9_.]+$ ]] || fail "AUTHENTIK_MAILCOW_TEMPLATE_ATTRIBUTE is invalid"
  [[ "$MAILCOW_OIDC_REDIRECT_URI" == "${MAILCOW_URL%/}" ]] || fail "MAILCOW_OIDC_REDIRECT_URI must exactly equal MAILCOW_URL without a trailing slash"
  [[ -f "$RUNTIME_ENV" ]] || fail "Authentik runtime environment is missing. Run setup-authentik.sh first."
  [[ "$(stat -c '%a' "$ENV_FILE" 2>/dev/null)" == 600 ]] || fail "Authentik module environment must have mode 0600: chmod 600 $ENV_FILE"
  [[ "$(stat -c '%a' "$RUNTIME_ENV" 2>/dev/null)" == 600 ]] || fail "Authentik runtime environment must have mode 0600: chmod 600 $RUNTIME_ENV"
  if [[ -f "$INTEGRATION_ENV" ]]; then
    [[ "$(stat -c '%a' "$INTEGRATION_ENV" 2>/dev/null)" == 600 ]] || fail "Existing Mailcow OIDC settings must have mode 0600: chmod 600 $INTEGRATION_ENV"
  fi
}

runtime_value() { sed -n "s/^$1=//p" "$RUNTIME_ENV" | tail -n 1; }
integration_value() { [[ -f "$INTEGRATION_ENV" ]] || return 0; sed -n "s/^$1=//p" "$INTEGRATION_ENV" | tail -n 1; }

prepare_tools_and_secrets() {
  local -a packages=()
  unset API_TOKEN CLIENT_SECRET
  API_TOKEN="$(runtime_value AUTHENTIK_BOOTSTRAP_TOKEN)"
  [[ -n "$API_TOKEN" && "$API_TOKEN" != change_me* ]] || fail "AUTHENTIK_BOOTSTRAP_TOKEN is missing or still a placeholder in $RUNTIME_ENV"
  CLIENT_SECRET="$(integration_value MAILCOW_OIDC_CLIENT_SECRET)"
  [[ -z "$CLIENT_SECRET" || "$CLIENT_SECRET" =~ ^[0-9a-f]{64}$ ]] || fail "Stored Mailcow OIDC client secret has an unexpected format"
  command -v curl >/dev/null 2>&1 || packages+=(curl)
  command -v jq >/dev/null 2>&1 || packages+=(jq)
  command -v openssl >/dev/null 2>&1 || packages+=(openssl)
  if (( ${#packages[@]} )); then apt-get update; apt-get install -y "${packages[@]}"; fi
  API_HEADER_FILE="$(mktemp)"; chmod 0600 "$API_HEADER_FILE"
  printf 'Authorization: Bearer %s\n' "$API_TOKEN" > "$API_HEADER_FILE"
  [[ -n "$CLIENT_SECRET" ]] || CLIENT_SECRET="$(openssl rand -hex 32)"
  CLIENT_SECRET_FILE="$(mktemp)"; chmod 0600 "$CLIENT_SECRET_FILE"
  printf '%s' "$CLIENT_SECRET" > "$CLIENT_SECRET_FILE"
}

api_get() {
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --connect-timeout 10 --max-time 30 \
    -H "@$API_HEADER_FILE" -H 'Accept: application/json' "${AUTHENTIK_URL%/}/api/v3$1"
}

api_write() {
  local method="$1" path="$2" payload="$3"
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --connect-timeout 10 --max-time 30 \
    -X "$method" -H "@$API_HEADER_FILE" -H 'Accept: application/json' -H 'Content-Type: application/json' \
    --data-binary @- "${AUTHENTIK_URL%/}/api/v3$path" <<< "$payload"
}

object_pk() { jq -er '.pk // .flow_uuid' <<< "$1"; }

configure_scope_mapping() {
  local mapping_name mapping_expression mapping_list mapping_id mapping_payload mapping_response conflicting_scope
  mapping_name="$AUTHENTIK_MAILCOW_APP_NAME mailbox template"
  mapping_expression="return {\"mailcow_template\": \"$AUTHENTIK_MAILCOW_TEMPLATE_ATTRIBUTE\"}"
  mapping_list="$(api_get '/propertymappings/provider/scope/?page_size=100')"
  mapping_id="$(jq -r --arg name "$mapping_name" '[.results[] | select(.name == $name and .scope_name == "mailcow_template")][0].pk // empty' <<< "$mapping_list")"
  conflicting_scope="$(jq -r --arg name "$mapping_name" '[.results[] | select(.name == $name and .scope_name != "mailcow_template")][0].scope_name // empty' <<< "$mapping_list")"
  [[ -z "$conflicting_scope" ]] || fail "Authentik already has a property mapping named '$mapping_name' with scope '$conflicting_scope'"
  mapping_payload="$(jq -cn --arg name "$mapping_name" --arg expression "$mapping_expression" \
    '{name:$name,scope_name:"mailcow_template",description:"Mailbox template attribute for Mailcow Generic-OIDC provisioning",expression:$expression}')"
  if [[ -n "$mapping_id" ]]; then
    log "Updating the Mailcow scope mapping"
    mapping_response="$(api_write PATCH "/propertymappings/provider/scope/${mapping_id}/" "$mapping_payload")"
  else
    log "Creating the Mailcow scope mapping"
    mapping_response="$(api_write POST '/propertymappings/provider/scope/' "$mapping_payload")"
    mapping_id="$(jq -er '.pk' <<< "$mapping_response")"
  fi
  CUSTOM_MAPPING_ID="$mapping_id"
}

configure_authentik() {
  local authorization_flow invalidation_flow mappings_response mappings custom_mapping signing_key
  local provider_list provider_id provider_payload provider_response app_list app_payload
  log "Reading Authentik defaults"
  authorization_flow="$(object_pk "$(api_get '/flows/instances/default-provider-authorization-implicit-consent/')")"
  invalidation_flow="$(object_pk "$(api_get '/flows/instances/default-provider-invalidation-flow/')")"
  configure_scope_mapping
  custom_mapping="$CUSTOM_MAPPING_ID"
  [[ -n "$custom_mapping" ]] || fail "Mailcow scope mapping was not created"
  mappings_response="$(api_get '/propertymappings/provider/scope/?page_size=100')"
  mappings="$(jq -c --arg custom "$custom_mapping" \
    '["openid","email","profile"] as $required | [$required[] as $scope | ([.results[] | select(.scope_name == $scope)][0].pk)] + [$custom] | unique' <<< "$mappings_response")"
  jq -e 'length == 4 and all(.[]; type == "string" and length > 0)' <<< "$mappings" >/dev/null \
    || fail "Could not assemble openid, email, profile, and mailcow_template scope mappings"
  signing_key="$(api_get '/crypto/certificatekeypairs/?has_key=true&page_size=100' | jq -er '[.results[] | select(.name == "authentik Self-signed Certificate")][0].pk // .results[0].pk')" || fail "No signing certificate with a private key is available in Authentik"

  provider_payload="$(jq -cn \
    --arg name "$AUTHENTIK_MAILCOW_APP_NAME" --arg auth "$authorization_flow" --arg invalid "$invalidation_flow" \
    --arg client_id "$AUTHENTIK_MAILCOW_CLIENT_ID" --rawfile client_secret "$CLIENT_SECRET_FILE" --arg redirect "$MAILCOW_OIDC_REDIRECT_URI" \
    --arg signing_key "$signing_key" --argjson mappings "$mappings" \
    '{name:$name,authorization_flow:$auth,invalidation_flow:$invalid,property_mappings:$mappings,client_type:"confidential",grant_types:["authorization_code","refresh_token"],client_id:$client_id,client_secret:$client_secret,include_claims_in_id_token:true,signing_key:$signing_key,redirect_uris:[{matching_mode:"strict",url:$redirect}],sub_mode:"hashed_user_id",issuer_mode:"per_provider"}')"

  provider_list="$(api_get "/providers/oauth2/?client_id=${AUTHENTIK_MAILCOW_CLIENT_ID}&page_size=20")"
  provider_id="$(jq -r --arg id "$AUTHENTIK_MAILCOW_CLIENT_ID" '[.results[] | select(.client_id == $id)][0].pk // empty' <<< "$provider_list")"
  if [[ -n "$provider_id" ]]; then
    log "Updating existing Authentik OAuth2 provider (id $provider_id)"
    provider_response="$(api_write PATCH "/providers/oauth2/${provider_id}/" "$provider_payload")"
  else
    log "Creating Authentik OAuth2 provider"
    provider_response="$(api_write POST '/providers/oauth2/' "$provider_payload")"
    provider_id="$(jq -er '.pk' <<< "$provider_response")"
  fi
  [[ -n "$provider_id" ]] || fail "Authentik OAuth2 provider was not created"

  app_payload="$(jq -cn --arg name "$AUTHENTIK_MAILCOW_APP_NAME" --arg slug "$AUTHENTIK_MAILCOW_APP_SLUG" \
    --argjson provider "$provider_id" --arg launch "${MAILCOW_URL%/}" \
    '{name:$name,slug:$slug,provider:$provider,meta_launch_url:$launch,open_in_new_tab:true,policy_engine_mode:"any"}')"
  app_list="$(api_get "/core/applications/?slug=${AUTHENTIK_MAILCOW_APP_SLUG}&page_size=20")"
  if jq -e --arg slug "$AUTHENTIK_MAILCOW_APP_SLUG" '.results[] | select(.slug == $slug)' <<< "$app_list" >/dev/null; then
    log "Updating existing Authentik application"
    api_write PATCH "/core/applications/${AUTHENTIK_MAILCOW_APP_SLUG}/" "$app_payload" >/dev/null
  else
    log "Creating Authentik application"
    api_write POST '/core/applications/' "$app_payload" >/dev/null
  fi
}

write_integration_file() {
  local tmp issuer discovery authorize token userinfo
  issuer="${AUTHENTIK_URL%/}/application/o/${AUTHENTIK_MAILCOW_APP_SLUG}/"
  discovery="${issuer}.well-known/openid-configuration"
  authorize="${AUTHENTIK_URL%/}/application/o/authorize/"
  token="${AUTHENTIK_URL%/}/application/o/token/"
  userinfo="${AUTHENTIK_URL%/}/application/o/userinfo/"
  install -d -m 0700 "$INTEGRATION_DIR"
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
MAILCOW_OIDC_AUTHORIZE_URL=$authorize
MAILCOW_OIDC_TOKEN_URL=$token
MAILCOW_OIDC_USERINFO_URL=$userinfo
MAILCOW_OIDC_CLIENT_ID=$AUTHENTIK_MAILCOW_CLIENT_ID
MAILCOW_OIDC_CLIENT_SECRET=$CLIENT_SECRET
MAILCOW_OIDC_REDIRECT_URI=$MAILCOW_OIDC_REDIRECT_URI
MAILCOW_OIDC_SCOPES='openid profile email mailcow_template'
MAILCOW_OIDC_TEMPLATE_ATTRIBUTE=$AUTHENTIK_MAILCOW_TEMPLATE_ATTRIBUTE
MAILCOW_OIDC_ISSUER=$issuer
EOF
  if [[ -f "$INTEGRATION_ENV" ]] && ! cmp -s "$tmp" "$INTEGRATION_ENV"; then cp -a "$INTEGRATION_ENV" "$INTEGRATION_ENV.bak.$(date +%Y%m%d%H%M%S)"; fi
  install -m 0600 "$tmp" "$INTEGRATION_ENV"; rm -f "$tmp"
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --connect-timeout 10 --max-time 30 "$discovery" \
    | jq -e --arg issuer "$issuer" '.issuer == $issuer and (.authorization_endpoint | length > 0) and (.token_endpoint | length > 0) and (.userinfo_endpoint | length > 0)' >/dev/null \
    || fail "Mailcow OIDC discovery document is invalid"
}

main() {
  require_root
  load_env
  validate_env
  prepare_tools_and_secrets
  api_get '/core/users/me/' >/dev/null || fail "Authentik API token is not accepted"
  configure_authentik
  write_integration_file
  log "Authentik application and OAuth2 provider for Mailcow are ready"
  log "Mailcow OIDC settings, including the client secret, are stored in $INTEGRATION_ENV (mode 0600)"
  warn "Mailcow is not changed automatically. Configure Generic-OIDC in System -> Configuration -> Access -> Identity Provider."
  warn "Do not enable forced SSO until a full login succeeds and the local Mailcow administrator remains available."
  log "Show the values locally: sudo sed -n '1,8p' $INTEGRATION_ENV"
}

main "$@"
