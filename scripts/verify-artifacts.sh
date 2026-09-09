#!/bin/bash
# Verify distributable bytes, then inspect the app recovered from the ZIP.
set -euo pipefail
LUMA_VERIFY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUMA_VERIFY_DIST="${1:-$LUMA_VERIFY_ROOT/dist}"
LUMA_VERIFY_VERSION="${2:-${VERSION:-0.1.0}}"
[[ "$LUMA_VERIFY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid version.' >&2; exit 2; }
LUMA_VERIFY_BASE="LumaCapture-$LUMA_VERIFY_VERSION-universal"
LUMA_VERIFY_STAGE="$(mktemp -d /private/tmp/LumaCapture-verify.XXXXXX)"
trap 'rm -rf "$LUMA_VERIFY_STAGE"' EXIT

(cd "$LUMA_VERIFY_DIST" && shasum -a 256 -c "$LUMA_VERIFY_BASE.sha256")
ditto -x -k --noextattr --norsrc "$LUMA_VERIFY_DIST/$LUMA_VERIFY_BASE.zip" "$LUMA_VERIFY_STAGE"
"$LUMA_VERIFY_ROOT/scripts/verify-bundle.sh" "$LUMA_VERIFY_STAGE/LumaCapture.app"
actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$LUMA_VERIFY_STAGE/LumaCapture.app/Contents/Info.plist")"
[[ "$actual_version" == "$LUMA_VERIFY_VERSION" ]]
if [[ -e "$LUMA_VERIFY_DIST/$LUMA_VERIFY_BASE.dmg" ]]; then
  hdiutil verify "$LUMA_VERIFY_DIST/$LUMA_VERIFY_BASE.dmg"
fi
echo "Verified ZIP readback, release version and SHA-256 for $LUMA_VERIFY_VERSION."
