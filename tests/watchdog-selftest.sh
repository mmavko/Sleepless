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

# --- sleepless CLI <-> watchdog.sh, end to end -------------------------------------------
# Above, leases are hand-written. Here the real writer and the real reader meet, with a
# throwaway HOME so the running machine's own lease is never touched. Real boot time on
# both sides: a mismatch here is exactly the bug that would silently disable the watchdog.
LEASE_SH="$REPO/sleepless"
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
echo "sleepless CLI <-> watchdog.sh"

lease release
[ "$(tick_real_lease)" = "clear" ] && ok "no lease written        -> clear" || bad "no lease written -> should clear"

lease extend 300
[ "$(tick_real_lease)" = "keep" ] && ok "sleepless extend 300    -> keep" || bad "live lease -> should keep"

# extend is a floor, not an assignment: a short renewal must never cut a longer lease short.
# Getting this backwards would let a 30s GUI tick silently truncate a 20-minute CLI lease.
lease extend 5
status_out="$(HOME="$FAKE_HOME" bash "$LEASE_SH" status 2>/dev/null || true)"
if printf '%s' "$status_out" | grep -qE 'live, (29[0-9]|300)s left'; then
  ok "extend 5 does not shorten a 300s lease"
else
  bad "extend 5 shortened a longer lease: $(printf '%s' "$status_out" | tr '\n' ' ')"
fi

# Duration suffixes must all reach the same place as bare seconds.
lease release; lease extend 2m
if [ -n "$(HOME="$FAKE_HOME" bash -c '. "$1/leaselib.sh"; live_expiry' _ "$REPO")" ]; then
  ok "extend accepts 2m as well as bare seconds"
else
  bad "extend 2m produced no live lease"
fi
for bad_d in bogus 5x -1 ""; do
  if HOME="$FAKE_HOME" bash "$LEASE_SH" extend "$bad_d" >/dev/null 2>&1; then
    [ -z "$bad_d" ] || bad "extend accepted bad duration '$bad_d'"
  fi
done
ok "extend rejects malformed durations"

lease release
lease extend 1
sleep 2
[ "$(tick_real_lease)" = "clear" ] && ok "lease expired naturally -> clear" || bad "expired lease -> should clear"

lease extend 300
lease release
[ "$(tick_real_lease)" = "clear" ] && ok "sleepless release       -> clear" || bad "released lease -> should clear"

# The lease is per boot. One written under a different boot id must not hold the flag.
lease extend 300
sed -i '' 's/^boot=.*/boot=1/' "$FAKE_HOME/Library/Application Support/Sleepless/lease"
[ "$(tick_real_lease)" = "clear" ] && ok "lease from another boot -> clear" || bad "cross-boot lease -> should clear"

# --- the UI/CLI contract --------------------------------------------------------------
# `sleepless extend` with no argument reads the app's idle-timeout setting, so the UI stays
# the single source of truth. That is a cross-language contract like boot time, and the same
# class of bug: if it silently falls back, every hook quietly uses the wrong duration.
# A throwaway domain, because `defaults` goes through cfprefsd and ignores HOME.
echo
echo "UI/CLI contract (idle timeout)"

TEST_DOMAIN="com.sleepless.selftest.$$"
cleanup_domain() {
  defaults delete "$TEST_DOMAIN" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$TEST_DOMAIN.plist"
}
trap 'cleanup_domain; rm -rf "$TMP"' EXIT

ttl_for_setting() {
  local minutes="$1"
  if [ "$minutes" = "unset" ]; then
    defaults delete "$TEST_DOMAIN" idleTimeoutMinutes >/dev/null 2>&1 || true
  else
    defaults write "$TEST_DOMAIN" idleTimeoutMinutes -int "$minutes" >/dev/null 2>&1
  fi
  HOME="$FAKE_HOME" bash "$LEASE_SH" release >/dev/null 2>&1
  HOME="$FAKE_HOME" SLEEPLESS_SELFTEST=1 SLEEPLESS_DEFAULTS_DOMAIN="$TEST_DOMAIN" \
    bash "$LEASE_SH" extend >/dev/null 2>&1
  local exp; exp="$(HOME="$FAKE_HOME" bash -c '. "$1/leaselib.sh"; live_expiry' _ "$REPO")"
  [ -n "$exp" ] && echo $(( exp - $(date +%s) )) || echo "none"
}

