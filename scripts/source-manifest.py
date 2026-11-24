#!/usr/bin/env python3
"""Check committed source bytes; --write refreshes the manifest before committing."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def entry(path):
    data = (ROOT / path).read_bytes()
    return {'path': path, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    destination = ROOT / 'source-manifest.json'
    if args.write:
        names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode('utf8').split('\0')
        paths = sorted({p for p in names if p and p != 'source-manifest.json' and (ROOT / p).is_file()})
        items = [entry(p) for p in paths]
        destination.write_text(json.dumps(items, ensure_ascii=False, indent=2)+'\n', encoding='utf8', newline='\n')
    else:
        items = json.loads(destination.read_text('utf8'))
        assert len({i['path'] for i in items}) == len(items), 'Duplicate manifest paths'
        for item in items:
            path = ROOT / item['path']
            assert path.resolve().is_relative_to(ROOT), 'Manifest path outside project'
            assert path.is_file() and entry(item['path']) == item, 'Manifest mismatch: ' + item['path']
    print(f'Source manifest: {len(items)} files verified' if not args.write else f'Updated manifest: {len(items)} files')


if __name__ == '__main__':
    main()
