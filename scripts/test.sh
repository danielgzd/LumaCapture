#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

LUMA_TEST_ARCH="$(uname -m)"
LUMA_TEST_MODE=xctest
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) LUMA_TEST_ARCH="${2:?An architecture is required}"; shift 2 ;;
    --portable) LUMA_TEST_MODE=portable; shift ;;
    --help) echo 'Usage: scripts/test.sh [--arch arm64|x86_64] [--portable]'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$LUMA_TEST_ARCH" == arm64 || "$LUMA_TEST_ARCH" == x86_64 ]] || { echo 'Unsupported architecture.' >&2; exit 2; }
developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ ! -d "$developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]]; then
  LUMA_TEST_MODE=portable
fi
if [[ "$LUMA_TEST_ARCH" != "$(uname -m)" ]]; then LUMA_TEST_MODE=portable; fi

if [[ "$LUMA_TEST_MODE" == xctest ]]; then
  "$LUMA_SWIFT" test --package-path "$LUMA_ROOT" --disable-sandbox \
    --cache-path "$LUMA_BUILD/package-cache" --config-path "$LUMA_BUILD/package-config" \
    --security-path "$LUMA_BUILD/package-security" --scratch-path "$LUMA_BUILD/tests" \
    --manifest-cache local -Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH"
else
  # The same behavioral checks work with CLT, which does not include XCTest.
  destination="$LUMA_BUILD/portable-tests/$LUMA_TEST_ARCH"
  luma_compile_core "$LUMA_TEST_ARCH" "$destination"
  "$LUMA_SWIFTC" -swift-version 5 -parse-as-library \
    -target "$LUMA_TEST_ARCH-apple-macosx$LUMA_DEPLOYMENT_TARGET" -sdk "$LUMA_SDK" \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" -I "$destination" -L "$destination" -lLumaCaptureCore \
    "$LUMA_ROOT/Tests/LumaCaptureCoreTests/CoreChecks.swift" "$LUMA_ROOT/scripts/test-main.swift" \
    -o "$destination/CoreChecks"
  if [[ "$LUMA_TEST_ARCH" == "$(uname -m)" ]]; then
    /usr/bin/arch "-$LUMA_TEST_ARCH" "$destination/CoreChecks"
  else
    file "$destination/CoreChecks"
    lipo "$destination/CoreChecks" -verify_arch "$LUMA_TEST_ARCH"
    echo "PASS $LUMA_TEST_ARCH compilation (execution requires matching hardware or Rosetta)"
  fi
fi