for pair in "10 600" "60 3600"; do
  set -- $pair
  got="$(ttl_for_setting "$1")"
  # Allow a second of slack for the clock ticking between write and read.
  if [ "$got" != "none" ] && [ "$got" -ge $(( $2 - 2 )) ] && [ "$got" -le "$2" ]; then
    ok "setting ${1}m -> lease ttl ${got}s"
  else
    bad "setting ${1}m -> lease ttl '${got}s', expected ~$2"
  fi
done

got="$(ttl_for_setting unset)"
if [ "$got" != "none" ] && [ "$got" -ge 1198 ] && [ "$got" -le 1200 ]; then
  ok "setting unset -> 20m fallback (${got}s)"
else
  bad "setting unset -> '${got}s', expected the ~1200s fallback"
fi
cleanup_domain

# --- hook detection ------------------------------------------------------------------
# install.sh and `sleepless status` both rely on this to tell you the idle timeout has
# nothing to count. A false positive is the bad direction: it would say you're covered when
# nothing is extending the lease.
echo
echo "Claude Code hook detection"

mkdir -p "$FAKE_HOME/.claude"
hook_check() { HOME="$FAKE_HOME" bash "$LEASE_SH" hook >/dev/null 2>&1; }

rm -f "$FAKE_HOME/.claude/settings.json"
hook_check && bad "reported a hook with no settings file" || ok "no settings file    -> not installed"

echo '{}' > "$FAKE_HOME/.claude/settings.json"
hook_check && bad "reported a hook for empty settings" || ok "empty settings      -> not installed"

echo '{ this is not json' > "$FAKE_HOME/.claude/settings.json"
hook_check && bad "reported a hook for malformed settings" || ok "malformed settings  -> not installed"

# A PreToolUse hook that calls something else entirely must not count.
cat > "$FAKE_HOME/.claude/settings.json" <<'JSON'
{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "/bin/echo hi" } ] } ] } }
JSON
hook_check && bad "counted an unrelated PreToolUse hook" || ok "unrelated hook      -> not installed"

# Right command, wrong event: only PreToolUse drives the heartbeat.
cat > "$FAKE_HOME/.claude/settings.json" <<'JSON'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/x/sleepless extend" } ] } ] } }
JSON
hook_check && bad "counted a Stop hook as the heartbeat" || ok "sleepless on Stop   -> not installed"

cat > "$FAKE_HOME/.claude/settings.json" <<'JSON'
{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "/x/sleepless extend" } ] } ] } }
JSON
hook_check && ok "PreToolUse hook     -> installed" || bad "missed a real PreToolUse hook"

# settings.local.json counts too.
rm -f "$FAKE_HOME/.claude/settings.json"
cat > "$FAKE_HOME/.claude/settings.local.json" <<'JSON'
{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "/x/sleepless", "args": ["extend"] } ] } ] } }
JSON
hook_check && ok "settings.local.json -> installed (args form)" || bad "missed the hook in settings.local.json"
rm -f "$FAKE_HOME/.claude/settings.local.json"

# --- session journal report ------------------------------------------------------------
# The journal is instrumentation whose whole value is the conclusion it draws, so the
# conclusion is what gets tested — especially that heat with the lid OPEN is not reported as
# dangerous. A report that cried wolf on a warm Mac on a desk would be worse than none.
echo
echo "session journal report"

JHOME="$TMP/jhome"; JDIR="$JHOME/Library/Application Support/Sleepless"
mkdir -p "$JDIR"; JFILE="$JDIR/sessions.jsonl"
report() { HOME="$JHOME" bash "$LEASE_SH" report 2>/dev/null; }
summary() { # maxThermal lidClosedSamples onBatterySamples batteryDropPct
  printf '{"ev":"summary","t":1,"reason":"switch","durationSec":3600,"samples":60,"maxThermal":"%s","secondsHot":60,"lidClosedSamples":%s,"onBatterySamples":%s,"batteryStart":90,"batteryEnd":50,"batteryDropPct":%s}\n' "$1" "$2" "$3" "$4"
}

rm -f "$JFILE"
case "$(report)" in *"No session journal yet"*) ok "no journal          -> says so" ;; *) bad "missing journal not handled" ;; esac

