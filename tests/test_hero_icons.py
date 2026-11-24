import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent / 'Assets/HeroIcons'


class HeroIconAssetsTests(unittest.TestCase):
    def test_theme_images_and_user_photo_match_packaged_manifest(self):
        theme = ROOT.parent / 'Theme'
        manifest = json.loads((theme / 'manifest.json').read_text('utf8'))
        entries = [manifest['userImage']] + manifest['skins']
        self.assertEqual(len(manifest['skins']), 3)
        for entry in entries:
            data = (theme / entry['file']).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), entry['sha256'])
            self.assertTrue(data.startswith((b'\xff\xd8\xff', b'\x89PNG\r\n\x1a\n')))

    def test_workbook_catalog_has_unique_ids_and_complete_offline_assets(self):
        catalog = json.loads((ROOT / 'catalog.json').read_text('utf8'))
        heroes = catalog['heroes']
        self.assertEqual(len(heroes), 130)
        self.assertEqual(len({h['id'] for h in heroes}), len(heroes))
        for hero in heroes:
            with self.subTest(id=hero['id']):
                self.assertTrue(hero['name'])
                self.assertEqual(hero['file'], f"{hero['id']}.img")
                data = (ROOT / hero['file']).read_bytes()
                self.assertEqual(len(data), hero['bytes'])
                self.assertEqual(hashlib.sha256(data).hexdigest(), hero['sha256'])
                self.assertTrue(data.startswith((b'\xff\xd8\xff', b'\x89PNG\r\n\x1a\n', b'GIF89a', b'GIF87a', b'RIFF')))


if __name__ == '__main__':
    unittest.main()
