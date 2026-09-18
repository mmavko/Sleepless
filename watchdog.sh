#!/usr/bin/env bash
# watchdog.sh — the dead-man switch for `pmset disablesleep`.
#
# `disablesleep` is global kernel state that no process owns. Every safety net inside the
# GUI (auto-off timer, battery floor, Low Power Mode) is an in-memory Timer, so killing the
# app kills all of them at once while the flag they guarded stays set. Without this script
# the answer to "the app crashed while ON" is "the Mac stays awake until you reboot".
#
# This runs from a LaunchAgent every WATCHDOG_INTERVAL seconds and enforces one rule:
#
#     if SleepDisabled is set and no live lease says it should be, clear it.
#
# SAFETY PROPERTY: this script can only ever make the Mac sleepier. It NEVER sets
# disablesleep to 1 — there is no code path here that can. A bug in this file can cost you
# a keep-awake session; it can never silently keep your Mac awake.
#
# It runs as YOU, not as root, and clears the flag through the same tightly-scoped sudoers
# grant the app already uses (see grant.sh). It needs no new privilege of any kind — which
# is the reason it's an Agent rather than a root Daemon. See docs/LEASE-DESIGN.md.
set -euo pipefail

SUPPORT_DIR="$HOME/Library/Application Support/Sleepless"
LEASE_FILE="$SUPPORT_DIR/lease"
LEASE_VERSION=1
# A lease further out than this is treated as corrupt rather than honoured. Bounds the
# damage from a bad clock or a garbled write: the worst case is an early turn-off.
MAX_LEASE_HORIZON=$((12 * 60 * 60))

PMSET=/usr/bin/pmset
SUDO=/usr/bin/sudo

log() { printf '[sleepless-watchdog] %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

# Seconds since the epoch at which the running kernel booted. A lease written before the
# current boot is meaningless: disablesleep resets to 0 on reboot, so anything still
# claiming a lease across that boundary is stale state, not intent.
boot_time() {
  /usr/sbin/sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p'
}

# 1 when the kernel flag is set, 0 otherwise. Needs no privilege. The line is absent
# entirely when the flag has never been set this boot, which reads as 0. Matches the last
# whitespace-separated token, the same way the app's own reader does.
read_sleep_disabled() {
  "$PMSET" -g 2>/dev/null | awk '
    tolower($0) ~ /sleepdisabled/ { v = $NF }
    END { print (v == "1") ? 1 : 0 }'
}

# The only privileged thing this script does, and the only direction it can go.
clear_sleep_disabled() {
  "$SUDO" -n "$PMSET" -a disablesleep 0
}

# Test seams. Honoured ONLY under SLEEPLESS_SELFTEST=1 so a stray environment variable can
# never redirect the real watchdog. See tests/watchdog-selftest.sh.
if [ "${SLEEPLESS_SELFTEST:-}" = "1" ]; then
  if [ -n "${SLEEPLESS_LEASE_FILE:-}" ]; then LEASE_FILE="$SLEEPLESS_LEASE_FILE"; fi
  if [ -n "${SLEEPLESS_READ_CMD:-}" ]; then
    read_sleep_disabled() { eval "$SLEEPLESS_READ_CMD"; }
  fi
  if [ -n "${SLEEPLESS_CLEAR_CMD:-}" ]; then
    clear_sleep_disabled() { eval "$SLEEPLESS_CLEAR_CMD"; }
  fi
  if [ -n "${SLEEPLESS_BOOT:-}" ]; then
    boot_time() { echo "$SLEEPLESS_BOOT"; }
  fi
fi

# Read one digits-only field from the lease. The lease file is NEVER sourced and never
# eval'd: every field is matched as an explicit run of digits, so a corrupt or hostile file
# yields an empty string rather than executing anything.
lease_field() {
  sed -n "s/^$1=\([0-9][0-9]*\)\$/\1/p" "$LEASE_FILE" 2>/dev/null | head -1
}

# Decide. Echoes a reason to clear, or nothing to leave the flag alone.
reason_to_clear() {
  local now boot version expires
  now="$(date +%s)"
  boot="$(boot_time)"

  [ -f "$LEASE_FILE" ] || { echo "no lease file"; return; }

  version="$(lease_field version)"
  [ "$version" = "$LEASE_VERSION" ] || { echo "unreadable lease (version='${version:-none}')"; return; }

  expires="$(lease_field expires)"
  [ -n "$expires" ] || { echo "lease has no expiry"; return; }

  local lease_boot
  lease_boot="$(lease_field boot)"
  if [ -n "$boot" ] && [ -n "$lease_boot" ] && [ "$lease_boot" != "$boot" ]; then
    echo "lease predates this boot"
    return
  fi

  if [ "$expires" -le "$now" ]; then
    echo "lease expired $((now - expires))s ago"
    return
  fi

  if [ "$expires" -gt "$((now + MAX_LEASE_HORIZON))" ]; then
    echo "lease expiry implausibly far out ($((expires - now))s); treating as corrupt"
    return
  fi
}

main() {
  # Nothing to guard: the common case, and it costs one unprivileged pmset read.
  [ "$(read_sleep_disabled)" = "1" ] || exit 0

  local reason
  reason="$(reason_to_clear)"
  [ -n "$reason" ] || exit 0

  log "clearing disablesleep: $reason"
  if clear_sleep_disabled; then
    log "disablesleep cleared; normal sleep restored"
  else
    # Leave the flag set and retry next tick. A visible, repeating failure is far better
    # than a silent one — this is the whole point of the script.
    log "FAILED to clear disablesleep (is the sudoers grant installed? run ./grant.sh)"
    exit 1
  fi
}

main "$@"
