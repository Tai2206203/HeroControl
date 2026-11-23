#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/.build/Diagnostics"
mkdir -p "$OUTPUT"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SOURCE="$ROOT/BackendSDK/DiagnosticBackend.m"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
    -miphoneos-version-min=17.0 -fobjc-arc -dynamiclib -fvisibility=hidden \
    -Wall -Wextra -Werror=implicit-function-declaration -framework Foundation \
    -install_name @rpath/HeroBackend.dylib "$SOURCE" -o "$OUTPUT/HeroBackend.dylib"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
    -miphoneos-version-min=17.0 -fobjc-arc -DHC_DIAGNOSTIC_CLI \
    -Wall -Wextra -Werror=implicit-function-declaration -framework Foundation \
    "$SOURCE" -o "$OUTPUT/hero-kernel-check"
# Compile/run the same ABI implementation for the macOS host. The self-test
# never requests kernel primitives and verifies apply cannot be acknowledged.
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -fobjc-arc -DHC_DIAGNOSTIC_CLI -Wall -Wextra -framework Foundation \
    "$SOURCE" -o "$OUTPUT/diagnostic-host-tests"
"$OUTPUT/diagnostic-host-tests" --self-test
printf 'Built diagnostics backend and terminal tool: %s\n' "$OUTPUT"
