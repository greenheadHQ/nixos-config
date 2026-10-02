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
import urllib.error
import urllib.request


MAX_ERROR_BODY_BYTES = 4096
REMOTE_ERROR_CODES = frozenset({
    "invalid-unused-tags-request", "invalid-operation-parameters", "root-operator-command-required",
    "tags-must-be-nonempty-and-contain-no-whitespace-or-control-characters", "tags-must-not-be-empty",
    "unused-tag-name-missing-or-changed", "unused-tag-selection-must-include-all-descendants",
    "unused-tag-selection-includes-protected-name", "selected-tag-or-descendant-is-in-use",
    "stale-preview-create-a-new-request-id", "preview-expired-create-a-new-request-id",
    "preview-token-mismatch", "explicit-confirmation-required", "restore-point-not-mirrored",
    "request-id-payload-mismatch", "operation-not-found", "collection-not-ready", "collection-not-open",
})
LOCAL_ERROR_CODES = frozenset({
    "expected-private-root-owned-regular-file", "input-file-too-large", "expected-json-list-of-tag-names",
    "invalid-configured-instance", "invalid-configured-helper-boundary", "selected-tags-must-not-be-empty",
    "invalid-local-credential", "helper-request-failed", "unexpected-operation-action",
    "operation-not-completed-inspect-status-do-not-repeat", "apply-response-unknown-check-status-do-not-repeat",
    "helper-busy", "helper-busy-check-status-do-not-repeat",
})
STATUS_GUIDANCE = "Use status for the same operation before any retry; do not create a new request ID."


def describe_error(error: Exception) -> str:
    # Only our closed vocabulary is printable. Never print an arbitrary exception,
    # HTTP body, filename, tag, credential or traceback, even if it is a ValueError.
    code = str(error) if isinstance(error, ValueError) else ""
    if code not in REMOTE_ERROR_CODES | LOCAL_ERROR_CODES:
        return type(error).__name__
    if code in {"operation-not-completed-inspect-status-do-not-repeat",
                "apply-response-unknown-check-status-do-not-repeat", "helper-busy-check-status-do-not-repeat"}:
        return code + ". " + STATUS_GUIDANCE
    return code


def remote_error_code(error: urllib.error.HTTPError) -> str | None:
    if error.code not in (400, 409):
        return None
    try:
        raw = error.read(MAX_ERROR_BODY_BYTES + 1)
        if len(raw) > MAX_ERROR_BODY_BYTES:
            return None
        value = json.loads(raw)
        if (not isinstance(value, dict) or value.get("ok") is not False
                or set(value) - {"ok", "error", "busy"} or not isinstance(value.get("error"), str)):
            return None
        code = value["error"]
        if error.code == 409 and code == "busy":
            return "helper-busy"
        if error.code == 400 and code in REMOTE_ERROR_CODES:
            return code
    except Exception:
        pass
    return None


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
    applying = path == "/tags/unused/apply"
    try:
        with opener.open(request, timeout=timeout) as response:
            value = json.load(response)
        if not isinstance(value, dict) or value.get("ok") is not True or not isinstance(value.get("result"), dict):
            raise ValueError("helper-request-failed")
    except urllib.error.HTTPError as error:
        code = remote_error_code(error)
        error.close()
        if code is not None:
            if applying and code == "helper-busy":
                code = "helper-busy-check-status-do-not-repeat"
            raise ValueError(code) from None
        if applying:
            raise ValueError("apply-response-unknown-check-status-do-not-repeat") from None
        raise
    except Exception:
        if applying:
            raise ValueError("apply-response-unknown-check-status-do-not-repeat") from None
        raise
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
        raise SystemExit("anki-host-unused-tags failed: " + describe_error(error)) from None
