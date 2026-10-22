#!/bin/bash
# Builds the engine's tests (mac/tests) with the engine and runs them.
# Needs the Xcode Command Line Tools; the preview tests also need ffmpeg.
#
#   scripts/test-mac.sh                 every test
#   scripts/test-mac.sh moviehash       the tests whose name contains "moviehash"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TARGET="$(uname -m)-apple-macos14.4"

clang -O2 -target "$TARGET" -c "$ROOT/mac/engine/fdlibm.c" -o "$TMP/fdlibm.o"
swiftc -O -swift-version 5 -target "$TARGET" -import-objc-header "$ROOT/mac/engine/Bridge.h" -o "$TMP/tests" \
  "$ROOT"/mac/engine/*.swift "$ROOT"/mac/tests/*.swift "$TMP/fdlibm.o" -licucore
"$TMP/tests" "$@"
