#!/usr/bin/env bash
# leaselib.sh — the v1 keep-awake lease format, in one place.
#
# Sourced by watchdog.sh (the enforcer) and lease.sh (the reference writer). It exists
# because those two once each carried their own copy of this parsing, and a bug had to be
# fixed twice — see the boot_time note below for the one that got away.
#
# App.swift reimplements this in Swift (it cannot source shell). tests/watchdog-selftest.sh
# asserts the two agree; that assertion is not optional, it is the contract.

LEASE_VERSION=1
SUPPORT_DIR="$HOME/Library/Application Support/Sleepless"
LEASE_FILE="${SLEEPLESS_LEASE_FILE_OVERRIDE:-$SUPPORT_DIR/lease}"
# A lease further out than this is treated as corrupt rather than honoured, bounding the
# damage from a bad clock or a garbled write. Worst case is an early turn-off.
MAX_LEASE_HORIZON=$((12 * 60 * 60))

# Seconds since the epoch at which the running kernel booted.
#
# sysctl prints: { sec = 1789518506, usec = 480767 } Wed Sep 16 02:28:26 2026
#
# Anchor on "{ sec". A greedy `.*sec = ` matches "usec = " and silently yields the
# MICROSECONDS instead. That bug shipped here: both shell scripts had it, so they agreed
# with each other and every test passed — until App.swift's sysctlbyname("kern.boottime")
# disagreed, which would have made the watchdog reject every lease the app writes and
# clear the flag ~30s after arming.
boot_time() {
  /usr/sbin/sysctl -n kern.boottime 2>/dev/null |
    sed -n 's/^[[:space:]]*{[[:space:]]*sec[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

# One digits-only field. The lease is PARSED, never sourced and never eval'd: a corrupt or
# hostile file yields an empty string, which every caller reads as "not live".
lease_field() {
  sed -n "s/^$1=\([0-9][0-9]*\)\$/\1/p" "$LEASE_FILE" 2>/dev/null | head -1
}

# The single decision both callers share. Echoes either:
#   live <expiry-epoch>
#   dead <reason>
# Every failure direction is "dead", i.e. toward letting the Mac sleep.
lease_state() {
  local now boot version expires lease_boot
  now="$(date +%s)"

  [ -f "$LEASE_FILE" ] || { echo "dead no lease file"; return; }

  version="$(lease_field version)"
  [ "$version" = "$LEASE_VERSION" ] || { echo "dead unreadable lease (version='${version:-none}')"; return; }

  expires="$(lease_field expires)"
  [ -n "$expires" ] || { echo "dead lease has no expiry"; return; }

  # A lease cannot outlive its boot: disablesleep resets to 0 on reboot, so anything still
  # claiming a lease across that boundary is stale state, not intent.
  boot="$(boot_time)"
  lease_boot="$(lease_field boot)"
  if [ -n "$boot" ] && [ -n "$lease_boot" ] && [ "$lease_boot" != "$boot" ]; then
    echo "dead lease predates this boot"; return
  fi

  if [ "$expires" -le "$now" ]; then
    echo "dead lease expired $((now - expires))s ago"; return
  fi

  if [ "$expires" -gt "$((now + MAX_LEASE_HORIZON))" ]; then
    echo "dead lease expiry implausibly far out ($((expires - now))s); treating as corrupt"; return
  fi

  echo "live $expires"
}

# Expiry if the lease is live, empty otherwise.
live_expiry() {
  local state; state="$(lease_state)"
  case "$state" in live\ *) echo "${state#live }" ;; esac
}
