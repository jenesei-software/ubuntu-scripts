#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DECOY_SITES_DIR="$SCRIPT_DIR/decoy-sites"
DEFAULT_DECOY_DIR="/srv/mistgate-decoy"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { printf '[%s] ERROR %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: mistgate-decoy --list
       mistgate-decoy SITE_OR_DIRECTORY

Replace the panel decoy site in MISTGATE_DECOY_DIR (default /srv/mistgate-decoy).

  --list            show the built-in starter sites
  SITE_OR_DIRECTORY a starter name (rybalka, palatki, ...) or a directory
                    with index.html

The previous directory is kept as <target>.bak.<timestamp>. Files, directories
and permissions are fixed automatically; the panel serves the new site without
a restart.

Examples:
  sudo mistgate-decoy --list
  sudo mistgate-decoy rybalka
  sudo mistgate-decoy /root/my-site
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

validate_source() {
  local source="$1"

  [[ -d "$source" && ! -L "$source" ]] || fail "Not a directory: $source"
  [[ -f "$source/index.html" && ! -L "$source/index.html" ]] \
    || fail "The site directory must contain a regular index.html: $source"
  if find "$source" -type l -print -quit 2>/dev/null | grep -q .; then
    fail "The site directory contains symbolic links: $source"
  fi
  if find "$source" -type f ! -r -print -quit 2>/dev/null | grep -q .; then
    fail "The site directory contains files that root cannot read: $source"
  fi

  local size files
  size="$(du -sb "$source" | awk '{print $1}')"
  files="$(find "$source" -type f | wc -l | tr -d '[:space:]')"
  if (( size > 2 * 1024 * 1024 || files > 4096 )); then
    printf '[%s] WARN the site is %s KiB / %s files; the panel serves it, but nodes cannot copy it (limits: 2 MiB / 4096 files)\n' \
      "$(date '+%F %T')" "$((size / 1024))" "$files"
  fi
}

main() {
  local source_input=""
  local source=""

  while (($#)); do
    case "$1" in
      --list)
        printf 'Built-in starter decoy sites:\n'
        list_sites
        return 0
        ;;
      -h|--help)
        usage
        return 0
        ;;
      -*)
        fail "Unknown option: $1 (use --help)"
        ;;
      *)
        [[ -z "$source_input" ]] || fail "Only one site or directory is accepted"
        source_input="$1"
        shift
        ;;
    esac
  done

  [[ -n "$source_input" ]] || {
    usage
    exit 1
  }

  if [[ -d "$source_input" ]]; then
    source="$(cd -- "$source_input" && pwd)"
  elif [[ -d "$DECOY_SITES_DIR/$source_input" ]]; then
    source="$DECOY_SITES_DIR/$source_input"
  else
    fail "Not a directory and not a starter name: $source_input (use --list)"
  fi
  validate_source "$source"

  local target
  target="$(read_decoy_dir)"
  [[ -n "$target" ]] \
    || fail "MISTGATE_DECOY_DIR is empty. Remove the empty value or set a directory in $SCRIPT_DIR/.env."
  [[ "$target" != "/" ]] || fail "MISTGATE_DECOY_DIR cannot be /"
  [[ "$target" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || fail "MISTGATE_DECOY_DIR may contain only letters, digits and . _ - /"
  [[ "$target" != /home && "$target" != /home/* && "$target" != /root && "$target" != /root/* ]] \
    || fail "MISTGATE_DECOY_DIR cannot live under /home or /root"

  case "$source/" in
    "$target"/*) fail "The source directory is the target or is inside it: $source" ;;
  esac
  case "$target/" in
    "$source"/*) fail "The target is inside the source directory: $target" ;;
  esac

  if [[ -e "$target" ]]; then
    [[ -w "$target" ]] || fail "No write access to $target. Run as root: sudo mistgate-decoy $source_input"
  else
    [[ -w "$(dirname -- "$target")" ]] \
      || fail "No write access to $(dirname -- "$target"). Run as root: sudo mistgate-decoy $source_input"
  fi

  local backup=""
  if [[ -d "$target" ]] && find "$target" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    backup="${target}.bak.$(date +%Y%m%d-%H%M%S)"
    if [[ -e "$backup" ]]; then
      backup="${backup}-$$"
    fi
    mv "$target" "$backup"
    log "Previous site kept at $backup"
  fi

  install -d -m 0755 "$(dirname -- "$target")"
  install -d -m 0755 "$target"
  cp -a "$source/." "$target/"
  find "$target" -type d -exec chmod 0755 {} +
  find "$target" -type f -exec chmod 0644 {} +

  log "Decoy site installed in $target"
  if [[ -n "$backup" ]]; then
    log "Rollback: sudo mistgate-decoy $backup"
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl cat mistgate.service >/dev/null 2>&1; then
    if ! systemctl cat mistgate.service 2>/dev/null | grep -Fq -- "--decoy-dir $target"; then
      log "The panel unit does not reference $target; run: cd $SCRIPT_DIR && bash setup-mistgate.sh"
    fi
  fi

  log "The panel serves the new files on the next request; no restart is needed"
}

main "$@"
