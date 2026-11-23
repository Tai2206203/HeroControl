#!/usr/bin/env python3
"""Verify the entitlement requests embedded in the packaged Mach-O signatures."""
import argparse
import json
import plistlib
import subprocess
from pathlib import Path


def read_entitlements(path):
    proc = subprocess.run(["codesign", "--display", "--entitlements", ":-", str(path)],
                          check=True, capture_output=True)
    payload = proc.stdout
    start = payload.find(b"<?xml")
    if start < 0:
        start = payload.find(b"<plist")
    if start < 0:
        raise RuntimeError("codesign returned no entitlement plist")
    return plistlib.loads(payload[start:])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    result = {}
    for label, binary, expected_file in [
        ("app", args.app, root / "Signing/App.entitlements"),
        ("helper", args.app / "Tools/hero-kernel-check", root / "Signing/Helper.entitlements"),
    ]:
        if not binary.exists():
            if label == "helper":
                result[label] = {"present": False}
                continue
            raise RuntimeError("Packaged app is missing")
        expected = plistlib.loads(expected_file.read_bytes())
        actual = read_entitlements(binary)
        missing = [key for key, value in expected.items() if actual.get(key) is not value]
        if missing:
            raise RuntimeError("Missing requested " + label + " entitlements: " + ", ".join(missing))
        result[label] = {"present": True, "requestedEntitlementsVerified": actual}
    result["note"] = "Signature contents verified only; runtime granting must be checked on the device."
    args.output.write_text(json.dumps(result, indent=2), encoding="utf8")
    print("Packaged app/helper entitlement requests verified.")


if __name__ == "__main__":
    main()
