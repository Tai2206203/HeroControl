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
assert len(keys) == 13 and len(set(keys)) == 13
expected = [
    '__ifxEnemyEspEnabledV1', 'DoroCheat.Reference.R1.Box', 'DoroCheat.Reference.R1.Icon',
    'DoroCheat.Reference.R1.HP', 'DoroCheat.Reference.R1.Map', 'DoroCheat.Reference.R1.Unseen',
    'DoroCheat.Reference.R1.Check', 'DoroCheat.Style.Buttons', 'DoroCheat.Style.Banner',
    'DoroCheat.Style.Skin', 'DoroCheat.Style.BeforeMatch', 'DoroCheat.Style.LiveChange', 'reports.enabled'
]
assert keys == expected
backend = (root / 'HeroControl/NativeBackend.swift').read_text('utf8')
header = (root / 'BackendSDK/HeroBackend.h').read_text('utf8')
example = (root / 'BackendSDK/UnavailableBackend.m').read_text('utf8')
for symbol in ['hc_backend_api_version', 'hc_backend_request', 'hc_backend_release']:
    assert all(symbol in text for text in [backend, header, example])
assert '@"connected": @NO' in example
assert 'CODE_SIGNING_ALLOWED=NO' in (root / 'scripts/build-tipa.sh').read_text('utf8')
print(json.dumps({'pbxObjects': len(definitions), 'toggleKeys': len(keys), 'sharedTestScheme': True,
                  'plistValid': True, 'abiWiring': True, 'note': 'Static checks only; run Xcode/Simulator for compilation and runtime checks.'}, indent=2))
