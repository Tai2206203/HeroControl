#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -miphoneos-version-min=17.0 -fobjc-arc -dynamiclib -fvisibility=hidden \
    -framework Foundation -install_name @rpath/HeroBackend.dylib \
    "$ROOT/BackendSDK/UnavailableBackend.m" -o "$ROOT/.build/HeroBackend.dylib"
echo "Built an unavailable-backend ABI example. It provides no kernel/game functionality."