summary nominal 0 0 0 > "$JFILE"
case "$(report)" in *"only untested"*) ok "never lid-closed    -> 'untested', not 'safe'" ;; *) bad "did not flag the untested case" ;; esac

summary serious 0 60 18 > "$JFILE"
out="$(report)"
case "$out" in
  *"Not yet evidence"*) ok "hot, lid OPEN       -> not flagged as dangerous" ;;
  *) bad "hot-with-lid-open was misreported: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')" ;;
esac

summary critical 118 120 81 > "$JFILE"
out="$(report)"
case "$out" in
  *"WITH THE LID CLOSED"*) ok "hot, lid CLOSED     -> flagged" ;;
  *) bad "missed the one case that matters: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')" ;;
esac

# A corrupt line must never take the report down: it is the only view onto the corpus.
printf 'not json\n{ broken\n' >> "$JFILE"
if report >/dev/null 2>&1; then ok "malformed lines     -> survives" ; else bad "malformed journal crashed the report"; fi

# Summaries are the corpus and are NEVER rotated by the app; the report still tolerates a .1
# if one exists, so an older journal is not silently dropped.
mv "$JFILE" "$JFILE.1"; : > "$JFILE"
case "$(report)" in *"sessions recorded: 1"*) ok "legacy .1 file      -> still read" ;; *) bad "rotated journal not read"; esac
rm -f "$JFILE.1"

# The corpus must not be capped. A size cap would discard the oldest sessions first, and the
# rare one that cooked in a bag is exactly the one worth keeping.
if grep -q "summariesRelativePath" "$REPO/App.swift" &&
   ! grep -E "rotate.*[Ss]ummar" "$REPO/App.swift" >/dev/null; then
  ok "summaries stream is never rotated"
else
  bad "summaries appear to be size-capped — the corpus would lose its oldest sessions"
fi
if grep -q "samplesMaxBytes" "$REPO/App.swift"; then
  ok "samples stream is capped separately"
else
  bad "no cap on the bulky sample stream"
fi

# The summary keys are written by App.swift and read by the report: a rename on one side
# would silently produce an empty or wrong analysis. Same contract class as boot time.
missing=""
for key in maxThermal lidClosedSamples onBatterySamples batteryDropPct durationSec reason; do
  grep -q "\"$key\"" "$REPO/App.swift" || missing="$missing App.swift:$key"
  grep -q "$key" "$LEASE_SH" || missing="$missing sleepless:$key"
done
[ -z "$missing" ] && ok "summary keys agree across Swift and the report" \
                   || bad "journal key contract broken:$missing"

# --- last-session outcome --------------------------------------------------------------
# The end-of-session notification fires while the lid is shut, so by definition nobody sees
# it. The outcome is persisted and repeated on the lid-open edge; this covers the terminal
# half of that, and in particular that the reason survives intact rather than being flattened
# to "off" — "which safety net stopped it" is the entire question being asked.
echo
echo "last-session outcome"

LDOMAIN="com.sleepless.lasttest.$$"
cleanup_ldomain() {
  defaults delete "$LDOMAIN" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$LDOMAIN.plist"
}
trap 'cleanup_domain; cleanup_ldomain; rm -rf "$TMP"' EXIT

last_note() {
  SLEEPLESS_SELFTEST=1 SLEEPLESS_DEFAULTS_DOMAIN="$LDOMAIN" HOME="$FAKE_HOME" \
    bash "$LEASE_SH" status 2>/dev/null | grep -i "last run" || true
}
write_last() { # agoSec durationSec reason
  defaults write "$LDOMAIN" lastSessionEndedAt -int $(( $(date +%s) - $1 )) >/dev/null 2>&1
  defaults write "$LDOMAIN" lastSessionDurationSec -int "$2" >/dev/null 2>&1
  defaults write "$LDOMAIN" lastSessionReason -string "$3" >/dev/null 2>&1
}

cleanup_ldomain
[ -z "$(last_note)" ] && ok "no history          -> silent" || bad "reported a run with no history"

write_last 60 2400 "No tool calls for 20 min"
case "$(last_note)" in
  *"40 min"*"No tool calls for 20 min"*) ok "idle timeout        -> duration + reason kept" ;;
  *) bad "idle-timeout outcome mangled: $(last_note)" ;;
