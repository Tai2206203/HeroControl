#!/usr/bin/env python3
"""Fetch the official icon URLs supplied in the user's workbook, before build."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent / 'Assets/HeroIcons'


def fetch(hero):
    assert urlparse(hero['url']).scheme == 'https'
    assert urlparse(hero['url']).hostname == 'lienquan.garena.vn'
    path = ROOT / hero['file']
    assert path.parent == ROOT and path.name == f"{hero['id']}.img"
    if path.exists():
        data = path.read_bytes()
    else:
        request = Request(hero['url'], headers={'User-Agent': 'HeroControl-icon-import/1.0'})
        with urlopen(request, timeout=45) as response:
            assert urlparse(response.url).hostname == 'lienquan.garena.vn'
            data = response.read(4 * 1024 * 1024 + 1)
        assert 0 < len(data) <= 4 * 1024 * 1024
        assert data.startswith((b'\xff\xd8\xff', b'\x89PNG\r\n\x1a\n', b'RIFF', b'GIF87a', b'GIF89a')), 'Not an image'
        path.write_bytes(data)
    return dict(hero, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())


if __name__ == '__main__':
    catalog = json.loads((ROOT / 'catalog.json').read_text('utf8'))
    with ThreadPoolExecutor(max_workers=6) as pool:
        catalog['heroes'] = list(pool.map(fetch, catalog['heroes']))
    (ROOT / 'catalog.json').write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n', encoding='utf8', newline='\n')
    print(f"Bundled {len(catalog['heroes'])} icons; no game-time network required.")
