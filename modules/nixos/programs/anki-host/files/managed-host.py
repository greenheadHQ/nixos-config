"""Root-only managed-model enrollment, deployed update and diagnostics.

The wrapper owns the instance, loopback port, state and credential directories.
There is no URL, raw definition, digest, filesystem path, schema action, or sync
direction argument. Updates use the deployed bundle and normal sync only.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import time
from typing import Any
import urllib.error
import urllib.request


# Exact codes only: helper errors may otherwise contain note content or secrets.
HELPER_ERRORS = frozenset({
    "busy", "local-authentication-required", "role-not-allowed",
    "managed-update-already-matches-deployed-source",
    "managed-update-baseline-changed-reprepare",
    "managed-update-confirmation-record-missing",
    "managed-update-content-changed-before-delivery",
    "managed-update-delivery-unconfirmed",
    "managed-update-device-sync-and-edit-pause-confirmation-required",
    "managed-update-diagnosis-unconfirmed",
    "managed-update-explicit-confirmation-required",
    "managed-update-fresh-normal-sync-required",
    "managed-update-interrupted-inspect-original-operation",
    "managed-update-invalid-journal",
    "managed-update-invalid-operation-id",
    "managed-update-isolated-verification-required",
    "managed-update-journal-unavailable-operator-repair-required",
    "managed-update-normal-baseline-required",
    "managed-update-not-found",
    "managed-update-operation-id-conflicts-with-baseline",
    "managed-update-postcondition-unconfirmed",
    "managed-update-preparation-failed",
    "managed-update-preparation-interrupted",
    "managed-update-preview-expired",
    "managed-update-preview-token-mismatch",
    "managed-update-published-baseline-mismatch",
    "managed-update-registration-in-progress",
    "managed-update-registration-unconfirmed",
    "managed-update-result-unconfirmed",
    "managed-update-source-changed-reprepare",
    "managed-update-source-model-mismatch",
    "managed-update-source-unavailable",
    "managed-update-stale-preview-reprepare",
    "managed-update-state-changed-during-backup",
    "managed-update-state-changed-during-verification",
    "managed-update-unresolved-update-inspect-original-operation",
    "managed-update-unsafe-journal-directory",
    "managed-update-unsupported-model-change",
    "managed-update-unverified-read-status",
    "managed-update-verification-or-backup-changed",
    "managed-update-verified-baseline-required",
    "managed-update-verified-mirrored-backup-required",
})


class CommandError(ValueError):
    """A fixed, public diagnostic produced at this command boundary."""


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


def helper_error(value: Any) -> CommandError:
    code = value.get("error") if isinstance(value, dict) else None
    return CommandError(code if isinstance(code, str) and code in HELPER_ERRORS else "helper-request-failed")


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
    try:
        with opener.open(request, timeout=timeout) as response:
            value = json.load(response)
    except urllib.error.HTTPError as error:
        try:
            value = json.loads(error.read(16385))
        except (OSError, ValueError):
            value = None
        raise helper_error(value) from None
    if not isinstance(value, dict) or value.get("ok") is not True or not isinstance(value.get("result"), dict):
        raise helper_error(value)
    return value["result"]


def normal_sync(instance: str, state: Path) -> None:
    """Use the host's fixed normal unit and require a newly published success."""
    def status() -> dict[str, Any]:
        try:
            result = json.loads((state / "sync-status.json").read_text())
        except FileNotFoundError:
            return {}
        if not isinstance(result, dict):
            raise CommandError("fresh-normal-sync-required")
        return result

    previous = status().get("runId")
    requested_at = time.time()
    subprocess.run(["systemctl", "start", f"anki-host-sync-{instance}.service"],
                   check=True, capture_output=True)
    current = status()
    try:
        started = datetime.fromisoformat(current.get("runStartedAt"))
        fresh = started.utcoffset() is not None and started.timestamp() >= requested_at
    except (TypeError, ValueError):
        fresh = False
    # Joining a unit that started before this request is not a fresh presync.
    if (not fresh or not isinstance(current.get("runId"), str) or not current["runId"]
            or current["runId"] == previous or current.get("result") != "success"
            or current.get("mode") != "normal" or not isinstance(current.get("sync"), dict)
            or current["sync"].get("action") != "normal"):
        raise CommandError("fresh-normal-sync-required")


