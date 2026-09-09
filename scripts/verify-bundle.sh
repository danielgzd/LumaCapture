#!/bin/bash
set -euo pipefail
LUMA_VERIFY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# == 0 ]]; then
  exec "$LUMA_VERIFY_ROOT/scripts/verify-artifacts.sh" "$LUMA_VERIFY_ROOT/dist" "${VERSION:-0.1.0}"
fi
LUMA_VERIFY_APP="$1"
LUMA_VERIFY_BIN="$LUMA_VERIFY_APP/Contents/MacOS/LumaCapture"
test -x "$LUMA_VERIFY_BIN"
test -s "$LUMA_VERIFY_APP/Contents/Resources/AppIcon.icns"
plutil -lint "$LUMA_VERIFY_APP/Contents/Info.plist"
lipo "$LUMA_VERIFY_BIN" -verify_arch arm64 x86_64
codesign --verify --deep --strict --verbose=2 "$LUMA_VERIFY_APP"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$LUMA_VERIFY_APP/Contents/Info.plist")"
[[ "$minimum" == 15.0 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$LUMA_VERIFY_APP/Contents/Info.plist")" == LumaCapture ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LUMA_VERIFY_APP/Contents/Info.plist")" == io.github.danielgzd.LumaCapture ]]
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$LUMA_VERIFY_APP/Contents/Info.plist")" ]]
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :NSScreenCaptureUsageDescription' "$LUMA_VERIFY_APP/Contents/Info.plist")" ]]
for architecture in arm64 x86_64; do
  deployment="$(otool -l -arch "$architecture" "$LUMA_VERIFY_BIN" | awk '/LC_BUILD_VERSION/{section=1;next} section && /minos/ && !found {print $2;found=1}')"
  [[ "$deployment" == 15.0 ]]
done
dependencies="$(otool -L "$LUMA_VERIFY_BIN")"
if printf '%s\n' "$dependencies" | awk '/^[[:space:]]/ {print $1}' | \
  awk '!/^\/System\/Library\// && !/^\/usr\/lib\// && !/^@rpath\/libswift/ {bad=1; print "Unexpected runtime dependency: " $0} END {exit !bad}'; then
  exit 1
fi
echo "Verified universal arm64 + x86_64 bundle, macOS $minimum, resources and signature."
