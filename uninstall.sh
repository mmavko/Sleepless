#!/usr/bin/env bash
# uninstall.sh — completely back Sleepless out: restore normal sleep, remove the app,
# the login item, AND the passwordless grant. Ends by PROVING the privilege is gone.
set -uo pipefail   # not -e: we want to attempt every cleanup step even if one is absent

APP_NAME="Sleepless"
APP="/Applications/$APP_NAME.app"
BUNDLE_ID="com.aboudjem.Sleepless"
SUDOERS_DST="/etc/sudoers.d/sleepless-disablesleep"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
SUPPORT_DIR="$HOME/Library/Application Support/Sleepless"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Sleepless uninstaller"
echo "====================="

# 1. Remove the watchdog FIRST, so it cannot tick during teardown and log failures about a
# grant we are about to delete on purpose.
echo "==> Removing the watchdog agent"
if [ -x "$REPO/watchdog-agent.sh" ]; then
  "$REPO/watchdog-agent.sh" uninstall || true
else
  launchctl bootout "gui/$(id -u)/$BUNDLE_ID.watchdog" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$BUNDLE_ID.watchdog.plist"
fi
# Remove the runtime state, but KEEP the session journal. It is the corpus the thermal design
# is meant to be built from, it is months of evidence that cannot be regenerated, and deleting
# months of a user's data as a side effect of "uninstall the app" is not ours to decide. The
# per-minute samples are bulky and reproducible, so those go.
rm -f "$SUPPORT_DIR/lease" "$SUPPORT_DIR/SleeplessWatchdog" "$SUPPORT_DIR/watchdog.sh" \
      "$SUPPORT_DIR/leaselib.sh" \
      "$SUPPORT_DIR/samples.jsonl" "$SUPPORT_DIR/samples.jsonl.1"
if [ -s "$SUPPORT_DIR/sessions.jsonl" ]; then
  echo "    kept your session journal: $SUPPORT_DIR/sessions.jsonl"
  echo "    (delete it yourself if you want it gone)"
else
  rmdir "$SUPPORT_DIR" 2>/dev/null || true
fi

# 2. Restore normal sleep BEFORE removing the grant (a reboot would also reset it to 0).
echo "==> Restoring normal sleep (disablesleep 0)"
sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || sudo /usr/bin/pmset -a disablesleep 0 || true

# 3. Quit the app + remove the login item.
echo "==> Quitting app + removing login item"
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
rm -f "$LAUNCH_AGENT"

# 4. Remove the app.
echo "==> Removing $APP"
rm -rf "$APP"

# 5. Remove the passwordless grant (password required, by design — you're touching sudo).
echo "==> Removing passwordless grant (you may be asked for your password)"
sudo rm -f "$SUDOERS_DST"
sudo visudo -c >/dev/null && echo "    sudoers still parses cleanly"

# 6. Proof of revocation: the previously-passwordless command must now PROMPT.
echo "==> Verifying the grant is gone"
sudo -k
if sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null; then
  echo "    ⚠️  unexpected: pmset still ran without a password — check $SUDOERS_DST"
else
  echo "    ✅ revoked: 'sudo -n pmset …' now requires a password again."
fi

echo ""
echo "Done. Sleepless and its grant are removed. UserDefaults (the battery-floor value)"
echo "can be cleared with: defaults delete $BUNDLE_ID 2>/dev/null || true"
