#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

LUMA_VERSION="${VERSION:-0.1.0}"
LUMA_BUILD_NUMBER="${BUILD_NUMBER:-1}"
LUMA_SIGN_IDENTITY="${SIGN_IDENTITY:--}"
LUMA_REQUIRE_STABLE_SIGNATURE="${REQUIRE_STABLE_SIGNATURE:-0}"
LUMA_DMG=1
LUMA_ARCHIVE=1
LUMA_SELF_TEST=0
LUMA_APP_OUTPUT=''
LUMA_KEEP_STAGE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) LUMA_VERSION="${2:?A version is required}"; shift 2 ;;
    --no-dmg) LUMA_DMG=0; shift ;;
    --no-archive) LUMA_ARCHIVE=0; shift ;;
    --self-test) LUMA_SELF_TEST=1; shift ;;
    --app-output) LUMA_APP_OUTPUT="${2:?An output .app path is required}"; shift 2 ;;
    --help)
      echo 'Usage: scripts/build.sh [--version 0.1.0] [--no-dmg] [--no-archive] [--self-test] [--app-output /path/LumaCapture.app]'
      echo 'Environment: SIGN_IDENTITY (default ad-hoc), BUILD_NUMBER, LUMA_BUILD_DIR'
      echo '--no-archive retains the built app in a temporary directory unless --app-output is supplied.'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
