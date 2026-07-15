#!/bin/bash
# Build MacUsage in release mode and launch it.
# First build takes ~30s; later builds are much faster.
set -e
cd "$(dirname "$0")"

echo "Building MacUsage..."
swift build -c release

echo "Launching... (look for the gauge icon in your menu bar)"
# Stop any already-running copy first so you don't get two icons.
pkill -x MacUsage 2>/dev/null || true
.build/release/MacUsage &
echo "Running. Quit from the panel's Quit button, or: pkill -x MacUsage"
