import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
from test_deb_package import fixture, package

SCRIPT = Path(__file__).resolve().parent.parent / "scripts/send-telegram.py"
SPEC = importlib.util.spec_from_file_location("send_telegram", SCRIPT)
telegram = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(telegram)
TOKEN = "123456:FAKE_TEST_TOKEN_NOT_A_REAL_BOT_000"


class Reply(io.BytesIO):
    def __init__(self, value):
        super().__init__(json.dumps(value).encode())


class TelegramTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.path = Path(self.folder.name) / "DORO-CHEAT.deb"
        package.build(fixture(Path(self.folder.name)), self.path, "roothide")

    def test_upload_checks_server_confirmation_and_destination(self):
        calls = []
        def opener(request, timeout):
            calls.append(request)
            self.assertEqual(timeout, 180)
            self.assertEqual(request.method, "POST")
            self.assertIn(b'name="document"', request.data)
            self.assertIn(self.path.read_bytes(), request.data)
            self.assertNotIn(TOKEN.encode(), request.data)
            return Reply({"ok": True, "result": {"message_id": 7, "chat": {"id": 42}}})
        result = telegram.send_document(TOKEN, "42", self.path, opener)
        self.assertEqual(result["status"], "sent")
        self.assertEqual(result["messageID"], 7)
        self.assertEqual(len(calls), 1)

    def test_wrong_destination_is_not_reported_successful(self):
        with self.assertRaisesRegex(telegram.DeliveryError, "different destination"):
            telegram.send_document(TOKEN, "42", self.path,
                lambda *args, **kwargs: Reply({"ok": True, "result": {"chat": {"id": 99}}}))

    def test_http_errors_do_not_expose_token(self):
        def opener(request, timeout):
            payload = io.BytesIO(json.dumps({"description": "blocked " + TOKEN}).encode())
            raise urllib.error.HTTPError(request.full_url, 403, "Forbidden", {}, payload)
        with self.assertRaises(telegram.DeliveryError) as caught:
            telegram.send_document(TOKEN, "42", self.path, opener)
        self.assertNotIn(TOKEN, str(caught.exception))
        self.assertIn("403", str(caught.exception))

    def test_transport_errors_hide_token_bearing_url(self):
        def opener(*args, **kwargs):
            raise urllib.error.URLError("https://api.telegram.org/bot" + TOKEN + "/sendDocument")
        with self.assertRaises(telegram.DeliveryError) as caught:
            telegram.send_document(TOKEN, "42", self.path, opener)
        self.assertNotIn(TOKEN, str(caught.exception))
        self.assertIn("unconfirmed", str(caught.exception))

    def test_numeric_ok_is_rejected(self):
        with self.assertRaises(telegram.DeliveryError):
            telegram.send_document(TOKEN, "42", self.path,
                lambda *args, **kwargs: Reply({"ok": 1, "result": {"chat": {"id": 42}}}))

    def test_missing_message_acknowledgement_is_not_success(self):
        for result in [None, {}, {"chat": {"id": 42}}]:
            with self.subTest(result=result), self.assertRaises(telegram.DeliveryError):
                telegram.send_document(TOKEN, "42", self.path,
                    lambda *args, **kwargs: Reply({"ok": True, "result": result}))

    def test_missing_secrets_skip_without_network(self):
        with patch.dict(telegram.os.environ, {"TELEGRAM_BOT_TOKEN": "", "TELEGRAM_CHAT_ID": ""}), \
             patch.object(telegram.sys, "argv", [str(SCRIPT), str(self.path)]), \
             patch.object(telegram, "send_document") as send, patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(telegram.main(), 0)
            send.assert_not_called()

    def test_missing_artifact_is_rejected_before_network(self):
        with self.assertRaisesRegex(telegram.DeliveryError, "missing"):
            telegram.send_document(TOKEN, "42", self.path.parent / "missing.deb")

    def test_broken_package_rejected_without_network(self):
        original = self.path.read_bytes()
        for payload in [b"not a deb", original[:-10]]:
            with self.subTest(size=len(payload)), patch.object(telegram.urllib.request, "urlopen") as opener:
                self.path.write_bytes(payload)
                with self.assertRaises(telegram.DeliveryError):
                    telegram.send_document(TOKEN, "42", self.path, opener)
                opener.assert_not_called()



if __name__ == "__main__":
    unittest.main()
