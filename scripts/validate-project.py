#!/usr/bin/env python3
"""Portable project/ABI/package wiring checks; does not replace an Xcode build."""
from pathlib import Path
import json
import plistlib
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
project = (root / 'HeroControl.xcodeproj/project.pbxproj').read_text('utf8')
definitions = re.findall(r'^([0-9A-F]{24}) = \{', project, re.M)
references = set(re.findall(r'\b[0-9A-F]{24}\b', project))
assert len(definitions) == len(set(definitions)), 'Duplicate PBX object ID'
assert references <= set(definitions), 'Dangling PBX references'
for file in (root / 'HeroControl').glob('*.swift'):
    assert f'path = "{file.name}";' in project, f'Source missing from project: {file.name}'
for file in (root / 'HeroControlTests').glob('*.swift'):
    assert f'path = "{file.name}";' in project, f'Test missing from project: {file.name}'
info = plistlib.loads((root / 'HeroControl/Info.plist').read_bytes())
assert info['CFBundlePackageType'] == 'APPL'
scheme = ET.parse(root / 'HeroControl.xcodeproj/xcshareddata/xcschemes/HeroControl.xcscheme')
assert scheme.find('.//TestableReference/BuildableReference') is not None
for ref in scheme.findall('.//BuildableReference'):
    assert ref.attrib['BlueprintIdentifier'] in definitions
models = (root / 'HeroControl/Models.swift').read_text('utf8')
keys = re.findall(r'\.init\(key: "([^"]+)"', models)
assert len(keys) == 10 and len(set(keys)) == 10
expected = [
    '__ifxEnemyEspEnabledV1', 'HeroControl.ESP.HeroID', 'DoroCheat.Reference.R1.Box', 'DoroCheat.Reference.R1.Icon',
    'DoroCheat.Reference.R1.HP', 'DoroCheat.Reference.R1.Map', 'DoroCheat.Reference.R1.Unseen',
    'DoroCheat.Reference.R1.Check', 'DoroCheat.Style.Banner',
    'reports.enabled'
]
assert keys == expected
backend = (root / 'HeroControl/NativeBackend.swift').read_text('utf8')
header = (root / 'BackendSDK/HeroBackend.h').read_text('utf8')
example = (root / 'BackendSDK/UnavailableBackend.m').read_text('utf8')
for symbol in ['hc_backend_api_version', 'hc_backend_request', 'hc_backend_release']:
    assert all(symbol in text for text in [backend, header, example])
assert '@"connected": @NO' in example
assert 'CODE_SIGNING_ALLOWED=NO' in (root / 'scripts/build-tipa.sh').read_text('utf8')
app_entitlements = plistlib.loads((root / 'Signing/App.entitlements').read_bytes())
helper_entitlements = plistlib.loads((root / 'Signing/Helper.entitlements').read_bytes())
assert app_entitlements.get('com.apple.private.security.no-sandbox') is True
assert app_entitlements.get('com.apple.private.persona-mgmt') is True
assert helper_entitlements.get('com.apple.private.security.no-container') is True
assert helper_entitlements.get('com.apple.private.security.storage.AppBundles') is True
assert helper_entitlements.get('task_for_pid-allow') is True
assert helper_entitlements.get('com.apple.system-task-ports') is True
assert helper_entitlements.get('com.apple.security.exception.iokit-user-client-class') == ['IOSurfaceRootUserClient']
overlay_entitlements = plistlib.loads((root / 'Signing/Overlay.entitlements').read_bytes())
assert overlay_entitlements.get('com.apple.springboard.accessibility-window-hosting') is True
assert overlay_entitlements.get('com.apple.private.hid.client.event-monitor') is True
assert overlay_entitlements.get('com.apple.private.security.no-sandbox') is True
assert overlay_entitlements.get('com.apple.private.security.storage.AppDataContainers') is True
assert overlay_entitlements.get('task_for_pid-allow') is True
assert overlay_entitlements.get('com.apple.system-task-ports') is True
assert 'Overlay/CameraEngine.m' in (root / 'scripts/build-overlay.sh').read_text('utf8')
assert 'esp-memory-check.c' in (root / 'scripts/build-overlay.sh').read_text('utf8')
assert 'esp-presentation-check.c' in (root / 'scripts/build-overlay.sh').read_text('utf8')
assert 'minimap-check.c' in (root / 'scripts/build-overlay.sh').read_text('utf8')
assert 'esp-visual-check.c' in (root / 'scripts/build-overlay.sh').read_text('utf8')
assert 'Assets/HeroIcons' in (root / 'scripts/build-overlay.sh').read_text('utf8')
assert 'Assets/Theme' in (root / 'scripts/build-overlay.sh').read_text('utf8')
assert '../Assets/Theme' in (root / 'HeroControl.xcodeproj/project.pbxproj').read_text('utf8')
assert 'logic-esp-check.c' in (root / 'scripts/build-overlay.sh').read_text('utf8')
assert 'lua-reports-check.c' in (root / 'scripts/build-overlay.sh').read_text('utf8')
overlay_info = plistlib.loads((root / 'Overlay/Info.plist').read_bytes())
assert overlay_info['CFBundleVersion'] == info['CFBundleVersion']
assert overlay_info['CFBundleShortVersionString'] == info['CFBundleShortVersionString']
assert overlay_info['CFBundleExecutable'] == 'hero-overlay'
build_script = (root / 'scripts/build-tipa.sh').read_text('utf8')
assert 'scripts/build-overlay.sh' in build_script
assert 'Tools/HeroOverlay.app' in build_script
assert 'Signing/Overlay.entitlements' in build_script
for banned in ['com.apple.private.cs.debugger', 'dynamic-codesigning', 'com.apple.private.skip-library-validation']:
    assert banned not in app_entitlements and banned not in helper_entitlements
print(json.dumps({'pbxObjects': len(definitions), 'toggleKeys': len(keys), 'sharedTestScheme': True,
                  'plistValid': True, 'abiWiring': True, 'note': 'Static checks only; run Xcode/Simulator for compilation and runtime checks.'}, indent=2))