esac

write_last 60 5400 "Battery low (14%)"
case "$(last_note)" in
  *"90 min"*"Battery low (14%)"*) ok "battery floor       -> duration + reason kept" ;;
  *) bad "battery-floor outcome mangled: $(last_note)" ;;
esac

# The most important one to get right: the app died and the watchdog cleaned up. Nothing else
# tells the user this happened.
write_last 60 7200 "crash"
case "$(last_note)" in
  *"watchdog restored sleep"*) ok "crash               -> says the watchdog saved it" ;;
  *) bad "crash outcome not explained: $(last_note)" ;;
esac

write_last 60 900 "switch"
case "$(last_note)" in
  *"you turned it off"*) ok "manual off          -> phrased for a human" ;;
  *) bad "manual-off outcome mangled: $(last_note)" ;;
esac

write_last 25200 2400 "switch"
[ -z "$(last_note)" ] && ok "older than 6h       -> aged out" || bad "stale outcome still reported"
cleanup_ldomain

# --- uninstall keeps the corpus --------------------------------------------------------
# Uninstalling the app must not silently destroy months of collected evidence. The samples are
# bulky and reproducible; the summaries are not, and they are the whole point of the journal.
echo
echo "uninstall preserves the journal"

if grep -q 'rm -rf "\$SUPPORT_DIR"' "$REPO/uninstall.sh"; then
  bad "uninstall.sh still wipes the whole support dir, journal included"
else
  ok "uninstall.sh does not blanket-delete the support dir"
fi
if grep -q 'sessions.jsonl' "$REPO/uninstall.sh" && grep -q 'samples.jsonl' "$REPO/uninstall.sh"; then
  ok "uninstall.sh distinguishes summaries from samples"
else
  bad "uninstall.sh does not distinguish the corpus from the bulky samples"
fi

# --- login-item naming -----------------------------------------------------------------
# macOS names a background item after the program launchd was handed. With /bin/bash in
# ProgramArguments, System Settings says "bash" — which tells the user nothing and looks like
# something to turn off. Verified against launchd: with the wrapper it reports
# `program = /bin/bash`; with the script alone it reports the script's own path.
echo
echo "login-item naming"

if grep -q "<string>/bin/bash</string>" "$REPO/watchdog-agent.sh"; then
  bad "plist still runs /bin/bash — the login item would be named 'bash'"
else
  ok "plist runs the script directly, not via /bin/bash"
fi
if grep -q 'SUPPORT_DIR/SleeplessWatchdog' "$REPO/watchdog-agent.sh"; then
  ok "installed watchdog has an identifiable name"
else
  bad "installed watchdog has no identifiable name"
fi
if grep -q 'SleeplessWatchdog' "$REPO/uninstall.sh"; then
  ok "uninstall removes it under that name"
else
  bad "uninstall would leave the renamed watchdog behind"
fi

# --- hook install / remove -------------------------------------------------------------
# This writes to ~/.claude/settings.json, which belongs to Claude Code and to whatever else
# the user has configured there. Every case below is about not damaging that file: merge
# rather than overwrite, refuse rather than guess, and leave nothing behind on removal.
echo
echo "hook install/remove"

HHOME="$TMP/hookhome"; mkdir -p "$HHOME/.claude"
HSET="$HHOME/.claude/settings.json"
hk() { HOME="$HHOME" bash "$LEASE_SH" hook "$@" >/dev/null 2>&1; }

rm -f "$HSET"
hk --install && [ -f "$HSET" ] && ok "install     -> creates settings.json" || bad "install did not create settings.json"
hk --install && ok "install     -> idempotent" || bad "second install failed"