def update_result(result: dict[str, Any], operation_id: str) -> dict[str, Any]:
    if (result.get("operation_id") != operation_id
            or result.get("state") not in ("prepared", "applied", "partial", "unknown", "expired", "not-applied")
            or type(result.get("registered")) is not bool or not isinstance(result.get("sync"), dict)
            or result["sync"].get("state") not in ("pending", "synced", "blocked")):
        raise CommandError("helper-request-failed")
    result = {**result, "sync": dict(result["sync"])}
    for public in (result, result["sync"]):
        if "error" in public:
            public["error"] = str(helper_error(public))
    return result


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
    preview = commands.add_parser("update-preview", allow_abbrev=False)
    preview.add_argument("--devices-ready", required=True, action="store_true",
                         help="confirm other devices finished syncing and are idle until this update completes")
    update = commands.add_parser("update", allow_abbrev=False)
    update.add_argument("operation_id", type=identifier)
    update.add_argument("--preview-token", required=True, type=preview_token)
    update.add_argument("--confirm", required=True, action="store_true")
    for name in ("update-status", "diagnose-update"):
        commands.add_parser(name, allow_abbrev=False).add_argument("operation_id", type=identifier)
    args = parser.parse_args(argv)
    if os.geteuid() != 0:
        parser.error("root-required")
    instance = os.environ["INSTANCE"]
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", instance) is None:
        raise ValueError("invalid-configured-instance")
    port, timeout = int(os.environ["HELPER_PORT"]), int(os.environ["HELPER_CURL_MAX_TIME"])
    if not 1 <= port <= 65535 or timeout <= 0:
        raise ValueError("invalid-configured-helper-boundary")
    state = None
    if args.command in ("update-preview", "update"):
        state = Path(os.environ["STATE_DIR"])
        if not state.is_absolute():
            raise ValueError("invalid-configured-state-directory")
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
    elif args.command == "diagnose-restore":
        path, payload = "/managed/restore/diagnose", {"request_id": args.request_id}
    elif args.command == "update-preview":
        path = "/managed/update/prepare"
    elif args.command == "update":
        path = "/managed/update/apply"
        payload = {"operation_id": args.operation_id, "preview_token": args.preview_token, "confirm": True}
    else:
        path = "/managed/update/" + ("status" if args.command == "update-status" else "diagnose")
        payload = {"operation_id": args.operation_id}
    credential = Path(os.environ["LOCAL_CREDENTIAL_ROOT"]) / instance / role
    key = read_credential(credential)

    def call(route: str, body: dict[str, Any]) -> dict[str, Any]:
        return helper(route, body, key=key, port=port, timeout=timeout)

    if args.command == "update-preview":
        normal_sync(instance, state)
        operation_id = secrets.token_hex(16)
        # Emit before prepare: a lost response must leave a status lookup key.
        print("operation_id: " + operation_id, file=sys.stderr, flush=True)
        payload = {"operation_id": operation_id, "devices_ready": True}
    result = call(path, payload)
    if path.startswith("/managed/update/"):
        result = update_result(result, payload["operation_id"])
    complete = True
    if args.command == "update":
        complete = False
        if result.get("state") == "applied" and result.get("registered") is True:
            try:
                normal_sync(instance, state)
            except Exception:
                print("normal-sync-unconfirmed; checking update delivery", file=sys.stderr)
            try:
                delivered = call("/managed/update/delivery", {"operation_id": args.operation_id})
                result = update_result(delivered, args.operation_id)
            except Exception:
                # Preserve the confirmed local result when delivery is unknown.
                print("delivery-unconfirmed; inspect update-status " + args.operation_id, file=sys.stderr)
            else:
                complete = (result.get("state") == "applied" and result.get("registered") is True
                            and result.get("sync", {}).get("state") == "synced")
    elif args.command == "update-preview":
        complete = result.get("state") == "prepared"
    print(json.dumps(result, ensure_ascii=False))
    if not complete:
        raise SystemExit(1)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Only fixed diagnostics can escape; never print an HTTP body or key.
        detail = str(error) if isinstance(error, CommandError) else type(error).__name__
        raise SystemExit("anki-host-managed failed: " + detail) from None
