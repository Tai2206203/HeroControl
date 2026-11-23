#!/usr/bin/env python3
"""Actual native ABI checks on macOS; never spawns a HUD or changes identity."""
import ctypes
import json
import sys

library = ctypes.CDLL(sys.argv[1])
library.hc_overlay_request.argtypes = [ctypes.c_char_p]
library.hc_overlay_request.restype = ctypes.c_void_p
library.hc_overlay_release.argtypes = [ctypes.c_void_p]


def exchange(payload):
    ptr = library.hc_overlay_request(payload)
    assert ptr
    try:
        result = json.loads(ctypes.string_at(ptr))
        assert type(result['ok']) is bool
        assert isinstance(result['state'], dict)
        assert isinstance(result['message'], str) and result['message']
        return result
    finally:
        library.hc_overlay_release(ptr)


for payload in [None, b'{', b'[]', b'null', b'{}', b'{"action":{}}', b'x' * 16385,
                b'{"action":"run-shell"}', b'{"action":"start","directory":"/","profile":"/etc/passwd"}']:
    assert exchange(payload)['ok'] is False
for action in ['status', 'start', 'stop', 'toggle']:
    assert exchange(json.dumps({'action': action}).encode())['ok'] is False
print('Overlay ABI: malformed requests rejected; host refused HUD/persona operations.')
