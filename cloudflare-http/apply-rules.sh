#!/usr/bin/env bash
#
# Restrict Docker-published HTTP/HTTPS ports to Cloudflare's network.
#
# Docker publishes container ports with rules of its own, and those rules are evaluated before UFW,
# so an ordinary firewall rule cannot filter them. The DOCKER-USER chain is consulted first and is
# never rewritten by Docker, which makes it the supported place for rules like this one.
#
# Every rule this script owns lives in one chain: the script rebuilds that chain from scratch on each
# run and only adds or removes its own jump rule in DOCKER-USER. It never touches anybody else's
# rules, containers or networks.
#
# The Cloudflare ranges are fetched from cloudflare.com on every run and cached under
# /var/lib/cf-only-http. If the network is down, the cached copy is reused; if there is no cache
# either, the script fails without changing anything.
#
# Usage: cf-only-http.sh <wan-interface> [ports] [chain] [extra-cidrs]
#   wan-interface  interface that faces the internet, for example eth0
#   ports          comma-separated TCP ports to restrict, default 80,443
#   chain          name of the chain this script owns, default CF_ONLY_HTTP
#   extra-cidrs    comma-separated CIDRs allowed on top of Cloudflare, default empty

set -Eeuo pipefail

IFACE="${1:?usage: cf-only-http.sh <wan-interface> [ports] [chain] [extra-cidrs]}"
PORTS="${2:-80,443}"
CHAIN="${3:-CF_ONLY_HTTP}"
EXTRA_CIDRS="${4:-}"
STATE_DIR="/var/lib/cf-only-http"
LIST_V4="$STATE_DIR/ips-v4"
LIST_V6="$STATE_DIR/ips-v6"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "command not found: $1"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ "$IFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "unexpected interface name: $IFACE"
[[ "$PORTS" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "unexpected port list: $PORTS"
[[ "$CHAIN" =~ ^[A-Za-z0-9_]{1,28}$ ]] || die "unexpected chain name: $CHAIN"

require_cmd iptables
require_cmd curl
require_cmd ip
ip link show "$IFACE" >/dev/null 2>&1 || die "interface does not exist: $IFACE"
iptables -nL DOCKER-USER >/dev/null 2>&1 || die "the DOCKER-USER chain is missing; is Docker running?"

fetch() {
  local url="$1"
  local out="$2"

  if curl -fsS --max-time 20 --retry 2 --retry-delay 2 "$url" -o "$out.tmp"; then
    mv "$out.tmp" "$out"
    return
  fi

  rm -f "$out.tmp"
  [[ -s "$out" ]] || die "cannot fetch $url and no cached copy is available"
  log "WARN: cannot refresh $out; keeping the cached copy"
}

fill_chain() {
  local tool="$1"
  local list="$2"
  local net
  local -a extra=()

  "$tool" -N "$CHAIN" 2>/dev/null || true
  "$tool" -F "$CHAIN"

  while read -r net; do
    [[ -n "$net" ]] || continue
    "$tool" -A "$CHAIN" -s "$net" -j RETURN
  done < "$list"

  if [[ -n "$EXTRA_CIDRS" ]]; then
    IFS=',' read -r -a extra <<< "$EXTRA_CIDRS"
    for net in "${extra[@]}"; do
      [[ -n "$net" ]] || continue
      "$tool" -A "$CHAIN" -s "$net" -j RETURN
    done
  fi

  "$tool" -A "$CHAIN" -j DROP
}

hook_chain() {
  local tool="$1"

  "$tool" -C DOCKER-USER -i "$IFACE" -p tcp -m multiport --dports "$PORTS" -j "$CHAIN" 2>/dev/null \
    || "$tool" -I DOCKER-USER 1 -i "$IFACE" -p tcp -m multiport --dports "$PORTS" -j "$CHAIN"
}

install -d -m 0755 "$STATE_DIR"
fetch https://www.cloudflare.com/ips-v4 "$LIST_V4"
fetch https://www.cloudflare.com/ips-v6 "$LIST_V6"

# The chain is only reached through the jump rule below, so rebuilding it never interrupts traffic.
fill_chain iptables "$LIST_V4"
hook_chain iptables

if command -v ip6tables >/dev/null 2>&1 && ip6tables -nL DOCKER-USER >/dev/null 2>&1; then
  fill_chain ip6tables "$LIST_V6"
  hook_chain ip6tables
else
  log "WARN: ip6tables or its DOCKER-USER chain is unavailable; IPv6 is not restricted"
fi

log "OK: $PORTS on $IFACE accept Cloudflare only ($(grep -c . "$LIST_V4") IPv4, $(grep -c . "$LIST_V6") IPv6 ranges)"
