import hashlib
import json
import struct
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent

def image_dimensions(data):
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return struct.unpack(">II", data[16:24])
    offset = 2
    while offset < len(data):
        if data[offset] != 255:
            offset += 1
            continue
        while data[offset] == 255:
            offset += 1
        marker = data[offset]
        offset += 1
        if marker in (0xd8, 0xd9) or 0xd0 <= marker <= 0xd7:
            continue
        size = int.from_bytes(data[offset:offset+2], "big")
        if marker in (0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf):
            return int.from_bytes(data[offset+5:offset+7], "big"), int.from_bytes(data[offset+3:offset+5], "big")
        offset += size
    raise ValueError("Image dimensions missing")

class ThemeAssetsTests(unittest.TestCase):
    def test_bundled_photo_bytes_match_manifest(self):
        folder = ROOT / 'Assets/Theme'
        manifest = json.loads((folder / 'manifest.json').read_text('utf8'))
        for asset in [manifest['userImage'], *manifest['skins']]:
            with self.subTest(file=asset['file']):
                data = (folder / asset['file']).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), asset['sha256'])
                self.assertTrue(data.startswith(b'\x89PNG\r\n\x1a\n') or data.startswith(b'\xff\xd8'))

    def test_sss_photos_are_present_in_hud_package_inputs(self):
        folder = ROOT / 'Assets/Theme'
        for name in ['violet-sss.png', 'lauriel-sss.jpg', 'airi-sss.jpg', 'telannas-fee-sss.jpg', 'telannas-dimension-sss.jpg', 'telannas-newyear-sss.jpg', 'butterfly-phoenix-sss.jpg', 'liliana-magic-sss.jpg']:
            self.assertTrue((folder / name).is_file(), name)
            width, height = image_dimensions((folder / name).read_bytes())
            self.assertGreaterEqual(width, 1000, name + " must be full artwork, not a portrait thumbnail")
            self.assertGreaterEqual(height, 600, name)
        script = (ROOT / 'scripts/build-overlay.sh').read_text('utf8')
        self.assertIn('ditto "$ROOT/Assets/Theme" "$OUTPUT/HeroOverlay.app/Theme"', script)
        self.assertIn('theme-assets-check', script)

if __name__ == '__main__':
    unittest.main()
