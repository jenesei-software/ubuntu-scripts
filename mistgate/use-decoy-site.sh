#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DECOY_SITES_DIR="$SCRIPT_DIR/decoy-sites"
DEFAULT_DECOY_DIR="/srv/mistgate-decoy"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { printf '[%s] ERROR %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: use-decoy-site.sh [--list] [--force] SITE

Copy one of the starter decoy sites from mistgate/decoy-sites/ into the
directory configured by MISTGATE_DECOY_DIR (default /srv/mistgate-decoy).

  --list    show the available starter sites
  --force   replace an existing site (the old directory is kept as a backup)

Examples:
  bash use-decoy-site.sh --list
  bash use-decoy-site.sh rybalka
  bash use-decoy-site.sh --force palatki
USAGE
}

site_title() {
  case "$1" in
    rybalka) printf '%s\n' "рыбалка и снасти" ;;
    palatki) printf '%s\n' "палатки и походное снаряжение" ;;
    gazirovka) printf '%s\n' "о сахаре в сладких напитках" ;;
    bakery) printf '%s\n' "пекарня" ;;
    veloservice) printf '%s\n' "ремонт велосипедов" ;;
    *) return 1 ;;
  esac
}

list_sites() {
  local name
  for name in rybalka palatki gazirovka bakery veloservice; do
    [[ -d "$DECOY_SITES_DIR/$name" ]] || continue
    printf '  %-12s %s\n' "$name" "$(site_title "$name")"
  done
}

read_decoy_dir() {
  local env_file="$SCRIPT_DIR/.env"
  local dir="$DEFAULT_DECOY_DIR"

  if [[ -n "${MISTGATE_DECOY_DIR:-}" ]]; then
    printf '%s\n' "$MISTGATE_DECOY_DIR"
    return 0
  fi

  if [[ -f "$env_file" ]]; then
    # Read only this one setting; do not source the file into the helper.
    local value
    value="$(sed -n 's/^[[:space:]]*MISTGATE_DECOY_DIR[[:space:]]*=[[:space:]]*//p' "$env_file" | sed -n '1p')"
    value="${value%\"}"
    value="${value#\"}"
    if [[ -n "$value" ]]; then
      dir="$value"
    fi
  fi

  printf '%s\n' "$dir"
}

main() {
  local force=false
  local site=""

  while (($#)); do
    case "$1" in
      --list)
        printf 'Available starter decoy sites:\n'
        list_sites
        return 0
        ;;
      --force)
        force=true
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      -*)
        fail "Unknown option: $1 (use --help)"
        ;;
      *)
        [[ -z "$site" ]] || fail "Only one site name is accepted"
        site="$1"
        shift
        ;;
    esac
  done

  [[ -n "$site" ]] || {
    usage
    exit 1
  }
  [[ -d "$DECOY_SITES_DIR/$site" ]] || fail "Unknown site: $site (use --list)"

  local target
  target="$(read_decoy_dir)"
  if [[ -z "$target" ]]; then
    fail "MISTGATE_DECOY_DIR is empty. Set a directory in $SCRIPT_DIR/.env or remove the empty value."
  fi
  [[ "$target" == /* ]] || fail "MISTGATE_DECOY_DIR must be absolute: $target"
  [[ "$target" != "/" ]] || fail "MISTGATE_DECOY_DIR cannot be /"
  [[ "$target" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || fail "MISTGATE_DECOY_DIR may contain only letters, digits and . _ - /"
  [[ "$target" != /home && "$target" != /home/* && "$target" != /root && "$target" != /root/* ]] \
    || fail "MISTGATE_DECOY_DIR cannot live under /home or /root"

  if [[ -e "$target" ]]; then
    [[ -w "$target" ]] || fail "No write access to $target. Run as root: sudo bash $SCRIPT_DIR/use-decoy-site.sh $site"
  else
    [[ -w "$(dirname -- "$target")" ]] \
      || fail "No write access to $(dirname -- "$target"). Run as root: sudo bash $SCRIPT_DIR/use-decoy-site.sh $site"
  fi

  if [[ -d "$target" ]] && find "$target" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    if [[ "$force" != "true" ]]; then
      fail "$target already contains files. Re-run with --force to replace it (the old directory is kept as a backup)."
    fi
    local backup
    backup="${target}.bak.$(date +%s)"
    mv "$target" "$backup"
    log "Existing site moved to $backup"
  fi

  install -d -m 0755 "$(dirname -- "$target")"
  install -d -m 0755 "$target"
  cp -a "$DECOY_SITES_DIR/$site/." "$target/"
  find "$target" -type d -exec chmod 0755 {} +
  find "$target" -type f -exec chmod 0644 {} +

  log "Installed '$site' ($(site_title "$site")) into $target"

  if command -v systemctl >/dev/null 2>&1 && systemctl cat mistgate.service >/dev/null 2>&1; then
    if ! systemctl cat mistgate.service 2>/dev/null | grep -Fq -- "--decoy-dir $target"; then
      log "The running panel unit does not reference $target yet; run: cd $SCRIPT_DIR && bash setup-mistgate.sh"
    fi
  fi

  log "Changes are served on the next request; no restart is needed"
}

main "$@"
