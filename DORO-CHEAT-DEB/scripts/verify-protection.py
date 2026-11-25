#!/usr/bin/env python3
"""Verify pinned oxorany bytes, native wiring and absence of selected plaintext."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex

ROOT = Path(__file__).resolve().parent.parent
GROUPS = ("BACKEND", "OVERLAY", "RUNTIME")

def entries():
    text = (ROOT / "Protection/ProtectedStrings.def").read_text("utf8")
    result = [(g, n, json.loads(v)) for g, n, v in re.findall(
        r'^HC_STRING\((\w+), (\w+), ("(?:[^"\\]|\\.)*")\)$', text, re.M)]
    if len(result) != text.count("HC_STRING(") or len({n for _, n, _ in result}) != len(result):
        raise ValueError("Invalid or duplicate protected string registry")
    return result

def plaintext_leaks(data, group):
    # Inspect complete printable string tokens, not suffixes of exported imports
    # such as _mach_vm_read_overwrite, which the dynamic loader needs unchanged.
    strings = set(re.findall(rb"[\x20-\x7e]+", data))
    return [name for g, name, value in entries() if g in ("COMMON", group)
            and value.encode("utf8") in strings]

def verify_platform_links(script):
    """Every protected object and predicate object must match the link SDK."""
    objects = {}
    for line in script.replace("\\\n", " ").splitlines():
        tokens = shlex.split(line, comments=True)
        if not tokens:
            continue
        if tokens[0] == "hc_build_protection" and len(tokens) >= 4:
            sdk, output = tokens[1], tokens[3]
            for name in (output, output + ".opaque.o"):
                if name in objects and objects[name] != sdk:
                    raise ValueError("Protected object reused across SDKs: " + name)
                objects[name] = sdk
        if len(tokens) >= 4 and tokens[:2] == ["xcrun", "--sdk"] and tokens[3] in ("clang", "clang++"):
            sdk = tokens[2]
            for token in tokens[4:]:
                if token in objects and objects[token] != sdk:
                    raise ValueError("SDK mismatch: " + token + " built for " + objects[token] + " linked for " + sdk)

def verify_sources():
    vendor = ROOT / "ThirdParty/oxorany"
    provenance = json.loads((vendor / "provenance.json").read_text("utf8"))
    for name, expected in provenance["files"].items():
        if hashlib.sha256((vendor / name).read_bytes()).hexdigest() != expected:
            raise ValueError("oxorany source hash mismatch: " + name)
    source_groups = {"BACKEND": ["BackendSDK/DiagnosticBackend.m", "Overlay/OverlayBridge.m", "BackendSDK/GameInspection.h"],
                     "OVERLAY": ["Overlay/HeroOverlay.m", "Overlay/CameraEngine.m", "BackendSDK/GameInspection.h"],
                     "RUNTIME": ["Runtime/GameRuntime.mm"]}
    registered = {n: g for g, n, _ in entries()}
    for group, names in source_groups.items():
        script = (ROOT / ("scripts/build-" + {"BACKEND": "diagnostics", "OVERLAY": "overlay", "RUNTIME": "runtime"}[group] + ".sh")).read_text("utf8")
        verify_platform_links(script)
        if "hc_build_protection iphoneos " + group not in script or '"$OUTPUT/protected-ios.o"' not in script or '"$OUTPUT/protected-ios.o.opaque.o"' not in script:
            raise ValueError("Missing protected object build/link: " + group)
        for name in names:
            text = (ROOT / name).read_text("utf8")
            for identifier in re.findall(r'HCProtected(?:CStr|Str)ing\((\w+)\)', text):
                if registered.get(identifier) not in ("COMMON", group):
                    raise ValueError("Wrong string group: " + identifier)
            for g, _, value in entries():
                if g in ("COMMON", group) and json.dumps(value, ensure_ascii=False) in text:
                    raise ValueError("Selected literal left unprotected: " + name)
    protection = (ROOT / "Protection/ProtectedStrings.cpp").read_text("utf8")
    if '#error Release string protection must not be disabled' not in protection:
        raise ValueError("Release disable guard missing")
    if "oxorany-LICENSE.txt" not in (ROOT / "scripts/build-deb.sh").read_text("utf8"):
        raise ValueError("Packaged license missing")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--group", choices=GROUPS)
    parser.add_argument("binaries", nargs="*", type=Path)
    args = parser.parse_args()
    verify_sources()
    if args.binaries and not args.group:
        parser.error("--group required when checking binaries")
    for binary in args.binaries:
        if not binary.is_file() or not binary.stat().st_size:
            raise ValueError("Missing/empty binary: " + str(binary))
        leaks = plaintext_leaks(binary.read_bytes(), args.group)
        if leaks:
            raise ValueError("Protected plaintext remains in " + str(binary) + ": " + ", ".join(leaks))
        print("Protected binary passed:", binary.name, args.group)
    print("oxorany provenance and native wiring passed:", len(entries()), "selected constants")

if __name__ == "__main__":
    main()
