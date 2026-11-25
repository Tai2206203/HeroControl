#!/usr/bin/env python3
"""Compile the existing Swift menu catalog to an Objective-C constant table."""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def generate(destination):
    models = (ROOT / 'HeroControl/Models.swift').read_text(encoding='utf8')
    entries = re.findall(r'\.init\(key: "([^"]+)", title: "([^"]+)", group: \.(\w+)\)', models)
    groups = ['esp', 'camera', 'style', 'calibration', 'reports']
    if len(entries) != 9 or len({key for key, _, _ in entries}) != 9:
        raise RuntimeError('Unexpected menu catalog; update the overlay generator explicitly')
    # UTF-8 source string literals are accepted by clang; json supplies escaping.
    rows = [f'@{{@"key": @{json.dumps(key, ensure_ascii=False)}, @"title": @{json.dumps(title, ensure_ascii=False)}, @"group": @{groups.index(group)}}}'
            for key, title, group in entries]
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text('// Generated from Models.swift; do not edit.\n'
                           'static NSArray<NSDictionary *> *HCFeatures(void) { return @[\n'
                           + ',\n'.join(rows) + '\n]; }\n', encoding='utf8')


if __name__ == '__main__':
    generate(Path(sys.argv[1]))