if [[ ! "$LUMA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'Version must contain three numeric components, for example 0.1.0.' >&2
  exit 2
fi
if [[ ! "$LUMA_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo 'BUILD_NUMBER must be an integer.' >&2
  exit 2
fi
if [[ "$LUMA_REQUIRE_STABLE_SIGNATURE" == 1 && "$LUMA_SIGN_IDENTITY" == - ]]; then
  echo 'A stable signing identity is required for release builds. Set SIGN_IDENTITY to a Developer ID Application certificate.' >&2
  exit 2
fi
if [[ -n "$LUMA_APP_OUTPUT" ]] && { [[ "$LUMA_APP_OUTPUT" != /*.app ]] || [[ -e "$LUMA_APP_OUTPUT" ]]; }; then
  echo '--app-output must be an absolute, new .app path. Use a location outside iCloud Drive.' >&2
  exit 2
fi

LUMA_DIST="$LUMA_ROOT/dist"
# Assemble/sign outside iCloud Drive. Its file provider can immediately attach
# FinderInfo to a live .app directory, which strict code signing correctly rejects.
LUMA_STAGE_ROOT="$(mktemp -d /private/tmp/LumaCapture-build.XXXXXX)"
cleanup() { if [[ "$LUMA_KEEP_STAGE" == 0 ]]; then rm -rf "$LUMA_STAGE_ROOT"; fi; }
trap cleanup EXIT
LUMA_APP="$LUMA_STAGE_ROOT/LumaCapture.app"
mkdir -p "$LUMA_DIST" "$LUMA_BUILD/universal" "$LUMA_APP/Contents/MacOS" "$LUMA_APP/Contents/Resources"
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(luma_sources "$LUMA_ROOT/Sources/LumaCapture")
for architecture in arm64 x86_64; do
  destination="$LUMA_BUILD/universal/$architecture"
  echo "Building $architecture for macOS ${LUMA_DEPLOYMENT_TARGET}…"
  luma_compile_core "$architecture" "$destination"
  "$LUMA_SWIFTC" -swift-version 5 -parse-as-library -O \
    -module-name LumaCapture -target "$architecture-apple-macosx$LUMA_DEPLOYMENT_TARGET" \
    -sdk "$LUMA_SDK" -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$destination" -L "$destination" -lLumaCaptureCore \
    "${sources[@]}" -o "$destination/LumaCapture"
done
lipo -create "$LUMA_BUILD/universal/arm64/LumaCapture" "$LUMA_BUILD/universal/x86_64/LumaCapture" \
  -output "$LUMA_APP/Contents/MacOS/LumaCapture"
cp "$LUMA_ROOT/Resources/Info.plist" "$LUMA_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $LUMA_VERSION" "$LUMA_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $LUMA_BUILD_NUMBER" "$LUMA_APP/Contents/Info.plist"
printf 'APPL????' > "$LUMA_APP/Contents/PkgInfo"

"$LUMA_SWIFTC" -swift-version 5 -sdk "$LUMA_SDK" -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  "$LUMA_ROOT/scripts/generate-icon.swift" -o "$LUMA_BUILD/generate-icon"
"$LUMA_BUILD/generate-icon" "$LUMA_BUILD/AppIcon.iconset"
"$LUMA_SWIFTC" -swift-version 5 -sdk "$LUMA_SDK" -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  "$LUMA_ROOT/scripts/generate-icns.swift" -o "$LUMA_BUILD/generate-icns"
"$LUMA_BUILD/generate-icns" "$LUMA_BUILD/AppIcon.iconset" "$LUMA_APP/Contents/Resources/AppIcon.icns"

# iCloud workspaces may attach Finder/provenance xattrs to generated bundle files;
# code signing rejects those metadata forks even though they are not app content.
xattr -cr "$LUMA_APP"
signing_options=(--force --sign "$LUMA_SIGN_IDENTITY" --entitlements "$LUMA_ROOT/Resources/LumaCapture.entitlements")
if [[ "$LUMA_SIGN_IDENTITY" != - ]]; then
  signing_options+=(--options runtime --timestamp)
fi
codesign "${signing_options[@]}" "$LUMA_APP"
# The iCloud file provider may recreate an empty FinderInfo xattr while the
# signature directory appears. It is not product data and strict verification
# rejects it, so clear that one attribute after signing as well.
xattr -d com.apple.FinderInfo "$LUMA_APP" 2>/dev/null || true
"$LUMA_ROOT/scripts/verify-bundle.sh" "$LUMA_APP"
if [[ "$LUMA_REQUIRE_STABLE_SIGNATURE" == 1 ]]; then
  REQUIRE_STABLE_SIGNATURE=1 "$LUMA_ROOT/scripts/verify-bundle.sh" "$LUMA_APP"
fi
if [[ "$LUMA_SELF_TEST" == 1 ]]; then
  "$LUMA_APP/Contents/MacOS/LumaCapture" --self-test "$LUMA_BUILD/self-test"
fi

if [[ "$LUMA_ARCHIVE" == 1 ]]; then
  artifact_base="LumaCapture-$LUMA_VERSION-universal"
  zip_path="$LUMA_DIST/$artifact_base.zip"
  # ditto replaces the archive; do not append to a stale ZIP.
  [[ ! -e "$zip_path" ]] || rm "$zip_path"
  ditto -c -k --sequesterRsrc --keepParent "$LUMA_APP" "$zip_path"
  artifacts=("$artifact_base.zip")
  if [[ "$LUMA_DMG" == 1 ]]; then
    staging="$LUMA_STAGE_ROOT/dmg-staging"
    mkdir -p "$staging"
    ditto "$LUMA_APP" "$staging/LumaCapture.app"
    ln -s /Applications "$staging/Applications"
    hdiutil create -volname "LumaCapture $LUMA_VERSION" -srcfolder "$staging" \
      -ov -format UDZO -fs HFS+ "$LUMA_DIST/$artifact_base.dmg"
    artifacts+=("$artifact_base.dmg")
  fi
  (cd "$LUMA_DIST" && shasum -a 256 "${artifacts[@]}" > "$artifact_base.sha256")
  "$LUMA_ROOT/scripts/verify-artifacts.sh" "$LUMA_DIST" "$LUMA_VERSION"
  echo "Verified archives and checksums in $LUMA_DIST"
fi
if [[ -n "$LUMA_APP_OUTPUT" ]]; then
  mkdir -p "$(dirname "$LUMA_APP_OUTPUT")"
  ditto --noextattr --norsrc "$LUMA_APP" "$LUMA_APP_OUTPUT"
  "$LUMA_ROOT/scripts/verify-bundle.sh" "$LUMA_APP_OUTPUT"
  echo "App: $LUMA_APP_OUTPUT"
elif [[ "$LUMA_ARCHIVE" == 0 ]]; then
  LUMA_KEEP_STAGE=1
  echo "App: $LUMA_APP"
  echo "This temporary build directory is retained until you remove it: $LUMA_STAGE_ROOT"
fi
echo "Built and verified LumaCapture.app (signing identity: $LUMA_SIGN_IDENTITY)"
