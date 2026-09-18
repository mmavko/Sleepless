#!/usr/bin/env bash
# lease.sh — read and write the keep-awake lease that watchdog.sh enforces.
#
#   ./lease.sh extend [seconds]   set expiry to max(current, now + seconds); default 120
#   ./lease.sh release            drop the lease (the watchdog clears the flag next tick)
#   ./lease.sh show               print the lease and how long is left
#
# This is the REFERENCE writer for the v1 lease format, and for now the only one: the GUI
# and the CLI will write the same file directly (steps 2 and 3 in docs/LEASE-DESIGN.md).
# Until they do, turning the app's switch on with the watchdog loaded means nobody is
# renewing, so the watchdog will correctly clear the flag within a tick.
#
# The lease expresses INTENT, never state. Writing one does not keep the Mac awake and
# cannot: only the app's privileged pmset call sets the flag. A lease just tells the
# watchdog not to take it away yet.
set -euo pipefail

SUPPORT_DIR="$HOME/Library/Application Support/Sleepless"
LEASE_FILE="$SUPPORT_DIR/lease"
LEASE_VERSION=1
DEFAULT_TTL=120
MAX_LEASE_HORIZON=$((12 * 60 * 60))

boot_time() {
  /usr/sbin/sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p'
}

lease_field() {
  sed -n "s/^$1=\([0-9][0-9]*\)\$/\1/p" "$LEASE_FILE" 2>/dev/null | head -1
}

# Current expiry, but only if the lease is one this boot can trust. A lease from before the
# current boot is stale by construction: disablesleep resets to 0 on reboot.
live_expiry() {
  local boot lease_boot version expires
  [ -f "$LEASE_FILE" ] || return 0
  version="$(lease_field version)"; [ "$version" = "$LEASE_VERSION" ] || return 0
  boot="$(boot_time)"; lease_boot="$(lease_field boot)"
  [ -n "$lease_boot" ] && [ "$lease_boot" = "$boot" ] || return 0
  expires="$(lease_field expires)"; [ -n "$expires" ] || return 0
  echo "$expires"
}

cmd_extend() {
  local ttl="${1:-$DEFAULT_TTL}" now target current
  case "$ttl" in
    ''|*[!0-9]*) echo "error: seconds must be a whole number" >&2; exit 64 ;;
  esac
  if [ "$ttl" -lt 1 ] || [ "$ttl" -gt "$MAX_LEASE_HORIZON" ]; then
    echo "error: seconds must be between 1 and $MAX_LEASE_HORIZON" >&2; exit 64
  fi

  now="$(date +%s)"
  target=$((now + ttl))
  # Never shorten someone else's lease: extend is a floor, not an assignment. A 20-minute
  # lease from the CLI must survive the GUI's next 120s renewal tick.
  current="$(live_expiry)"
  if [ -n "$current" ] && [ "$current" -gt "$target" ]; then target="$current"; fi

  mkdir -p "$SUPPORT_DIR"
  # Write-then-rename: the watchdog must never read a half-written lease.
  local tmp; tmp="$(mktemp "$SUPPORT_DIR/.lease.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  printf 'version=%s\nexpires=%s\nboot=%s\n' "$LEASE_VERSION" "$target" "$(boot_time)" > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$LEASE_FILE"
  trap - EXIT
  echo "lease held for $((target - now))s (until $(date -r "$target" '+%H:%M:%S'))"
}

cmd_release() {
  rm -f "$LEASE_FILE"
  echo "lease released; the watchdog will restore normal sleep within one tick"
}

cmd_show() {
  local expires now
  expires="$(live_expiry)"
  if [ -z "$expires" ]; then
    if [ -f "$LEASE_FILE" ]; then echo "no live lease (file present but stale or unreadable)";
    else echo "no lease"; fi
    return 1
  fi
  now="$(date +%s)"
  if [ "$expires" -le "$now" ]; then
    echo "lease expired $((now - expires))s ago"
    return 1
  fi
  echo "lease live, $((expires - now))s left (until $(date -r "$expires" '+%H:%M:%S'))"
}

case "${1:-}" in
  extend)  cmd_extend "${2:-}" ;;
  release) cmd_release ;;
  show)    cmd_show ;;
  *) echo "usage: $(basename "$0") extend [seconds] | release | show" >&2; exit 64 ;;
esac
