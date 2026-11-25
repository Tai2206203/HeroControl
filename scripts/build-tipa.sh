#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend)
            [[ $# -ge 2 ]] || { echo "--backend requires a dylib path" >&2; exit 2; }
            BACKEND="$2"; shift 2 ;;
        *) echo "Usage: bash scripts/build-tipa.sh [--backend /absolute/path/HeroBackend.dylib]" >&2; exit 2 ;;
    esac
done
[[ "$(uname -s)" == Darwin ]] || { echo "Run this script on macOS with full Xcode, or use GitHub Actions." >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "Xcode is required." >&2; exit 1; }
xcrun --sdk iphoneos --show-sdk-path >/dev/null

if [[ -n "$BACKEND" ]]; then
    [[ -f "$BACKEND" ]] || { echo "Backend does not exist: $BACKEND" >&2; exit 1; }
    BACKEND="$(cd "$(dirname "$BACKEND")" && pwd)/$(basename "$BACKEND")"
    xcrun lipo -verify_arch arm64 "$BACKEND"
    PLATFORM_INFO="$(xcrun vtool -show-build "$BACKEND")"
    grep -Eq 'platform[[:space:]]+IOS([[:space:]]|$)' <<< "$PLATFORM_INFO" || {
        echo "Backend must declare the iPhoneOS platform." >&2; exit 1;
    }
    grep -Eq 'platform[[:space:]]+(IOSSIMULATOR|MACOS|MACCATALYST)' <<< "$PLATFORM_INFO" && {
        echo "Backend contains an incompatible platform slice." >&2; exit 1;
    }
    for SYMBOL in hc_backend_api_version hc_backend_request hc_backend_release; do
        xcrun nm -gU "$BACKEND" | awk '{print $NF}' | grep -x "_$SYMBOL" >/dev/null || {
            echo "Missing exported symbol: $SYMBOL" >&2; exit 1;
        }
    done
fi

mkdir -p "$ROOT/dist"
bash "$ROOT/scripts/build-diagnostics.sh"
if [[ -z "$BACKEND" ]]; then
    BACKEND="$ROOT/.build/Diagnostics/HeroBackend.dylib"
fi
bash "$ROOT/scripts/build-overlay.sh"
bash "$ROOT/scripts/build-runtime.sh"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/herocontrol.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
xcodebuild -project "$ROOT/HeroControl.xcodeproj" -scheme HeroControl \
    -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$ROOT/.build/DerivedData" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build

APP="$ROOT/.build/DerivedData/Build/Products/Release-iphoneos/HeroControl.app"
[[ -d "$APP" ]] || { echo "Built app not found: $APP" >&2; exit 1; }
mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/HeroControl.app"
mkdir -p "$STAGE/Payload/HeroControl.app/Tools" "$STAGE/Payload/HeroControl.app/Frameworks" "$STAGE/Payload/HeroControl.app/ThirdParty"
ditto "$ROOT/.build/Overlay/HeroOverlay.app" "$STAGE/Payload/HeroControl.app/Tools/HeroOverlay.app"
cp "$ROOT/.build/Overlay/HeroOverlayBridge.dylib" "$STAGE/Payload/HeroControl.app/Frameworks/"
cp "$ROOT/ThirdParty/oxorany/LICENSE" "$STAGE/Payload/HeroControl.app/ThirdParty/oxorany-LICENSE.txt"
cp "$ROOT/ThirdParty/TrollSpeed-LICENSE.txt" "$ROOT/ThirdParty/NOTICE.txt" "$STAGE/Payload/HeroControl.app/ThirdParty/"
mkdir -p "$STAGE/Payload/HeroControl.app/Runtime"
cp "$ROOT/Runtime/Payload/"* "$STAGE/Payload/HeroControl.app/Runtime/"
cp "$ROOT/Runtime/Runtime.lua" "$ROOT/Runtime/HeroControlRuntime.plist" \
    "$ROOT/.build/Runtime/HeroControlRuntime.dylib" "$STAGE/Payload/HeroControl.app/Runtime/"
codesign --force --sign - --entitlements "$ROOT/Signing/Overlay.entitlements" \
    "$STAGE/Payload/HeroControl.app/Tools/HeroOverlay.app"
if [[ -n "$BACKEND" ]]; then
    mkdir -p "$STAGE/Payload/HeroControl.app/Frameworks"
    cp "$BACKEND" "$STAGE/Payload/HeroControl.app/Frameworks/HeroBackend.dylib"
fi
if [[ -f "$ROOT/.build/Diagnostics/hero-kernel-check" ]]; then
    mkdir -p "$STAGE/Payload/HeroControl.app/Tools"
    cp "$ROOT/.build/Diagnostics/hero-kernel-check" "$STAGE/Payload/HeroControl.app/Tools/hero-kernel-check"
    chmod 755 "$STAGE/Payload/HeroControl.app/Tools/hero-kernel-check"
    codesign --force --sign - --entitlements "$ROOT/Signing/Helper.entitlements" \
        "$STAGE/Payload/HeroControl.app/Tools/hero-kernel-check"
fi

# Embed explicit entitlement requests. The on-device installer/jailbreak must
# preserve and honor them; a successful build alone does not prove access.
while IFS= read -r -d '' FILE; do
    codesign --force --sign - "$FILE"
done < <(find "$STAGE/Payload/HeroControl.app" -type f -name '*.dylib' -print0)
codesign --force --sign - --entitlements "$ROOT/Signing/App.entitlements" "$STAGE/Payload/HeroControl.app"
codesign --verify --deep --strict "$STAGE/Payload/HeroControl.app"
python3 "$ROOT/scripts/verify-entitlements.py" "$STAGE/Payload/HeroControl.app" \
    --output "$ROOT/dist/signing-report.json"
OUTPUT="$ROOT/dist/DORO-CHEAT.tipa"
# zip can append entries to an existing archive; always create a fresh archive.
(cd "$STAGE" && /usr/bin/zip -qry "$STAGE/DORO-CHEAT.tipa" Payload)
mv -f "$STAGE/DORO-CHEAT.tipa" "$OUTPUT"
/usr/bin/unzip -t "$OUTPUT"
/usr/bin/shasum -a 256 "$OUTPUT" > "$ROOT/dist/DORO-CHEAT.tipa.sha256"
printf '\nBuilt: %s\n' "$OUTPUT"
printf 'Backend bundled: %s\n' "$BACKEND"
printf 'The default diagnostics backend does not implement game functions. Device testing is required.\n'
