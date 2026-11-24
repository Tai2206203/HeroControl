#!/usr/bin/env python3
"""Send one successful build to the user's Telegram chat. Secrets are env-only."""
import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
import uuid
import zipfile
from pathlib import Path

MAX_DOCUMENT_BYTES = 50_000_000


class DeliveryError(Exception):
    pass


def redact(text, token):
    text = str(text).replace(token, "[redacted]") if token else str(text)
    return re.sub(r"\b\d{6,}:[A-Za-z0-9_-]{20,}\b", "[redacted]", text)


def multipart(chat_id, caption, filename, payload, boundary):
    chunks = []
    for name, value in [("chat_id", chat_id), ("caption", caption)]:
        chunks.append((f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n"
                       f"{value}\r\n").encode("utf8"))
    safe_name = filename.replace('"', "_").replace("\r", "_").replace("\n", "_")
    chunks.extend([
        (f"--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; filename=\"{safe_name}\"\r\n"
         "Content-Type: application/octet-stream\r\n\r\n").encode("utf8"),
        payload, f"\r\n--{boundary}--\r\n".encode("ascii"),
    ])
    return b"".join(chunks)


def send_document(token, chat_id, path, opener=urllib.request.urlopen):
    if not re.fullmatch(r"\d+:[A-Za-z0-9_-]+", token):
        raise DeliveryError("TELEGRAM_BOT_TOKEN has an invalid format.")
    if not re.fullmatch(r"-?\d+", chat_id):
        raise DeliveryError("TELEGRAM_CHAT_ID must be a numeric chat ID.")
    if not path.is_file() or path.suffix.lower() != ".tipa":
        raise DeliveryError("The .tipa artifact is missing.")
    if not 0 < path.stat().st_size <= MAX_DOCUMENT_BYTES:
        raise DeliveryError("The .tipa exceeds the Telegram upload limit or is empty; download the GitHub artifact.")
    with zipfile.ZipFile(path) as archive:
        if "Payload/HeroControl.app/Info.plist" not in archive.namelist():
            raise DeliveryError("The artifact is not a HeroControl app package.")
    payload = path.read_bytes()
    digest = hashlib.sha256(payload).hexdigest()
    commit = os.environ.get("GITHUB_SHA", "local")[:12]
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    caption = f"Hero Control | commit {commit}\nSHA-256: {digest}"
    if repo and run_id:
        caption += f"\n{server}/{repo}/actions/runs/{run_id}"
    caption += "\n0.13.0 build 30: một lần ON tự chuẩn bị check tố cáo; giao diện tiến trình và lịch sử mới; camera lưu khi kéo, có nút −/+ dùng cả khi ON. Lần cài adapter đầu cần mở lại game một lần."
    boundary = "HeroControl" + uuid.uuid4().hex
    body = multipart(chat_id, caption, path.name, payload, boundary)
    request = urllib.request.Request(
        "https://api.telegram.org/bot" + token + "/sendDocument", data=body,
        headers={"Content-Type": "multipart/form-data; boundary=" + boundary}, method="POST")
    try:
        with opener(request, timeout=180) as response:
            result = json.loads(response.read(1024 * 1024))
    except urllib.error.HTTPError as error:
        try:
            value = json.loads(error.read(1024 * 1024))
            detail = value.get("description", "Telegram rejected the upload")
        except (ValueError, OSError):
            detail = "Telegram rejected the upload"
        raise DeliveryError(f"Telegram HTTP {error.code}: {redact(detail, token)}") from None
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        # Exception strings may contain the token-bearing request URL. Never log them.
        raise DeliveryError("Telegram transport/response error. Delivery is unconfirmed; check the chat before retrying.") from None
    if not isinstance(result, dict) or result.get("ok") is not True:
        detail = result.get("description", "Unexpected Telegram reply") if isinstance(result, dict) else "Unexpected Telegram reply"
        raise DeliveryError(redact(detail, token))
    message = result.get("result")
    if not isinstance(message, dict) or not isinstance(message.get("chat"), dict):
        raise DeliveryError("Telegram returned no message/chat acknowledgement.")
    if str(message["chat"].get("id")) != chat_id:
        raise DeliveryError("Telegram returned a different destination chat; do not retry automatically.")
    if type(message.get("message_id")) is not int:
        raise DeliveryError("Telegram returned no message ID; delivery is unconfirmed.")
    return {"status": "sent", "messageID": message.get("message_id"), "sha256": digest, "bytes": len(payload)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact", type=Path)
    args = parser.parse_args()
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
    if not token or not chat:
        print("::warning::Telegram secrets are not configured. Add TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in repository Actions secrets. The GitHub artifact remains available.")
        return 0
    try:
        result = send_document(token, chat, args.artifact)
    except (DeliveryError, OSError, zipfile.BadZipFile) as error:
        print("::error::" + redact(error, token), file=sys.stderr)
        return 1
    print("Telegram delivery confirmed; message ID: " + str(result["messageID"]))
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a", encoding="utf8") as stream:
            stream.write("\nTelegram: file delivery confirmed. SHA-256: `" + result["sha256"] + "`\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
