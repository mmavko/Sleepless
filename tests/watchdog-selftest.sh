#!/usr/bin/env bash
# tests/watchdog-selftest.sh — exercise every decision watchdog.sh can make, without
# touching the real disablesleep flag or needing the sudoers grant.
#
# The watchdog is the one component whose failure is silent by nature: if it stops clearing
# the flag, everything still looks fine until the day your Mac is awake in a bag. So its
# logic is tested directly, with the pmset read and the privileged clear injected.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHDOG="$REPO/watchdog.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LEASE="$TMP/lease"
CLEARED="$TMP/cleared"
NOW="$(date +%s)"
BOOT=1700000000

pass=0; fail=0
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# Run one tick. $1 = flag state ("1"/"0"). Returns the tick's exit status; creates
# $CLEARED iff the watchdog decided to clear.
tick() {
  rm -f "$CLEARED"
  SLEEPLESS_SELFTEST=1 \
  SLEEPLESS_LEASE_FILE="$LEASE" \
  SLEEPLESS_BOOT="$BOOT" \
  SLEEPLESS_READ_CMD="echo $1" \
  SLEEPLESS_CLEAR_CMD="touch '$CLEARED'" \
  bash "$WATCHDOG" 2>/dev/null
}

# $1 = label, $2 = flag state, $3 = "clear" | "keep"
expect() {
  local label="$1" flag="$2" want="$3" status
  tick "$flag"; status=$?
  local got="keep"; [ -f "$CLEARED" ] && got="clear"
  if [ "$got" = "$want" ] && [ "$status" -eq 0 ]; then
    ok "$label"
  else
    bad "$label (wanted $want, got $got, exit $status)"
  fi
}

write_lease() { printf '%s\n' "$@" > "$LEASE"; }

echo "watchdog.sh self-test"

# The common case: nothing to guard, so the lease is never even consulted.
rm -f "$LEASE"
expect "flag off, no lease            -> keep"  0 keep

write_lease "version=1" "expires=$((NOW + 300))" "boot=$BOOT"
expect "flag off, live lease          -> keep"  0 keep

# A live lease is the only thing that holds the flag.
expect "flag on,  live lease          -> keep"  1 keep

# Every other state clears. This is the dead-man switch itself: the GUI crashing means
# nobody renews, so within one TTL the lease stops being live and the flag goes.
rm -f "$LEASE"
expect "flag on,  no lease            -> clear" 1 clear

write_lease "version=1" "expires=$((NOW - 1))" "boot=$BOOT"
expect "flag on,  expired 1s ago      -> clear" 1 clear

write_lease "version=1" "expires=$((NOW + 300))" "boot=$((BOOT - 10000))"
expect "flag on,  lease before boot   -> clear" 1 clear

write_lease "version=1" "expires=$((NOW + 86400 * 30))" "boot=$BOOT"
expect "flag on,  expiry 30d out      -> clear" 1 clear

write_lease "version=99" "expires=$((NOW + 300))" "boot=$BOOT"
expect "flag on,  unknown version     -> clear" 1 clear

write_lease "version=1" "boot=$BOOT"
expect "flag on,  no expiry field     -> clear" 1 clear

write_lease "not a lease at all"
expect "flag on,  garbage lease       -> clear" 1 clear

: > "$LEASE"
expect "flag on,  empty lease         -> clear" 1 clear

# The lease file is parsed, never sourced. A hostile value must not execute and must not
# be accepted as an expiry.
write_lease "version=1" 'expires=$(touch '"$TMP/PWNED"')' "boot=$BOOT"
expect "flag on,  injection attempt   -> clear" 1 clear
if [ -f "$TMP/PWNED" ]; then bad "lease file was evaluated"; else ok "lease file not evaluated"; fi

# A failed clear must be loud and non-zero, so launchd and the log show it, and the next
# tick tries again. Silence here would defeat the whole component.
rm -f "$LEASE"
SLEEPLESS_SELFTEST=1 SLEEPLESS_LEASE_FILE="$LEASE" SLEEPLESS_BOOT="$BOOT" \
SLEEPLESS_READ_CMD="echo 1" SLEEPLESS_CLEAR_CMD="false" \
bash "$WATCHDOG" >/dev/null 2>&1
[ $? -ne 0 ] && ok "failed clear exits non-zero" || bad "failed clear exited 0"

# And it must say why, not fail mutely.
msg="$(SLEEPLESS_SELFTEST=1 SLEEPLESS_LEASE_FILE="$LEASE" SLEEPLESS_BOOT="$BOOT" \
       SLEEPLESS_READ_CMD="echo 1" SLEEPLESS_CLEAR_CMD="false" \
       bash "$WATCHDOG" 2>&1 >/dev/null || true)"
case "$msg" in
  *FAILED*grant.sh*) ok "failed clear names the likely cause" ;;
  *) bad "failed clear message unhelpful: $msg" ;;
esac

# --- lease.sh <-> watchdog.sh, end to end -------------------------------------------
# Above, leases are hand-written. Here the real writer and the real reader meet, with a
# throwaway HOME so the running machine's own lease is never touched. Real boot time on
# both sides: a mismatch here is exactly the bug that would silently disable the watchdog.
LEASE_SH="$REPO/lease.sh"
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"

lease() { HOME="$FAKE_HOME" bash "$LEASE_SH" "$@" >/dev/null 2>&1; }
# Real lease path, real boot time; only the flag read and the privileged clear are faked.
tick_real_lease() {
  rm -f "$CLEARED"
  HOME="$FAKE_HOME" SLEEPLESS_SELFTEST=1 \
    SLEEPLESS_READ_CMD="echo 1" SLEEPLESS_CLEAR_CMD="touch '$CLEARED'" \
    bash "$WATCHDOG" >/dev/null 2>&1
  [ -f "$CLEARED" ] && echo clear || echo keep
}

echo
echo "lease.sh <-> watchdog.sh"

lease release
[ "$(tick_real_lease)" = "clear" ] && ok "no lease written        -> clear" || bad "no lease written -> should clear"

lease extend 300
[ "$(tick_real_lease)" = "keep" ] && ok "lease.sh extend 300     -> keep" || bad "live lease -> should keep"

# extend is a floor, not an assignment: a short renewal must never cut a longer lease short.
# Getting this backwards would let a 30s GUI tick silently truncate a 20-minute CLI lease.
lease extend 5
if HOME="$FAKE_HOME" bash "$LEASE_SH" show 2>/dev/null | grep -qE '29[0-9]s left|300s left'; then
  ok "extend 5 does not shorten a 300s lease"
else
  bad "extend 5 shortened a longer lease: $(HOME="$FAKE_HOME" bash "$LEASE_SH" show 2>&1)"
fi

lease release
lease extend 1
sleep 2
[ "$(tick_real_lease)" = "clear" ] && ok "lease expired naturally -> clear" || bad "expired lease -> should clear"

lease extend 300
lease release
[ "$(tick_real_lease)" = "clear" ] && ok "lease.sh release        -> clear" || bad "released lease -> should clear"

# The lease is per boot. One written under a different boot id must not hold the flag.
lease extend 300
sed -i '' 's/^boot=.*/boot=1/' "$FAKE_HOME/Library/Application Support/Sleepless/lease"
[ "$(tick_real_lease)" = "clear" ] && ok "lease from another boot -> clear" || bad "cross-boot lease -> should clear"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
