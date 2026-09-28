"""Manually inspect, preview and remove selected unused local tag names as root.

The wrapper fixes the instance, loopback endpoint and credential directory.
This command never chooses a sync direction or executes caller-supplied code.
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


def private_file(path: Path, maximum: int) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        metadata = os.fstat(fd)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0
                or metadata.st_mode & 0o077 or not 0 < metadata.st_size <= maximum):
            raise ValueError("expected-private-root-owned-regular-file")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            data = stream.read(maximum + 1)
        if len(data) > maximum:
            raise ValueError("input-file-too-large")
        return data
    finally:
        os.close(fd)


def tag_names(values: Any) -> list[str]:
    if (not isinstance(values, list) or any(not isinstance(v, str) or not v or
            any(c.isspace() or ord(c) < 32 for c in v) for v in values)):
        raise ValueError("expected-json-list-of-tag-names")
    return sorted(set(values))


def helper(path: str, payload: dict[str, Any], *, key: str, port: int, timeout: int) -> dict[str, Any]:
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", json.dumps(payload).encode("utf-8"),
        {"Content-Type": "application/json", "Authorization": "Bearer " + key}, method="POST")

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args: Any, **kwargs: Any) -> None:
            return None

    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=timeout) as response:
        value = json.load(response)
    if not isinstance(value, dict) or value.get("ok") is not True or not isinstance(value.get("result"), dict):
        raise ValueError("helper-request-failed")
    return value["result"]


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.set_defaults(command="inspect", protect=[], protect_file=None)
    commands = parser.add_subparsers(dest="command")
    inspect = commands.add_parser("inspect", allow_abbrev=False)
    preview = commands.add_parser("preview", allow_abbrev=False)
    for command in (inspect, preview):
        command.add_argument("--protect", action="append", default=[])
        command.add_argument("--protect-file", type=Path)
    preview.add_argument("--tags-file", required=True, type=Path)
    preview.add_argument("--request-id", type=request_id)
    apply = commands.add_parser("apply", allow_abbrev=False)
    apply.add_argument("operation_id", type=identifier)
    apply.add_argument("--preview-token", required=True, type=preview_token)
    apply.add_argument("--confirm", required=True, action="store_true")
    status = commands.add_parser("status", allow_abbrev=False)
    status.add_argument("operation_id", type=identifier)
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
    if args.command in (None, "inspect", "preview"):
        protected = tag_names(args.protect)
        if args.protect_file:
            protected = tag_names([*protected, *tag_names(json.loads(private_file(args.protect_file, 1048576)))])
        payload["protected_tags"] = protected
        path = "/tags/unused/inspect"
        if args.command == "preview":
            payload["tags"] = tag_names(json.loads(private_file(args.tags_file, 1048576)))
            if not payload["tags"]:
                raise ValueError("selected-tags-must-not-be-empty")
            if args.request_id is not None:
                payload["request_id"] = args.request_id
            path = "/tags/unused/prepare"
    elif args.command == "apply":
        path = "/tags/unused/apply"
        payload = {"operation_id": args.operation_id, "preview_token": args.preview_token, "confirm": True}
    else:
        path, payload = "/operations/status", {"operation_id": args.operation_id}
    credential = Path(os.environ["LOCAL_CREDENTIAL_ROOT"]) / instance / "schema"
    key = private_file(credential, 65).decode("ascii").strip()
    if re.fullmatch(r"[0-9a-f]{64}", key) is None:
        raise ValueError("invalid-local-credential")
    result = helper(path, payload, key=key, port=port, timeout=timeout)
    if path != "/tags/unused/inspect" and result.get("action") != "remove_unused_tags":
        raise ValueError("unexpected-operation-action")
    print(json.dumps(result, ensure_ascii=False))
    if args.command == "apply" and result.get("state") != "applied":
        raise ValueError("operation-not-completed-inspect-status-do-not-repeat")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        raise SystemExit("anki-host-unused-tags failed: " + type(error).__name__) from None
