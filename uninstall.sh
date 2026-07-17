#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# Removes MacUsage completely.
#
#   curl -fsSL https://raw.githubusercontent.com/ShovonCodes/mac-usage/main/uninstall.sh | bash
#
# Quits the app, deletes the app bundle, removes the login item
# (if one was registered), and clears saved preferences.
# ─────────────────────────────────────────────────────────────────
# Deliberately no `set -e`: every step is best-effort so a missing
# piece (already uninstalled, never registered) doesn't stop cleanup.
set -u

APP_NAME="MacUsage"
BUNDLE_ID="com.macusage.app"

echo "▸ Quitting $APP_NAME..."
pkill -x "$APP_NAME" 2>/dev/null

# Deregister start-at-login while the app bundle still exists —
# SMAppService registrations can only be flipped by the app itself.
for APP in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
  if [ -x "$APP/Contents/MacOS/$APP_NAME" ]; then
    "$APP/Contents/MacOS/$APP_NAME" --set-login off >/dev/null 2>&1
  fi
done

REMOVED=0
for APP in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
  if [ -d "$APP" ]; then
    rm -rf "$APP"
    echo "✓ Removed $APP"
    REMOVED=1
  fi
done
[ "$REMOVED" = "0" ] && echo "  (no installed copy found)"

# Legacy login item (versions before SMAppService used System Events).
# Best effort; macOS may ask permission to control System Events the
# first time. Silent no-op if never registered.
if osascript -e "tell application \"System Events\" to delete login item \"$APP_NAME\"" >/dev/null 2>&1; then
  echo "✓ Removed the login item"
fi

# Saved preferences (silent no-op if none exist).
defaults delete "$BUNDLE_ID" >/dev/null 2>&1

echo "✓ $APP_NAME is uninstalled."
