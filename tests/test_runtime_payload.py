import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('runtime_payload', ROOT / 'scripts/verify-runtime-payload.py')
payload = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(payload)
SPEC2 = importlib.util.spec_from_file_location('runtime_import', ROOT / 'scripts/import-runtime-reference.py')
importer = importlib.util.module_from_spec(SPEC2)
SPEC2.loader.exec_module(importer)


class RuntimePayloadTests(unittest.TestCase):
    def test_shipped_payload_lineage_and_filter(self):
        payload.verify()

    def test_binary_string_length_uses_dotnet_encoding(self):
        self.assertEqual(importer.seven_bit(0), b'\0')
        self.assertEqual(importer.seven_bit(127), b'\x7f')
        self.assertEqual(importer.seven_bit(128), b'\x80\x01')
        self.assertEqual(importer.seven_bit(16384), b'\x80\x80\x01')


if __name__ == '__main__':
    unittest.main()