# The one that would ruin someone's day: clobbering unrelated configuration.
rm -f "$HSET" "$HHOME/.claude/"*backup* 2>/dev/null
cat > "$HSET" <<'JSON'
{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/bin/echo mine"}]}],"Stop":[{"hooks":[{"type":"command","command":"/bin/echo done"}]}]}}
JSON
hk --install
if /usr/bin/python3 -c "
import json,sys
d=json.load(open('$HSET'))
pre=d['hooks']['PreToolUse']
assert d['model']=='opus'
assert any(h.get('command')=='/bin/echo mine' for e in pre for h in e['hooks'])
assert d['hooks']['Stop'][0]['hooks'][0]['command']=='/bin/echo done'
assert any('sleepless' in h.get('command','') for e in pre for h in e['hooks'])
" 2>/dev/null; then ok "install     -> merges, keeps other keys and hooks"; else bad "install clobbered existing settings"; fi

[ -n "$(ls "$HHOME/.claude/" 2>/dev/null | grep backup)" ] && ok "install     -> backs the file up" || bad "no backup was written"

hk --remove
if /usr/bin/python3 -c "
import json
d=json.load(open('$HSET'))
pre=d['hooks']['PreToolUse']
assert not any('sleepless' in h.get('command','') for e in pre for h in e['hooks'])
assert any(h.get('command')=='/bin/echo mine' for e in pre for h in e['hooks'])
assert d['hooks']['Stop']
" 2>/dev/null; then ok "remove      -> drops ours, keeps theirs"; else bad "remove damaged the file"; fi
hk --remove && ok "remove      -> idempotent" || bad "second remove failed"

# Refuse rather than guess. A half-understood settings.json must come through untouched.
printf '{ this is not json\n' > "$HSET"
HOME="$HHOME" bash "$LEASE_SH" hook --install >/dev/null 2>&1
if [ "$(cat "$HSET")" = "{ this is not json" ]; then
  ok "malformed   -> refuses, file untouched"
else
  bad "malformed settings.json was modified"
fi

# The step is useless if it prints after the app launches and macOS fires its notification.
if /usr/bin/python3 -c "
import sys
t=open('$REPO/install.sh').read()
sys.exit(0 if t.index('Add it now?') < t.index('open \"\$APP\"') else 1)
"; then ok "install.sh  -> asks before launching the app"; else bad "hook prompt comes after the app launches"; fi

grep -q 'hook --remove' "$REPO/uninstall.sh" && ok "uninstall   -> removes the hook" \
  || bad "uninstall leaves a hook pointing at a deleted script"

# --- boot time: the shell/Swift contract --------------------------------------------
# The lease is keyed on boot time, and the app writes it with sysctlbyname("kern.boottime")
# while the scripts parse sysctl(8) output. If those disagree by even one, every lease the
# app writes is rejected and the watchdog clears the flag ~30s after you arm it.
#
# This actually happened: `.*sec = ` is greedy and matched "usec = ", so both scripts read
# the MICROSECONDS field. They agreed with each other, so nothing failed until Swift
# joined. Hence two assertions, not one.
echo
echo "boot time"

# Call the REAL function from leaselib.sh. An earlier version of this test inlined a copy
# of the regex, which meant it validated the copy and would never have caught a regression
# in the shipped code.
SHELL_BOOT="$(HOME="$FAKE_HOME" bash -c '. "$1/leaselib.sh"; boot_time' _ "$REPO")"
NOW="$(date +%s)"

# A boot time must be a plausible unix epoch in the past. The old bug produced ~480767,
# which is 1970 — this assertion alone would have caught it.
if [ -n "$SHELL_BOOT" ] && [ "$SHELL_BOOT" -gt 1000000000 ] && [ "$SHELL_BOOT" -le "$NOW" ]; then
  ok "shell boot time is a plausible epoch ($SHELL_BOOT)"
else
  bad "shell boot time implausible: '${SHELL_BOOT:-empty}' (now=$NOW)"
fi

# And it must equal what the app computes, which is the contract that actually matters.
if command -v swiftc >/dev/null 2>&1; then
  cat > "$TMP/boot.swift" <<'SWIFTEOF'
import Foundation
var tv = timeval()
var size = MemoryLayout<timeval>.stride
guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { exit(1) }
print(Int(tv.tv_sec))
SWIFTEOF
  if swiftc -O "$TMP/boot.swift" -o "$TMP/boottest" 2>/dev/null; then
    SWIFT_BOOT="$("$TMP/boottest")"
    if [ "$SWIFT_BOOT" = "$SHELL_BOOT" ]; then
      ok "shell and Swift boot time agree"
    else
      bad "shell ($SHELL_BOOT) and Swift ($SWIFT_BOOT) boot time DISAGREE"
    fi
  else
    echo "  skip  Swift boot-time comparison (swiftc present but compile failed)"
  fi
else
  echo "  skip  Swift boot-time comparison (no swiftc)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
