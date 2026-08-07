#!/usr/bin/env bash
#
# Tests for the pure logic: history bucketing, the 24 h store, card
# order parsing, and alert hysteresis.
#
# There is no SwiftPM test target because the package is a single
# executable, and splitting it into a library plus a shim purely to be
# testable would complicate the build for everyone. Instead this
# compiles the real sources directly, alongside Tests.swift.
#
# MacUsageApp.swift is the one exception: it is copied with its @main
# attribute stripped so the test file can own the entry point. Every
# other file is production source, unmodified.
#
#   ./Testing/run.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=Sources/MacUsage
BUILD=.build/testing
mkdir -p "$BUILD"

sed 's/^@main$//' "$SRC/MacUsageApp.swift" > "$BUILD/MacUsageApp.swift"
FILES=$(find "$SRC" -name '*.swift' ! -name 'MacUsageApp.swift')

# Remove the previous binary first. Without this a compile failure
# silently re-runs the last good build, and the suite "passes" without
# having tested the current code.
rm -f "$BUILD/tests"

if ! swiftc -O -parse-as-library $FILES "$BUILD/MacUsageApp.swift" Testing/Tests.swift \
     -o "$BUILD/tests" 2>"$BUILD/compile.log"; then
  echo "COMPILE FAILED"
  grep -E "error" "$BUILD/compile.log" | head -20
  exit 1
fi

"$BUILD/tests"
