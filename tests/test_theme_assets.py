import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent

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
        for name in ['violet-sss.png', 'lauriel-sss.jpg', 'airi-sss.jpg']:
            self.assertTrue((folder / name).is_file(), name)
        script = (ROOT / 'scripts/build-overlay.sh').read_text('utf8')
        self.assertIn('ditto "$ROOT/Assets/Theme" "$OUTPUT/HeroOverlay.app/Theme"', script)
        self.assertIn('theme-assets-check', script)

if __name__ == '__main__':
    unittest.main()
