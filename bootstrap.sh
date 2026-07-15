#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# One-line installer/updater for MacUsage — no manual clone needed.
#
#   curl -fsSL https://raw.githubusercontent.com/ShovonCodes/mac-usage/main/bootstrap.sh | bash
#
# The installer asks whether the app should start at login.
#
# Running it again later = update: it always fetches the latest
# main branch, rebuilds, and replaces the installed app in place.
#
# What it does: clones the repo into a temp folder, runs install.sh
# from it, then deletes the temp folder.
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_URL="${MACUSAGE_REPO:-https://github.com/ShovonCodes/mac-usage.git}"

if ! command -v git >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  echo "error: the Xcode Command Line Tools are required (they include git and Swift)."
  echo "Install them first:  xcode-select --install"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "▸ Fetching the latest MacUsage..."
git clone --quiet --depth 1 "$REPO_URL" "$TMP_DIR/mac-usage"

"$TMP_DIR/mac-usage/install.sh"
