#!/bin/bash
set -euo pipefail
LUMA_VERIFY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUMA_VERIFY_APP="${1:-$LUMA_VERIFY_ROOT/dist/LumaCapture.app}"
LUMA_VERIFY_BIN="$LUMA_VERIFY_APP/Contents/MacOS/LumaCapture"
test -x "$LUMA_VERIFY_BIN"
test -s "$LUMA_VERIFY_APP/Contents/Resources/AppIcon.icns"
plutil -lint "$LUMA_VERIFY_APP/Contents/Info.plist"
lipo "$LUMA_VERIFY_BIN" -verify_arch arm64 x86_64
xattr -d com.apple.FinderInfo "$LUMA_VERIFY_APP" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "$LUMA_VERIFY_APP"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$LUMA_VERIFY_APP/Contents/Info.plist")"
[[ "$minimum" == 15.0 ]]
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
