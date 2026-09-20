"""Root-only managed-model enrollment and diagnostic commands.

The wrapper owns the instance, loopback port and credential directory. There is
no URL, raw definition, digest, filesystem path, schema action, or sync direction
argument. This command cannot deploy a new model or authorize a full upload.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import stat
from typing import Any
import urllib.request


def identifier(value: str) -> str:
    if re.fullmatch(r"[0-9a-f]{32}", value) is None:
        raise argparse.ArgumentTypeError("expected-32-lowercase-hex-identifier")
    return value


def preview_token(value: str) -> str:
    if re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise argparse.ArgumentTypeError("expected-64-lowercase-hex-preview-token")
    return value


def request_id(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{7,127}", value) is None:
        raise argparse.ArgumentTypeError("invalid-request-id")
    return value


def read_credential(path: Path) -> str:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        metadata = os.fstat(fd)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0
                or metadata.st_mode & 0o077 or metadata.st_size not in (64, 65)):
            raise ValueError("invalid-local-credential-file")
        value = os.read(fd, 66).decode("ascii").strip()
        if re.fullmatch(r"[0-9a-f]{64}", value) is None:
            raise ValueError("invalid-local-credential")
        return value
    finally:
        os.close(fd)


def helper(path: str, payload: dict[str, Any], *, key: str, port: int, timeout: int) -> dict[str, Any]:
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", json.dumps(payload).encode("utf-8"),
        {"Content-Type": "application/json", "Authorization": "Bearer " + key}, method="POST")

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args: Any, **kwargs: Any) -> None:
            return None

    # Root credentials must not be forwarded to an environment proxy or a
    # redirect destination, even when local endpoint behavior is unexpected.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=timeout) as response:
        value = json.load(response)
    if not isinstance(value, dict) or value.get("ok") is not True or not isinstance(value.get("result"), dict):
        raise ValueError("helper-request-failed")
    return value["result"]


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("inspect", allow_abbrev=False)
    commands.add_parser("enrollment-preview", allow_abbrev=False)
    enroll = commands.add_parser("register", allow_abbrev=False)
    enroll.add_argument("operation_id", type=identifier)
    enroll.add_argument("--preview-token", required=True, type=preview_token)
    enroll.add_argument("--confirm", required=True, action="store_true")
    notification = commands.add_parser("retry-notification", allow_abbrev=False)
    notification.add_argument("incident_id", type=identifier)
    diagnosis = commands.add_parser("diagnose-restore", allow_abbrev=False)
    diagnosis.add_argument("request_id", type=request_id)
    args = parser.parse_args(argv)
    if os.geteuid() != 0:
        parser.error("root-required")
    instance = os.environ["INSTANCE"]
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", instance) is None:
        raise ValueError("invalid-configured-instance")
    port, timeout = int(os.environ["HELPER_PORT"]), int(os.environ["HELPER_CURL_MAX_TIME"])
    if not 1 <= port <= 65535 or timeout <= 0:
        raise ValueError("invalid-configured-helper-boundary")
    payload: dict[str, Any] = {}
    role = "schema"
    if args.command == "inspect":
        path, role = "/managed/check", "read"
    elif args.command == "enrollment-preview":
        path = "/managed/enrollment/prepare"
    elif args.command == "register":
        path = "/managed/enrollment/apply"
        payload = {"operation_id": args.operation_id, "preview_token": args.preview_token, "confirm": True}
    elif args.command == "retry-notification":
        path, payload = "/managed/notification/retry", {"incident_id": args.incident_id}
    else:
        path, payload = "/managed/restore/diagnose", {"request_id": args.request_id}
    credential = Path(os.environ["LOCAL_CREDENTIAL_ROOT"]) / instance / role
    result = helper(path, payload, key=read_credential(credential), port=port, timeout=timeout)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Do not leak credentials, HTTP response bodies or tracebacks to logs.
        raise SystemExit("anki-host-managed failed: " + type(error).__name__) from None
