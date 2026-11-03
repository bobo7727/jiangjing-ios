#!/usr/bin/env bash
set +x
# Best effort only: never print credentials, the URL, or delivery diagnostics.
python3 - "$@" >/dev/null 2>&1 <<'PY' || true
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit


def notify():
    workflow = sys.argv[1] if len(sys.argv) == 2 else ""
    if workflow not in ("ios-simulator", "ios-testflight"):
        return
    url = os.environ.get("GROKBOT_WEBHOOK_URL", "").replace("\r", "").replace("\n", "")
    key = os.environ.get("GROKBOT_WEBHOOK_KEY", "").replace("\r", "").replace("\n", "")
    if not url or not key or any(ord(c) <= 32 or ord(c) == 127 for c in url):
        return
    target = urlsplit(url)
    if (target.scheme != "https" or not target.hostname or target.username is not None
            or target.password is not None or target.fragment or "\\" in url):
        return
    # Accessing port also rejects malformed/out-of-range ports.
    target.port
    build_id = os.environ.get("CM_BUILD_ID", "")
    app_id = os.environ.get("CM_PROJECT_ID", "")
    home = os.environ.get("HOME", "")
    marker = bool(build_id and home and (Path(home) / ("codemagic-success-" + build_id)).is_file())
    payload = {
        "source": "codemagic",
        "app": "jiangjing-ios",
        "workflow": workflow,
        "build_id": build_id,
        "app_id": app_id,
        "build_url": f"https://codemagic.io/app/{app_id}/build/{build_id}",
        "status": "finished" if workflow == "ios-testflight" else ("success" if marker else "failed"),
        "branch": os.environ.get("CM_BRANCH", ""),
        "commit": os.environ.get("CM_COMMIT", ""),
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    if workflow == "ios-testflight":
        # Ordinary script completion is only a hint, never an upload result.
        payload["script_marker"] = "present" if marker else "absent"
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    # The system temp directory is outside Codemagic artifact paths. URL and key
    # stay out of curl argv; the private files are removed even on curl failure.
    with tempfile.TemporaryDirectory(prefix="grokbot-notify-") as directory:
        def private_file(name, data):
            path = Path(directory) / name
            with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as stream:
                stream.write(data)
            return str(path)

        headers = private_file("headers", ("Authorization: Bearer " + key + "\nContent-Type: application/json\n").encode("utf-8"))
        data = private_file("payload", body)
        config = private_file("curl.conf", ("url = " + json.dumps(url, ensure_ascii=False) + "\n").encode("utf-8"))
        environment = dict(os.environ)
        environment.pop("GROKBOT_WEBHOOK_KEY", None)
        environment.pop("GROKBOT_WEBHOOK_URL", None)
        subprocess.run([
            "curl", "--disable", "--config", config,
            "--proto", "=https", "--globoff", "--max-redirs", "0",
            "--silent", "--fail", "--output", os.devnull,
            "--connect-timeout", "3", "--max-time", "8",
            "--retry", "2", "--retry-delay", "1", "--retry-max-time", "18",
            "--request", "POST", "--header", "@" + headers,
            "--data-binary", "@" + data,
        ], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=30, check=False)


try:
    notify()
except Exception:
    pass
PY
exit 0
