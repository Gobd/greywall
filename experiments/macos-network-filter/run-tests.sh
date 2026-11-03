#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/tmp
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
options=(--disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security")
swift test "${options[@]}"
# SwiftPM's Xcode and native build backends use different product directories.
probe=$(find .build -type f -name network-probe -perm -111 | head -n 1)
if [ -z "$probe" ]; then echo "network-probe executable missing" >&2; exit 1; fi
"$probe" ancestry
# Read-only preflight is intentionally separate; missing entitlements are not a unit-test failure.
if [ "${1:-}" = "--preflight" ]; then "$probe" preflight; fi
