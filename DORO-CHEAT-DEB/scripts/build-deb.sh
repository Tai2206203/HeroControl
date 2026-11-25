#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${1:-roothide}"
case "$SCHEME" in rootless|rootful|roothide) ;; *) echo "Usage: bash scripts/build-deb.sh [roothide|rootless|rootful]" >&2;exit 2;; esac
[[ "$(uname -s)" == Darwin ]] || { echo "A macOS host with Xcode is required to compile the iOS app; use the DEB GitHub workflow." >&2;exit 1; }
python3 "$ROOT/scripts/validate-project.py"
python3 "$ROOT/scripts/verify-protection.py"
python3 "$ROOT/scripts/verify-runtime-payload.py"
python3 "$ROOT/scripts/source-manifest.py"
mkdir -p "$ROOT/.build" "$ROOT/dist"
bash "$ROOT/scripts/build-diagnostics.sh"
bash "$ROOT/scripts/build-overlay.sh"
bash "$ROOT/scripts/build-runtime.sh"
xcodebuild -project "$ROOT/HeroControl.xcodeproj" -scheme HeroControl \
    -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$ROOT/.build/DerivedData" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
STAGE="$(mktemp -d "$ROOT/.build/deb-stage.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
APP="$STAGE/DORO-CHEAT-DEB.app"
ditto "$ROOT/.build/DerivedData/Build/Products/Release-iphoneos/HeroControl.app" "$APP"
mkdir -p "$APP/Tools" "$APP/Frameworks" "$APP/Runtime" "$APP/ThirdParty"
ditto "$ROOT/.build/Overlay/HeroOverlay.app" "$APP/Tools/HeroOverlay.app"
cp "$ROOT/.build/Overlay/HeroOverlayBridge.dylib" "$ROOT/.build/Diagnostics/HeroBackend.dylib" "$APP/Frameworks/"
cp "$ROOT/.build/Diagnostics/hero-kernel-check" "$APP/Tools/"
cp "$ROOT/Runtime/Payload/"* "$APP/Runtime/"
cp "$ROOT/Runtime/Runtime.lua" "$ROOT/Runtime/DoroCheatDebRuntime.plist" "$ROOT/.build/Runtime/DoroCheatDebRuntime.dylib" "$APP/Runtime/"
cp "$ROOT/ThirdParty/TrollSpeed-LICENSE.txt" "$ROOT/ThirdParty/NOTICE.txt" "$APP/ThirdParty/"
cp "$ROOT/ThirdParty/oxorany/LICENSE" "$APP/ThirdParty/oxorany-LICENSE.txt"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -miphoneos-version-min=15.0 -fobjc-arc -framework Foundation "$ROOT/Debian/DebControl.m" -o "$APP/Tools/deb-control"
chmod 755 "$APP/Tools/hero-kernel-check" "$APP/Tools/deb-control"
while IFS= read -r -d '' FILE; do codesign --force --sign - "$FILE";done < <(find "$APP" -type f -name '*.dylib' -print0)
codesign --force --sign - --entitlements "$ROOT/Signing/Helper.entitlements" "$APP/Tools/deb-control"
codesign --force --sign - --entitlements "$ROOT/Signing/Helper.entitlements" "$APP/Tools/hero-kernel-check"
codesign --force --sign - --entitlements "$ROOT/Signing/Overlay.entitlements" "$APP/Tools/HeroOverlay.app"
codesign --force --sign - --entitlements "$ROOT/Signing/App.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
python3 "$ROOT/scripts/verify-entitlements.py" "$APP" --output "$ROOT/dist/signing-report-$SCHEME.json"
case "$SCHEME" in rootless) ARCH=iphoneos-arm64;; rootful) ARCH=iphoneos-arm;; roothide) ARCH=iphoneos-arm64e;;esac
VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$ROOT/Debian/package.json")"
python3 "$ROOT/scripts/package-deb.py" "$APP" --scheme "$SCHEME" --output "$ROOT/dist/doro-cheat-deb_${VERSION}_${ARCH}.deb"
python3 "$ROOT/scripts/source-archive.py"
