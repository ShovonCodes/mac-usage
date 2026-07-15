#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# One-command installer for MacUsage.
#
#   ./install.sh            build + install + launch
#   ./install.sh --login    same, and also register "start at login"
#
# What it does:
#   1. Builds the release binary with Swift Package Manager.
#   2. Wraps it into a real MacUsage.app bundle (Spotlight-searchable).
#   3. Copies the bundle into /Applications (or ~/Applications).
#   4. Relaunches the app.
#   5. Optionally registers it as a login item so it survives reboots.
#
# Safe to re-run any time — it replaces the installed copy in place.
# ─────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MacUsage"
DISPLAY_NAME="Mac Usage"
BUNDLE_ID="com.macusage.app"
VERSION="1.0.0"

WANT_LOGIN_ITEM="ask"
[ "${1:-}" = "--login" ] && WANT_LOGIN_ITEM="yes"

# 1. Toolchain check ───────────────────────────────────────────────
if ! command -v swift >/dev/null 2>&1; then
  echo "error: Swift toolchain not found."
  echo "Install the Xcode Command Line Tools first:  xcode-select --install"
  exit 1
fi

# 2. Build ─────────────────────────────────────────────────────────
echo "▸ Building $APP_NAME (release)..."
swift build -c release
BINARY=".build/release/$APP_NAME"

# 3. Assemble the .app bundle ──────────────────────────────────────
echo "▸ Assembling $APP_NAME.app..."
STAGE=".build/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp "$BINARY" "$STAGE/Contents/MacOS/$APP_NAME"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: keeps macOS treating every reinstall as the
# same app (permissions and login-item registration stay stable).
codesign --force --sign - "$STAGE"

# 4. Install ───────────────────────────────────────────────────────
if [ -w /Applications ]; then
  DEST="/Applications"
else
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi
APP_PATH="$DEST/$APP_NAME.app"
echo "▸ Installing to $APP_PATH..."
pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "$APP_PATH"
ditto "$STAGE" "$APP_PATH"

# 5. Launch ────────────────────────────────────────────────────────
open "$APP_PATH"
echo "✓ Installed and launched — look for the gauge icon in the menu bar."
echo "  (Spotlight can now find it: ⌘Space → \"$DISPLAY_NAME\")"

# 6. Login item (optional) ─────────────────────────────────────────
# Ask via /dev/tty (the terminal itself), not stdin: piped installs
# (curl | bash) use stdin for the script, so it can't carry answers.
if [ "$WANT_LOGIN_ITEM" = "ask" ]; then
  if { read -r -p "Start $DISPLAY_NAME automatically at login? [y/N] " reply < /dev/tty; } 2>/dev/null; then
    case "$reply" in
      [Yy]*) WANT_LOGIN_ITEM="yes" ;;
      *)     WANT_LOGIN_ITEM="no"  ;;
    esac
  else
    # No terminal attached (CI, scripted install) — default to no.
    WANT_LOGIN_ITEM="no"
  fi
fi

if [ "$WANT_LOGIN_ITEM" = "yes" ]; then
  if osascript >/dev/null 2>&1 <<OSA
tell application "System Events"
    if exists login item "$APP_NAME" then delete login item "$APP_NAME"
    make login item at end with properties {path:"$APP_PATH", hidden:false, name:"$APP_NAME"}
end tell
OSA
  then
    echo "✓ Registered as a login item (remove any time in System Settings → General → Login Items)."
  else
    echo "! Could not add the login item automatically (macOS blocked the automation request)."
    echo "  Add it manually: System Settings → General → Login Items → \"+\" → $APP_PATH"
  fi
else
  echo "  Skipped start-at-login. Enable it any time:"
  echo "  System Settings → General → Login Items → \"+\" → $APP_PATH"
fi
