#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/.build/Diagnostics"
mkdir -p "$OUTPUT"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SOURCE="$ROOT/BackendSDK/DiagnosticBackend.m"
GENERATION="$(python3 "$ROOT/scripts/runtime-generation.py")"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
    -miphoneos-version-min=17.0 -fobjc-arc -dynamiclib -fvisibility=hidden \
    "-DHC_RUNTIME_GENERATION=\"$GENERATION\"" \
    -Wall -Wextra -Werror=implicit-function-declaration -framework Foundation -framework CoreFoundation -framework Security \
    -install_name @rpath/HeroBackend.dylib "$SOURCE" -o "$OUTPUT/HeroBackend.dylib"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
    -miphoneos-version-min=17.0 -fobjc-arc -DHC_DIAGNOSTIC_CLI \
    "-DHC_RUNTIME_GENERATION=\"$GENERATION\"" \
    -Wall -Wextra -Werror=implicit-function-declaration -framework Foundation -framework CoreFoundation -framework Security \
    "$SOURCE" -o "$OUTPUT/hero-kernel-check"
# Compile/run the same ABI implementation for the macOS host. The self-test
# never requests kernel primitives and verifies apply cannot be acknowledged.
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -fobjc-arc -DHC_DIAGNOSTIC_CLI -Wall -Wextra -framework Foundation -framework CoreFoundation -framework Security \
    "-DHC_RUNTIME_GENERATION=\"$GENERATION\"" \
    "$SOURCE" -o "$OUTPUT/diagnostic-host-tests"
"$OUTPUT/diagnostic-host-tests" --self-test
python3 "$ROOT/scripts/check-helper-fds.py" "$OUTPUT/diagnostic-host-tests"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -fobjc-arc -dynamiclib -fvisibility=hidden -Wall -Wextra \
    "-DHC_RUNTIME_GENERATION=\"$GENERATION\"" \
    -framework Foundation -framework CoreFoundation -framework Security \
    "$SOURCE" -o "$OUTPUT/diagnostic-contract.dylib"
xcrun --sdk macosx swiftc -parse-as-library \
    "$ROOT/HeroControl/Models.swift" "$ROOT/HeroControl/NativeBackend.swift" \
    "$ROOT/scripts/native-contract-check.swift" -o "$OUTPUT/native-contract-check"
"$OUTPUT/native-contract-check" "$OUTPUT/diagnostic-contract.dylib"
printf 'Built diagnostics backend and terminal tool: %s\n' "$OUTPUT"
