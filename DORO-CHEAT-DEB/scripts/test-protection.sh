#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/.build/ProtectionTests"
mkdir -p "$OUTPUT"
source "$ROOT/scripts/build-protection.sh"
for GROUP in BACKEND OVERLAY RUNTIME; do
    hc_build_protection macosx "$GROUP" "$OUTPUT/$GROUP.o"
    xcrun --sdk macosx clang++ -std=c++17 -O2 -pthread "-DHC_OBF_GROUP_$GROUP" \
        "$ROOT/scripts/protected-strings-check.cpp" "$OUTPUT/$GROUP.o" "$OUTPUT/$GROUP.o.opaque.o" -o "$OUTPUT/$GROUP-check"
    "$OUTPUT/$GROUP-check"
done
# _DEBUG would disable upstream oxorany: release protection must fail closed.
if xcrun --sdk macosx clang++ -std=c++17 -D_DEBUG -DHC_OBF_GROUP_RUNTIME \
    -fsyntax-only "$ROOT/Protection/ProtectedStrings.cpp" 2>"$OUTPUT/debug-guard.txt"; then
    echo "Protection disable guard unexpectedly accepted _DEBUG" >&2
    exit 1
fi
grep -q 'Release string protection must not be disabled' "$OUTPUT/debug-guard.txt"
