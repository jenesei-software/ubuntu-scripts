#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_INPUT="${1:-}"
timestamp() { date '+%F %T'; }
log_line() { local level="$1"; shift; printf '[%s] %-7s %s\n' "$(timestamp)" "$level" "$*"; }
log() { log_line INFO "$*"; }; warn() { log_line WARN "$*"; }; fail() { log_line ERROR "$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: cd ~/ubuntu-scripts/authentik && bash setup-youtrack-oidc.sh"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"; }
cleanup() { [[ -z "${API_HEADER_FILE:-}" ]] || rm -f "$API_HEADER_FILE"; }
trap cleanup EXIT
resolve_env_path() { local value="$1"; if [[ "$value" = /* ]]; then printf '%s\n' "$value"; elif [[ -f "$value" ]]; then printf '%s/%s\n' "$(cd -- "$(dirname -- "$value")" && pwd)" "$(basename -- "$value")"; else printf '%s/%s\n' "$SCRIPT_DIR" "$value"; fi; }

load_env() {
  if [[ -n "$ENV_FILE_INPUT" ]]; then ENV_FILE="$(resolve_env_path "$ENV_FILE_INPUT")"; else ENV_FILE="$SCRIPT_DIR/.env"; fi
  [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
  AUTHENTIK_URL=""; AUTHENTIK_INSTALL_DIR=""; YOUTRACK_URL=""; AUTHENTIK_YOUTRACK_APP_NAME=""; AUTHENTIK_YOUTRACK_APP_SLUG=""; AUTHENTIK_YOUTRACK_CLIENT_ID=""; YOUTRACK_OIDC_REDIRECT_URI=""
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  AUTHENTIK_INSTALL_DIR="${AUTHENTIK_INSTALL_DIR:-/opt/authentik}"
  AUTHENTIK_YOUTRACK_APP_NAME="${AUTHENTIK_YOUTRACK_APP_NAME:-YouTrack}"
  AUTHENTIK_YOUTRACK_APP_SLUG="${AUTHENTIK_YOUTRACK_APP_SLUG:-youtrack}"
  AUTHENTIK_YOUTRACK_CLIENT_ID="${AUTHENTIK_YOUTRACK_CLIENT_ID:-youtrack}"
  YOUTRACK_OIDC_REDIRECT_URI="${YOUTRACK_OIDC_REDIRECT_URI:-${YOUTRACK_URL%/}/hub/api/rest/oauth2/auth}"
  RUNTIME_ENV="$AUTHENTIK_INSTALL_DIR/.env"
  INTEGRATION_DIR="$AUTHENTIK_INSTALL_DIR/integrations"
  INTEGRATION_ENV="$INTEGRATION_DIR/youtrack-oidc.env"
}

validate_env() {
  [[ "$AUTHENTIK_URL" =~ ^https://[A-Za-z0-9.-]+/?$ ]] || fail "AUTHENTIK_URL must be an HTTPS site URL"
  [[ "$YOUTRACK_URL" =~ ^https://[A-Za-z0-9.-]+/?$ ]] || fail "YOUTRACK_URL must be an HTTPS site URL"
  [[ "$AUTHENTIK_URL" != "$YOUTRACK_URL" ]] || fail "Authentik and YouTrack must use different hostnames"
  [[ "$AUTHENTIK_YOUTRACK_APP_SLUG" =~ ^[-A-Za-z0-9_]+$ ]] || fail "AUTHENTIK_YOUTRACK_APP_SLUG is invalid"
  [[ "$AUTHENTIK_YOUTRACK_CLIENT_ID" =~ ^[-A-Za-z0-9_.]+$ ]] || fail "AUTHENTIK_YOUTRACK_CLIENT_ID is invalid"
  [[ "$YOUTRACK_OIDC_REDIRECT_URI" == "${YOUTRACK_URL%/}/"* ]] || fail "YOUTRACK_OIDC_REDIRECT_URI must belong to YOUTRACK_URL"
  [[ -f "$RUNTIME_ENV" ]] || fail "Authentik runtime environment is missing. Run setup-authentik.sh first."
}

runtime_value() { sed -n "s/^$1=//p" "$RUNTIME_ENV" | tail -n 1; }
integration_value() { [[ -f "$INTEGRATION_ENV" ]] || return 0; sed -n "s/^$1=//p" "$INTEGRATION_ENV" | tail -n 1; }

prepare_tools_and_secrets() {
  local -a packages=()
  command -v curl >/dev/null 2>&1 || packages+=(curl)
  command -v jq >/dev/null 2>&1 || packages+=(jq)
  command -v openssl >/dev/null 2>&1 || packages+=(openssl)
  if (( ${#packages[@]} )); then apt-get update; apt-get install -y "${packages[@]}"; fi
  API_TOKEN="$(runtime_value AUTHENTIK_BOOTSTRAP_TOKEN)"
  [[ -n "$API_TOKEN" ]] || fail "AUTHENTIK_BOOTSTRAP_TOKEN is missing from $RUNTIME_ENV"
  API_HEADER_FILE="$(mktemp)"; chmod 0600 "$API_HEADER_FILE"
  printf 'Authorization: Bearer %s\n' "$API_TOKEN" > "$API_HEADER_FILE"
  CLIENT_SECRET="$(integration_value YOUTRACK_OIDC_CLIENT_SECRET)"
  [[ -n "$CLIENT_SECRET" ]] || CLIENT_SECRET="$(openssl rand -hex 32)"
}

api_get() { curl --proto '=https' --tlsv1.2 --fail --silent --show-error --connect-timeout 10 --max-time 30 -H "@$API_HEADER_FILE" -H 'Accept: application/json' "${AUTHENTIK_URL%/}/api/v3$1"; }
api_write() {
  local method="$1" path="$2" payload="$3"
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --connect-timeout 10 --max-time 30 -X "$method" -H "@$API_HEADER_FILE" -H 'Accept: application/json' -H 'Content-Type: application/json' --data-binary @- "${AUTHENTIK_URL%/}/api/v3$path" <<< "$payload"
}

object_pk() { jq -er '.pk // .flow_uuid' <<< "$1"; }
configure_authentik() {
  local authorization_flow invalidation_flow mappings_response mappings signing_key provider_list provider_id provider_payload provider_response app_list app_payload
  log "Reading Authentik defaults"
  authorization_flow="$(object_pk "$(api_get '/flows/instances/default-provider-authorization-implicit-consent/')")"
  invalidation_flow="$(object_pk "$(api_get '/flows/instances/default-provider-invalidation-flow/')")"
  mappings_response="$(api_get '/propertymappings/provider/scope/?page_size=100')"
  mappings="$(jq -c '[.results[] | select(.scope_name == "openid" or .scope_name == "email" or .scope_name == "profile") | .pk] | unique' <<< "$mappings_response")"
  [[ "$(jq 'length' <<< "$mappings")" -ge 3 ]] || fail "Could not find Authentik's built-in openid, email, and profile scope mappings"
  signing_key="$(api_get '/crypto/certificatekeypairs/?has_key=true&page_size=100' | jq -er '[.results[] | select(.name == "authentik Self-signed Certificate")][0].pk // .results[0].pk')" || fail "No signing certificate with a private key is available in Authentik"

  provider_payload="$(jq -cn \
    --arg name "$AUTHENTIK_YOUTRACK_APP_NAME" --arg auth "$authorization_flow" --arg invalid "$invalidation_flow" \
    --arg client_id "$AUTHENTIK_YOUTRACK_CLIENT_ID" --arg client_secret "$CLIENT_SECRET" --arg redirect "$YOUTRACK_OIDC_REDIRECT_URI" \
    --arg signing_key "$signing_key" --argjson mappings "$mappings" \
    '{name:$name,authorization_flow:$auth,invalidation_flow:$invalid,property_mappings:$mappings,client_type:"confidential",grant_types:["authorization_code","refresh_token"],client_id:$client_id,client_secret:$client_secret,include_claims_in_id_token:true,signing_key:$signing_key,redirect_uris:[{matching_mode:"strict",url:$redirect}],sub_mode:"hashed_user_id",issuer_mode:"per_provider"}')"

  provider_list="$(api_get "/providers/oauth2/?client_id=${AUTHENTIK_YOUTRACK_CLIENT_ID}&page_size=20")"
  provider_id="$(jq -r --arg id "$AUTHENTIK_YOUTRACK_CLIENT_ID" '[.results[] | select(.client_id == $id)][0].pk // empty' <<< "$provider_list")"
  if [[ -n "$provider_id" ]]; then
    log "Updating existing Authentik OAuth2 provider (id $provider_id)"
    provider_response="$(api_write PATCH "/providers/oauth2/${provider_id}/" "$provider_payload")"
  else
    log "Creating Authentik OAuth2 provider"
    provider_response="$(api_write POST '/providers/oauth2/' "$provider_payload")"
    provider_id="$(jq -er '.pk' <<< "$provider_response")"
  fi

  app_payload="$(jq -cn --arg name "$AUTHENTIK_YOUTRACK_APP_NAME" --arg slug "$AUTHENTIK_YOUTRACK_APP_SLUG" --argjson provider "$provider_id" --arg launch "${YOUTRACK_URL%/}" '{name:$name,slug:$slug,provider:$provider,meta_launch_url:$launch,open_in_new_tab:true,policy_engine_mode:"any"}')"
  app_list="$(api_get "/core/applications/?slug=${AUTHENTIK_YOUTRACK_APP_SLUG}&page_size=20")"
  if jq -e --arg slug "$AUTHENTIK_YOUTRACK_APP_SLUG" '.results[] | select(.slug == $slug)' <<< "$app_list" >/dev/null; then
    log "Updating existing Authentik application"
    api_write PATCH "/core/applications/${AUTHENTIK_YOUTRACK_APP_SLUG}/" "$app_payload" >/dev/null
  else
    log "Creating Authentik application"
    api_write POST '/core/applications/' "$app_payload" >/dev/null
  fi
}

write_integration_file() {
  local tmp discovery issuer
  discovery="${AUTHENTIK_URL%/}/application/o/${AUTHENTIK_YOUTRACK_APP_SLUG}/.well-known/openid-configuration"
  issuer="${AUTHENTIK_URL%/}/application/o/${AUTHENTIK_YOUTRACK_APP_SLUG}/"
  install -d -m 0700 "$INTEGRATION_DIR"; tmp="$(mktemp)"
  cat > "$tmp" <<EOF
YOUTRACK_OIDC_DISCOVERY_URL=$discovery
YOUTRACK_OIDC_ISSUER=$issuer
YOUTRACK_OIDC_CLIENT_ID=$AUTHENTIK_YOUTRACK_CLIENT_ID
YOUTRACK_OIDC_CLIENT_SECRET=$CLIENT_SECRET
YOUTRACK_OIDC_REDIRECT_URI=$YOUTRACK_OIDC_REDIRECT_URI
EOF
  if [[ -f "$INTEGRATION_ENV" ]] && ! cmp -s "$tmp" "$INTEGRATION_ENV"; then cp -a "$INTEGRATION_ENV" "${INTEGRATION_ENV}.bak.$(date +%s)"; fi
  install -m 0600 "$tmp" "$INTEGRATION_ENV"; rm -f "$tmp"
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --connect-timeout 10 --max-time 30 "$discovery" | jq -e --arg issuer "$issuer" '.issuer == $issuer and (.authorization_endpoint | length > 0) and (.token_endpoint | length > 0) and (.jwks_uri | length > 0)' >/dev/null || fail "OIDC discovery document is invalid"
}

main() {
  require_root; require_cmd apt-get; load_env; validate_env; prepare_tools_and_secrets
  api_get '/core/users/me/' >/dev/null || fail "Authentik API token is not accepted"
  configure_authentik; write_integration_file
  log "Authentik application and OAuth2 provider for YouTrack are ready"
  log "YouTrack OIDC values, including the client secret, are stored in $INTEGRATION_ENV (mode 0600)"
  warn "YouTrack is not changed automatically. Add and test an OpenID Connect auth module in Administration -> Access Management -> Auth Modules."
  warn "Keep password login and an existing administrator session until OIDC login has been tested. Do not make Authentik the default module yet."
  log "Show the values locally: sudo sed -n '1,5p' $INTEGRATION_ENV"
}
main "$@"
