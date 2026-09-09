#!/bin/bash
# Repeatable synthetic 4K benchmark; never reads the user's screen or photos.
set -euo pipefail
source "$(dirname "$0")/common.sh"
LUMA_BENCH_OUTPUT="${1:-$LUMA_BUILD/benchmarks}"
mkdir -p "$LUMA_BENCH_OUTPUT"
"$LUMA_SWIFTC" -swift-version 5 -parse-as-library -O \
  -sdk "$LUMA_SDK" -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  "$LUMA_ROOT/Sources/LumaCapture/Editor/EditorModel.swift" \
  "$LUMA_ROOT/scripts/benchmark-editor.swift" -o "$LUMA_BUILD/benchmark-editor"
"$LUMA_BUILD/benchmark-editor" "$LUMA_BENCH_OUTPUT"
