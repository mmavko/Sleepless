#!/usr/bin/env bash
# grant.sh — install ONLY the passwordless grant that lets Sleepless toggle lid-close
# sleep without a prompt. Works from a clone or from the app bundle's Resources
# directory, both of which must include the sudoers template beside this script.
#
# It writes one tightly scoped sudoers drop-in (root:wheel, 0440) permitting exactly two
# commands and nothing else. See SECURITY.md. Undo with uninstall.sh (or sudo rm the file).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUDOERS_DST="/etc/sudoers.d/sleepless-disablesleep"
ID=/usr/bin/id
STAT=/usr/bin/stat
SED=/usr/bin/sed
MKTEMP=/usr/bin/mktemp
RM=/bin/rm
INSTALL=/usr/bin/install
VISUDO=/usr/sbin/visudo
# Resolve the REAL user. Prefer SLEEPLESS_USER (the app passes it, because under the native
# auth sheet this script runs as root with SUDO_USER unset), then SUDO_USER, then the caller.
USER_NAME="${SLEEPLESS_USER:-${SUDO_USER:-$($ID -un)}}"
# An explicitly supplied root identity is never a reason to guess another account.
if [ "${SLEEPLESS_USER:-}" = "root" ]; then
  echo "error: refusing an explicit root username for the sudoers grant." >&2
  exit 1
fi
# Never install a root-owned grant (it is useless and not what the user wants): if we somehow
# resolved to root/empty, fall back to the GUI console user, and refuse if still unresolved.
if [ -z "$USER_NAME" ] || [ "$USER_NAME" = "root" ]; then
  USER_NAME="$($STAT -f%Su /dev/console 2>/dev/null || true)"
fi
case "$USER_NAME" in
  ""|root|*[!A-Za-z0-9._-]*)
    echo "error: refusing unsafe or root username '$USER_NAME' for the sudoers grant." >&2
    exit 1
    ;;
esac
USER_UID="$($ID -u "$USER_NAME" 2>/dev/null || true)"
if [ -z "$USER_UID" ] || [ "$USER_UID" = "0" ]; then
  echo "error: '$USER_NAME' is not an existing non-root account; refusing to install." >&2
  exit 1
fi

# Run privileged steps with sudo normally, but directly when we are ALREADY root (e.g. the
# app installs this via one native macOS auth sheet, so there is no Terminal + no sudo prompt).
run_privileged() {
  if [ "$($ID -u)" -eq 0 ]; then
    "$@"
  else
    /usr/bin/sudo "$@"
  fi
}

# The bundled template is the only executable source of truth for the grant.
TEMPLATE="$SCRIPT_DIR/sleepless.sudoers.template"
[ -f "$TEMPLATE" ] || {
  echo "error: missing required sudoers template: $TEMPLATE" >&2
  exit 1
}
GRANT="$($SED "s/__USER__/$USER_NAME/" "$TEMPLATE")"

echo "Sleepless will install this passwordless grant at $SUDOERS_DST (root:wheel, 0440):"
echo ""
echo "    $GRANT"
echo ""
echo "It permits ONLY turning lid-close sleep on (1) or off (0). Nothing else."
if [ "${1:-}" = "--print" ]; then
  exit 0
fi
if [ "${1:-}" != "--yes" ] && [ "${1:-}" != "-y" ]; then
  read -r -p "Continue? [y/N] " reply
  case "$reply" in [yY]*) ;; *) echo "Aborted."; exit 1 ;; esac
fi

TMP="$($MKTEMP)"
cleanup() { "$RM" -f "$TMP"; }
trap cleanup EXIT
printf '%s\n' "$GRANT" > "$TMP"
if ! run_privileged "$VISUDO" -cf "$TMP" >/dev/null; then
  echo "error: generated sudoers failed validation; not installing." >&2
  exit 1
fi
run_privileged "$INSTALL" -m 0440 -o root -g wheel "$TMP" "$SUDOERS_DST"
run_privileged "$VISUDO" -c >/dev/null && echo "✅ grant installed and sudoers parses cleanly ($SUDOERS_DST)."
echo "   Toggle Sleepless from the menu bar; it will no longer need a password."
