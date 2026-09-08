"""Runtime-only local credentials. No key values are part of the Nix store."""

from __future__ import annotations

import hmac
import os
from pathlib import Path


def read_key(path: str) -> str:
    if not path:
        raise RuntimeError("local-credential-path-missing")
    key = Path(path).read_text(encoding="ascii").strip()
    if len(key) != 64 or any(c not in "0123456789abcdef" for c in key):
        raise RuntimeError("local-credential-invalid")
    return key


class Access:
    def __init__(self, credential_dir: str) -> None:
        self.keys = {role: read_key(os.path.join(credential_dir, role))
                     for role in ("read", "operation", "maintenance", "schema")}

    def role(self, header: str | None) -> str | None:
        if not isinstance(header, str) or not header.startswith("Bearer "):
            return None
        key = header.removeprefix("Bearer ")
        if len(key) != 64 or any(c not in "0123456789abcdef" for c in key):
            return None
        for role, expected in self.keys.items():
            if hmac.compare_digest(key, expected):
                return role
        return None

    def allowed(self, method: str, path: str, role: str | None) -> bool:
        if role is None:
            return False
        if method == "GET" and path in ("/status", "/status/full"):
            return True
        if method == "POST" and path in ("/operations/status", "/operations/history", "/deck-options", "/model-info", "/media"):
            return role in ("read", "operation", "schema")
        if method == "POST" and path in ("/operations/prepare", "/operations/apply", "/operations/delivery"):
            return role in ("operation", "schema")
        if method == "POST" and path in ("/sync", "/export", "/import-colpkg"):
            return role == "maintenance"
        if method == "POST" and path in ("/schema/inspect", "/schema/backup", "/schema/apply"):
            return role == "schema"
        return False
