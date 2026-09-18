#!/usr/bin/env bash
# install.sh — build Sleepless and add the passwordless grant that lets it toggle
# lid-close sleep. Launch at login is controlled only by the app's native switch.
#
# This top-level installer delegates the privileged grant to grant.sh and previews
# its template-derived content first. To back everything out, run ./uninstall.sh.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Sleepless"
APP="/Applications/$APP_NAME.app"
BUNDLE_ID="com.aboudjem.Sleepless"
SUDOERS_DST="/etc/sudoers.d/sleepless-disablesleep"
LEGACY_LAUNCH_AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

echo "Sleepless installer"
echo "==================="
echo "This will:"
echo "  1. Build $APP_NAME.app and copy it to /Applications."
echo "  2. Install a passwordless sudo grant at $SUDOERS_DST so the app can flip"
echo "     lid-close sleep without prompting. The exact template-derived grant is:"
"$REPO/grant.sh" --print
echo "  3. Remove the obsolete script-installed login item, if present."
echo "     Use Sleepless's Launch at login switch to control the native login item."
echo ""
read -r -p "Continue? [y/N] " reply
case "$reply" in [yY]*) ;; *) echo "Aborted."; exit 1 ;; esac

# 1. Build into /Applications.
echo "==> Building into /Applications"
DEST=/Applications "$REPO/build.sh" /Applications

# 2. Passwordless grant (delegated to grant.sh, the single source of truth).
echo "==> Installing passwordless grant (you'll be asked for your password once)"
"$REPO/grant.sh" --yes

# 3. Migrate away from the pre-SMAppService login item. New installs never create it;
# users who wanted login launch can enable the native switch after the app opens.
if [ -f "$LEGACY_LAUNCH_AGENT" ]; then
  echo "==> Removing obsolete script-installed login item"
  launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
  rm -f "$LEGACY_LAUNCH_AGENT"
fi

# Launch now.
open "$APP"

echo ""
echo "✅ Installed. The coffee cup is in your menu bar — click it to toggle."
echo "   Turn ON, close the lid: your Mac stays awake on battery (auto-off at the floor you set)."
echo "   To remove everything (including the grant): ./uninstall.sh"
