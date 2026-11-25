#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/.build/Runtime"
mkdir -p "$OUTPUT"
python3 "$ROOT/scripts/verify-runtime-payload.py"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
GENERATION="$(python3 "$ROOT/scripts/runtime-generation.py")"
source "$ROOT/scripts/build-protection.sh"
hc_build_protection iphoneos RUNTIME "$OUTPUT/protected-ios.o" -arch arm64 -miphoneos-version-min=15.0
xcrun --sdk iphoneos clang++ -arch arm64 -isysroot "$SDK" \
    -miphoneos-version-min=15.0 -std=c++17 -fobjc-arc -fexceptions -fcxx-exceptions \
    -dynamiclib -fvisibility=hidden -Wall -Wextra -Werror=implicit-function-declaration \
    "-DHC_RUNTIME_GENERATION=\"$GENERATION\"" \
    -framework Foundation -framework CoreFoundation -install_name @rpath/DoroCheatDebRuntime.dylib \
    "$ROOT/Runtime/GameRuntime.mm" "$OUTPUT/protected-ios.o" "$OUTPUT/protected-ios.o.opaque.o" -Wl,-x -o "$OUTPUT/DoroCheatDebRuntime.dylib"
printf 'Built bundled game-process adapter: %s\n' "$OUTPUT/DoroCheatDebRuntime.dylib"

python3 "$ROOT/scripts/verify-protection.py" --group RUNTIME "$OUTPUT/DoroCheatDebRuntime.dylib"
