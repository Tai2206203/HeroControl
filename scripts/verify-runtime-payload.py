#!/usr/bin/env python3
"""Verify portable payload lineage before any Apple compilation/packaging."""
import hashlib
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def verify(root=ROOT):
    payload = root / 'Runtime/Payload'
    manifest = json.loads((payload / 'manifest.json').read_text('utf8'))
    assert manifest['unityUUID'] == '298E718A-DA06-33B8-8253-910447B649E3'
    assert manifest['allServerHistoryGuaranteed'] is False
    assert {p['file'] for p in manifest['patches']} == {'HeroSkin_1.patch', 'HeroSkin_2.patch'}
    for item in manifest['patches']:
        data = (payload / item['file']).read_bytes()
        assert len(data) == item['bytes']
        assert hashlib.sha256(data).hexdigest() == item['sha256'], item['file']
        assert data[:8].hex() == 'd0db2c0e465fd41f'
    lua = (payload / 'ComplaintHistory.lua').read_text('utf8')
    patch = (payload / 'HeroSkin_1.patch').read_bytes()
    assert lua.encode('utf8') in patch, 'Shipped Lua differs from embedded donor'
    assert "if f[1]=='I' then" in lua
    assert "if f[1]=='I' or (f[1]=='B' and not freshMatch) then" not in lua
    assert b'/checkto' not in patch and 'function m.command(' not in lua
    assert 'function m.setEnabled(value)' in lua
    assert 'CSID_CMD_COMPLAINT_RECORD_REQ' in lua and 'syncPendingRequest' in lua
    filter_ = plistlib.loads((root / 'Runtime/HeroControlRuntime.plist').read_bytes())
    assert filter_ == {'Filter': {'Bundles': ['com.garena.game.kgvn']}}
    print('Runtime payload verified: two patches, embedded Lua parity, baseline history and exact bundle filter.')


if __name__ == '__main__':
    verify()
