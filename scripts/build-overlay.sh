#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/.build/Overlay"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$OUTPUT/HeroOverlay.app"
python3 "$ROOT/scripts/generate-overlay-features.py" "$OUTPUT/HCFeatures.h"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
    -miphoneos-version-min=17.0 -fobjc-arc -Wall -Wextra \
    -Werror=implicit-function-declaration -I"$OUTPUT" \
    -framework Foundation -framework UIKit -framework QuartzCore \
    "$ROOT/Overlay/HeroOverlay.m" -o "$OUTPUT/HeroOverlay.app/hero-overlay"
cp "$ROOT/Overlay/Info.plist" "$OUTPUT/HeroOverlay.app/Info.plist"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
    -miphoneos-version-min=17.0 -fobjc-arc -Wall -Wextra -dynamiclib -fvisibility=hidden \
    -framework Foundation -install_name @rpath/HeroOverlayBridge.dylib \
    "$ROOT/Overlay/OverlayBridge.m" -o "$OUTPUT/HeroOverlayBridge.dylib"
# Also exercise invalid input/unsupported-host responses of the actual ABI.
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -fobjc-arc -dynamiclib -fvisibility=hidden -framework Foundation \
    "$ROOT/Overlay/OverlayBridge.m" -o "$OUTPUT/overlay-host.dylib"
python3 "$ROOT/scripts/check-overlay-bridge.py" "$OUTPUT/overlay-host.dylib"
printf 'Built independent Hero Control overlay: %s\n' "$OUTPUT"
