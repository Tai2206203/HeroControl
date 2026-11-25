#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_ID="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)
for runtime, devices in d["devices"].items():
    if ".iOS-" not in runtime: continue
    for x in devices:
        if x["name"].startswith("iPhone"):
            print(x["udid"]); sys.exit(0)
sys.exit("No available iPhone Simulator. Install an iOS simulator runtime in Xcode Settings > Components.")
')"
xcodebuild -project "$ROOT/HeroControl.xcodeproj" -scheme HeroControl \
    -configuration Debug -destination "platform=iOS Simulator,id=$DEVICE_ID" \
    -derivedDataPath "$ROOT/.build/Simulator" \
    CODE_SIGNING_ALLOWED=NO test
