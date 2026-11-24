#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/.build/Runtime"
mkdir -p "$OUTPUT"
python3 "$ROOT/scripts/verify-runtime-payload.py"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
GENERATION="$(python3 "$ROOT/scripts/runtime-generation.py")"
xcrun --sdk iphoneos clang++ -arch arm64 -isysroot "$SDK" \
    -miphoneos-version-min=17.0 -std=c++17 -fobjc-arc -fexceptions -fcxx-exceptions \
    -dynamiclib -fvisibility=hidden -Wall -Wextra -Werror=implicit-function-declaration \
    "-DHC_RUNTIME_GENERATION=\"$GENERATION\"" \
    -framework Foundation -framework CoreFoundation -install_name @rpath/HeroControlRuntime.dylib \
    "$ROOT/Runtime/GameRuntime.mm" -o "$OUTPUT/HeroControlRuntime.dylib"
printf 'Built bundled game-process adapter: %s\n' "$OUTPUT/HeroControlRuntime.dylib"
