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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The lease format lives in exactly one place. watchdog-agent.sh installs this file
# alongside the script, so the installed copy is self-contained.
# shellcheck source=leaselib.sh
. "$SCRIPT_DIR/leaselib.sh"

PMSET=/usr/bin/pmset
SUDO=/usr/bin/sudo

log() { printf '[sleepless-watchdog] %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

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

# Decide, using the shared lease_state(). Echoes a reason to clear, or nothing to leave
# the flag alone.
reason_to_clear() {
  local state; state="$(lease_state)"
  case "$state" in
    live\ *) ;;                      # a live lease is the only thing that holds the flag
    dead\ *) echo "${state#dead }" ;;
    *)       echo "unrecognised lease state" ;;
  esac
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
