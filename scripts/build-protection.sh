#!/bin/bash
# Sourced by native build scripts. No network access during builds.
hc_build_protection() {
    local sdk="$1" group="$2" object="$3"
    shift 3
    mkdir -p "$(dirname "$object")"
    xcrun --sdk "$sdk" clang++ -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
        -std=c++17 -O2 -fvisibility=hidden -fvisibility-inlines-hidden \
        "-DHC_OBF_GROUP_$group" "$@" -c "$ROOT/Protection/ProtectedStrings.cpp" -o "$object"
    # Separate translation unit keeps upstream opaque predicates opaque; no LTO.
    xcrun --sdk "$sdk" clang++ -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
        -std=c++17 -O2 -fvisibility=hidden -include cstddef "$@" \
        -c "$ROOT/ThirdParty/oxorany/oxorany.cpp" -o "$object.opaque.o"
    python3 "$ROOT/scripts/verify-protection.py" --group "$group" "$object"
}
