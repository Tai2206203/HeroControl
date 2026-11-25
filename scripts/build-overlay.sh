#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/.build/Overlay"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
GENERATION="$(python3 "$ROOT/scripts/runtime-generation.py")"
mkdir -p "$OUTPUT/HeroOverlay.app"
python3 "$ROOT/scripts/generate-overlay-features.py" "$OUTPUT/HCFeatures.h"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
    -miphoneos-version-min=17.0 -fobjc-arc -Wall -Wextra \
    -Werror=implicit-function-declaration -I"$OUTPUT" \
    "-DHC_RUNTIME_GENERATION=\"$GENERATION\"" \
    -framework Foundation -framework CoreFoundation -framework UIKit -framework QuartzCore -framework CoreGraphics -framework ImageIO \
    "$ROOT/Overlay/HeroOverlay.m" "$ROOT/Overlay/CameraEngine.m" -o "$OUTPUT/HeroOverlay.app/hero-overlay"
cp "$ROOT/Overlay/Info.plist" "$OUTPUT/HeroOverlay.app/Info.plist"
ditto "$ROOT/Assets/HeroIcons" "$OUTPUT/HeroOverlay.app/HeroIcons"
ditto "$ROOT/Assets/Theme" "$OUTPUT/HeroOverlay.app/Theme"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
    -miphoneos-version-min=17.0 -fobjc-arc -Wall -Wextra -dynamiclib -fvisibility=hidden \
    "-DHC_RUNTIME_GENERATION=\"$GENERATION\"" \
    -framework Foundation -install_name @rpath/HeroOverlayBridge.dylib \
    "$ROOT/Overlay/OverlayBridge.m" -o "$OUTPUT/HeroOverlayBridge.dylib"
# Compile and exercise the actual preparation preflight without an iPhone/helper.
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -fobjc-arc -Wall -Wextra -Werror=implicit-function-declaration -framework Foundation \
    "$ROOT/scripts/reports-preparation-check.m" -o "$OUTPUT/reports-preparation-check"
"$OUTPUT/reports-preparation-check"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -fobjc-arc -Wall -Wextra -I"$OUTPUT" -framework Foundation \
    "$ROOT/scripts/settings-store-check.m" -o "$OUTPUT/settings-store-check"
"$OUTPUT/settings-store-check"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -std=c11 -Wall -Wextra -Werror "$ROOT/scripts/drawer-motion-check.c" -o "$OUTPUT/drawer-motion-check"
"$OUTPUT/drawer-motion-check"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -fobjc-arc -Wall -Wextra -framework Foundation "$ROOT/scripts/report-notice-check.m" -o "$OUTPUT/report-notice-check"
"$OUTPUT/report-notice-check"
# Also exercise invalid input/unsupported-host responses of the actual ABI.
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -fobjc-arc -dynamiclib -fvisibility=hidden -framework Foundation \
    "$ROOT/Overlay/OverlayBridge.m" -o "$OUTPUT/overlay-host.dylib"
python3 "$ROOT/scripts/check-overlay-bridge.py" "$OUTPUT/overlay-host.dylib"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -Wall -Wextra -Werror "$ROOT/scripts/overlay-lock-check.c" -o "$OUTPUT/overlay-lock-check"
python3 "$ROOT/scripts/check-overlay-lock.py" "$OUTPUT/overlay-lock-check"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -Wall -Wextra -Werror "$ROOT/scripts/camera-memory-check.c" -o "$OUTPUT/camera-memory-check"
"$OUTPUT/camera-memory-check"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -Wall -Wextra -Werror "$ROOT/scripts/esp-memory-check.c" -o "$OUTPUT/esp-memory-check"
"$OUTPUT/esp-memory-check"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -Wall -Wextra -Werror "$ROOT/scripts/esp-presentation-check.c" -o "$OUTPUT/esp-presentation-check"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -Wall -Wextra -Werror "$ROOT/scripts/minimap-check.c" -o "$OUTPUT/minimap-check"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -Wall -Wextra -Werror "$ROOT/scripts/esp-visual-check.c" -o "$OUTPUT/esp-visual-check"
"$OUTPUT/esp-visual-check"
"$OUTPUT/minimap-check"
"$OUTPUT/esp-presentation-check"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -Wall -Wextra -Werror "$ROOT/scripts/logic-esp-check.c" -o "$OUTPUT/logic-esp-check"
"$OUTPUT/logic-esp-check"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -Wall -Wextra -Werror "$ROOT/scripts/lua-reports-check.c" -o "$OUTPUT/lua-reports-check"
"$OUTPUT/lua-reports-check"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -Wall -Wextra -Werror "$ROOT/scripts/remote-cstring-check.c" -o "$OUTPUT/remote-cstring-check"
"$OUTPUT/remote-cstring-check"
printf 'Built independent Hero Control overlay: %s\n' "$OUTPUT"
