#!/usr/bin/env bash
# watchdog-agent.sh — install, remove or check the LaunchAgent that runs watchdog.sh.
#
#   ./watchdog-agent.sh install     copy watchdog.sh into place and load the agent
#   ./watchdog-agent.sh uninstall   unload the agent and remove both
#   ./watchdog-agent.sh status      exit 0 iff the agent is loaded (quiet with --quiet)
#
# An AGENT, not a root daemon. It runs as you and clears the flag through the sudoers grant
# the app already has, so the dead-man switch costs no new privilege at all. The trade is
# that it does not run at the login window — see docs/LEASE-DESIGN.md for why that gap is
# acceptable and what would change if it stops being.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.aboudjem.Sleepless.watchdog"
SUPPORT_DIR="$HOME/Library/Application Support/Sleepless"
INSTALLED_WATCHDOG="$SUPPORT_DIR/watchdog.sh"
INSTALLED_LIB="$SUPPORT_DIR/leaselib.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/Sleepless-watchdog.log"
# Must stay well under the lease TTL the renewers use, or a live lease can lapse unnoticed
# between ticks. See docs/LEASE-DESIGN.md: 120s TTL, 30s renew, 30s tick.
INTERVAL=30

is_loaded() { launchctl list "$LABEL" >/dev/null 2>&1; }

cmd_status() {
  if is_loaded; then
    [ "${1:-}" = "--quiet" ] || echo "loaded: $LABEL (tick ${INTERVAL}s, log $LOG)"
    return 0
  fi
  [ "${1:-}" = "--quiet" ] || echo "NOT loaded: $LABEL"
  return 1
}

cmd_install() {
  for f in watchdog.sh leaselib.sh; do
    [ -f "$SCRIPT_DIR/$f" ] || { echo "error: $f not found beside this script" >&2; exit 1; }
  done

  mkdir -p "$SUPPORT_DIR" "$(dirname "$PLIST")" "$(dirname "$LOG")"
  # Install a COPY rather than pointing launchd at the repo: the agent must keep working if
  # the working tree moves, and must not change under it when you switch branches.
  install -m 0755 "$SCRIPT_DIR/watchdog.sh" "$INSTALLED_WATCHDOG"
  # watchdog.sh sources this from its own directory, so the installed pair is self-contained.
  install -m 0644 "$SCRIPT_DIR/leaselib.sh" "$INSTALLED_LIB"

  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>                <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$INSTALLED_WATCHDOG</string>
    </array>
    <key>StartInterval</key>        <integer>$INTERVAL</integer>
    <key>RunAtLoad</key>            <true/>
    <key>StandardOutPath</key>      <string>$LOG</string>
    <key>StandardErrorPath</key>    <string>$LOG</string>
</dict>
</plist>
PLIST_EOF
  plutil -lint "$PLIST" >/dev/null

  # bootout first so "install" is idempotent and always picks up a changed plist.
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$PLIST"

  if cmd_status --quiet; then
    echo "✅ watchdog agent loaded ($LABEL), ticking every ${INTERVAL}s."
    echo "   script: $INSTALLED_WATCHDOG"
    echo "   log:    $LOG"
  else
    echo "error: agent did not load. Check: launchctl print gui/$UID/$LABEL" >&2
    exit 1
  fi
}

cmd_uninstall() {
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$INSTALLED_WATCHDOG" "$INSTALLED_LIB"
  if is_loaded; then
    echo "error: $LABEL is still loaded" >&2
    exit 1
  fi
  echo "✅ watchdog agent removed."
  echo "   Note: with no watchdog, a crash while Sleepless is ON leaves the Mac awake until reboot."
}

case "${1:-}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status "${2:-}" ;;
  *) echo "usage: $(basename "$0") install|uninstall|status [--quiet]" >&2; exit 64 ;;
esac
