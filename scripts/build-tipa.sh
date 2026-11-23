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
    if xcrun vtool -show-build "$BACKEND" | grep 'platform IOSSIMULATOR' >/dev/null; then
        echo "Simulator dylibs cannot run on an iPhone." >&2; exit 1
    fi
    for SYMBOL in hc_backend_api_version hc_backend_request hc_backend_release; do
        xcrun nm -gU "$BACKEND" | awk '{print $NF}' | grep -x "_$SYMBOL" >/dev/null || {
            echo "Missing exported symbol: $SYMBOL" >&2; exit 1;
        }
    done
fi

mkdir -p "$ROOT/dist"
if [[ -z "$BACKEND" ]]; then
    bash "$ROOT/scripts/build-diagnostics.sh"
    BACKEND="$ROOT/.build/Diagnostics/HeroBackend.dylib"
fi
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
if [[ -n "$BACKEND" ]]; then
    mkdir -p "$STAGE/Payload/HeroControl.app/Frameworks"
    cp "$BACKEND" "$STAGE/Payload/HeroControl.app/Frameworks/HeroBackend.dylib"
fi
if [[ -f "$ROOT/.build/Diagnostics/hero-kernel-check" ]]; then
    mkdir -p "$STAGE/Payload/HeroControl.app/Tools"
    cp "$ROOT/.build/Diagnostics/hero-kernel-check" "$STAGE/Payload/HeroControl.app/Tools/hero-kernel-check"
    chmod 755 "$STAGE/Payload/HeroControl.app/Tools/hero-kernel-check"
    codesign --force --sign - "$STAGE/Payload/HeroControl.app/Tools/hero-kernel-check"
fi

# Ad-hoc signatures describe the bundle; the device installer must supply the
# installation/signing mechanism. This does not grant entitlements or kernel access.
while IFS= read -r -d '' FILE; do
    codesign --force --sign - "$FILE"
done < <(find "$STAGE/Payload/HeroControl.app" -type f -name '*.dylib' -print0)
codesign --force --sign - "$STAGE/Payload/HeroControl.app"
codesign --verify --deep --strict "$STAGE/Payload/HeroControl.app"
OUTPUT="$ROOT/dist/HeroControl.tipa"
# zip can append entries to an existing archive; always create a fresh archive.
(cd "$STAGE" && /usr/bin/zip -qry "$STAGE/HeroControl.tipa" Payload)
mv -f "$STAGE/HeroControl.tipa" "$OUTPUT"
/usr/bin/unzip -t "$OUTPUT"
/usr/bin/shasum -a 256 "$OUTPUT" > "$ROOT/dist/HeroControl.tipa.sha256"
printf '\nBuilt: %s\n' "$OUTPUT"
printf 'Backend bundled: %s\n' "$BACKEND"
printf 'The default diagnostics backend does not implement game functions. Device testing is required.\n'
