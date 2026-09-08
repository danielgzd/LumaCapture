#!/bin/bash
# Shared build environment. Every compiler/package cache stays inside the project.
set -euo pipefail

LUMA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUMA_BUILD="${LUMA_BUILD_DIR:-$LUMA_ROOT/.build}"
mkdir -p "$LUMA_BUILD/module-cache" "$LUMA_BUILD/package-cache" \
  "$LUMA_BUILD/package-config" "$LUMA_BUILD/package-security"
export CLANG_MODULE_CACHE_PATH="$LUMA_BUILD/module-cache"
export SWIFT_MODULECACHE_PATH="$LUMA_BUILD/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$LUMA_BUILD/module-cache"

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'LumaCapture requires macOS and Apple developer tools.' >&2
  exit 1
fi

# Prefer a complete Xcode installation when the global selection is CLT.
# Respect an explicit DEVELOPER_DIR; never change the global xcode-select setting.
if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ "$(xcode-select -p)" == */CommandLineTools ]] \
  && [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
LUMA_SWIFTC="$(xcrun --find swiftc)"
LUMA_SWIFT="$(xcrun --find swift)"
LUMA_SDK="$(xcrun --sdk macosx --show-sdk-path)"
LUMA_DEPLOYMENT_TARGET=15.0

luma_sources() {
  local directory="$1"
  if command -v rg >/dev/null 2>&1; then
    rg --files "$directory" -g '*.swift' | LC_ALL=C sort
  else
    find "$directory" -name '*.swift' -type f | LC_ALL=C sort
  fi
}

luma_compile_core() {
  local architecture="$1"
  local destination="$2"
  local sources=()
  while IFS= read -r source; do sources+=("$source"); done < <(luma_sources "$LUMA_ROOT/Sources/LumaCaptureCore")
  mkdir -p "$destination"
  "$LUMA_SWIFTC" -swift-version 5 -parse-as-library -O -emit-library -static -emit-module \
    -module-name LumaCaptureCore -target "$architecture-apple-macosx$LUMA_DEPLOYMENT_TARGET" \
    -sdk "$LUMA_SDK" -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -emit-module-path "$destination/LumaCaptureCore.swiftmodule" \
    "${sources[@]}" -o "$destination/libLumaCaptureCore.a"
}
