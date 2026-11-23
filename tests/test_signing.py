import copy
import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parent.parent / "scripts/verify-entitlements.py"
SPEC = importlib.util.spec_from_file_location("verify_entitlements", SCRIPT)
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)


class EntitlementTests(unittest.TestCase):
    def test_equal_array_from_separate_plist_decode_is_accepted(self):
        expected = {"platform-application": True,
                    "com.apple.security.exception.iokit-user-client-class": ["IOSurfaceRootUserClient"]}
        actual = copy.deepcopy(expected)
        self.assertIsNot(actual["com.apple.security.exception.iokit-user-client-class"],
                         expected["com.apple.security.exception.iokit-user-client-class"])
        self.assertEqual(signing.missing_entitlements(actual, expected), [])

    def test_different_iokit_class_is_rejected(self):
        key = "com.apple.security.exception.iokit-user-client-class"
        self.assertEqual(signing.missing_entitlements({key: ["OtherClass"]}, {key: ["IOSurfaceRootUserClient"]}), [key])

    def test_integer_cannot_satisfy_boolean_entitlement(self):
        self.assertEqual(signing.missing_entitlements({"platform-application": 1}, {"platform-application": True}),
                         ["platform-application"])


if __name__ == "__main__":
    unittest.main()
