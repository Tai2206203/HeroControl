import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("protection", ROOT / "scripts/verify-protection.py")
protection = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(protection)

class ProtectionTests(unittest.TestCase):
    def test_vendor_and_native_wiring(self):
        protection.verify_sources()

    def test_scanner_rejects_plaintext_in_each_group(self):
        for group, name, value in protection.entries():
            target = "BACKEND" if group == "COMMON" else group
            for boundary in (b"\0", b"\x01"):
                with self.subTest(name=name, boundary=boundary):
                    data = boundary + value.encode("utf8") + b"\0"
                    self.assertIn(name, protection.plaintext_leaks(data, target))

    def test_loader_import_symbols_are_preserved(self):
        self.assertEqual(protection.plaintext_leaks(b"\0_mach_vm_read_overwrite\0", "RUNTIME"), [])

    def test_component_exclusion(self):
        self.assertEqual(protection.plaintext_leaks(b"\0SecTaskCreateFromSelf\0", "OVERLAY"), [])

if __name__ == "__main__":
    unittest.main()
