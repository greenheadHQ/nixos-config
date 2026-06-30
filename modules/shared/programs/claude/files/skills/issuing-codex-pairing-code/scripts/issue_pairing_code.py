#!/usr/bin/env python3
"""Issue a Codex remote-control pairing code through a helper-owned app-server.

Internal boundaries:
- platform and consent gates run before any live side effect
- runtime path creation owns only this helper's private directory
- WebSocket framing is isolated from JSON-RPC sequencing
- output formatting redacts all non-manual pairing payloads
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import datetime as dt
import hashlib
import json
import os
import platform
import re
import secrets
import shlex
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
DEFAULT_SESSION = "codex-pair-bg"
CLIENT_NAME = "issuing-codex-pairing-code"
CLIENT_VERSION = "1.0.0"
MOCK_EXPIRES_AT = 1893456000
CODE_RE = re.compile(r"\b[A-Z0-9]{4}-[A-Z0-9]{4}\b")
SECRET_KEY_RE = re.compile(
    r'("(?:manualPairingCode|pairingCode|environmentId)"\s*:\s*")[^"]+(")'
)


class PairingError(RuntimeError):
    """User-facing helper failure with secret-safe messaging."""


@dataclasses.dataclass(frozen=True)
class RuntimePaths:
    root: Path
    socket_path: Path
    log_path: Path
    session_name: str


@dataclasses.dataclass(frozen=True)
class PairingResult:
    manual_pairing_code: str
    expires_at: Any
    cleanup_command: str


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Issue a Codex remote-control computer pairing code."
    )
    parser.add_argument(
        "--user-requested-code",
        action="store_true",
        help="Required for live issuance after explicit user consent.",
    )
    parser.add_argument(
        "--mock",
        action="store_true",
        help="Return deterministic fixture output without live Codex, tmux, or sockets.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print machine-readable output with the manual code, expiry, and cleanup command.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=10.0,
        help="Timeout in seconds for app-server startup and RPC waits.",
    )
    return parser.parse_args(argv)


def ensure_consent(args: argparse.Namespace) -> None:
    if not args.mock and not args.user_requested_code:
        raise PairingError(
            "live issuance requires --user-requested-code after explicit user consent"
        )


def ensure_live_platform_allowed(is_mock: bool) -> None:
    if is_mock:
        return
    if platform.system() != "Darwin":
        raise PairingError(
            "live pairing-code issuance is supported only on macOS/Darwin; "
            "use --mock for fixture validation on Linux/NixOS"
        )


def select_codex_binary() -> Path:
    override = os.environ.get("CODEX_PAIRING_CODEX_BIN")
    candidates: list[Path] = []
    if override:
        candidates.append(Path(override).expanduser())
    candidates.extend(
        [
            Path("/Applications/Codex.app/Contents/Resources/codex"),
            Path("~/.codex/packages/standalone/current/codex").expanduser(),
            Path("~/.codex/packages/standalone/current/bin/codex").expanduser(),
        ]
    )
    path_codex = shutil.which("codex")
    if path_codex:
        candidates.append(Path(path_codex))

    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate

    raise PairingError(
        "could not find an executable Codex binary; set CODEX_PAIRING_CODEX_BIN"
    )


def ensure_pairing_start_returns_manual_code(codex_binary: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="codex-pairing-protocol-") as tmp:
        result = subprocess.run(
            [
                str(codex_binary),
                "app-server",
                "generate-ts",
                "--out",
                tmp,
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )
        if result.returncode != 0:
            message = result.stderr.strip() or result.stdout.strip()
            raise PairingError(
                "could not verify Codex app-server pairing protocol before live issuance: "
                + redact_pairing_payload(message or "generate-ts failed")
            )

        response_files = list(Path(tmp).rglob("RemoteControlPairingStartResponse.ts"))
        if not response_files:
            raise PairingError(
                "Codex app-server protocol does not expose "
                "RemoteControlPairingStartResponse; refusing live issuance before "
                "starting app-server"
            )

        response_schema = "\n".join(
            path.read_text(encoding="utf-8", errors="replace")
            for path in response_files
        )
        if "manualPairingCode" not in response_schema:
            raise PairingError(
                "Codex app-server protocol does not expose manualPairingCode in "
                "RemoteControlPairingStartResponse; refusing live issuance before "
                "starting app-server"
            )


def make_private_runtime_paths() -> RuntimePaths:
    session_name = f"{DEFAULT_SESSION}-{os.getpid()}-{secrets.token_hex(4)}"
    runtime_override = os.environ.get("CODEX_PAIRING_RUNTIME_DIR")
    if runtime_override:
        base = Path(runtime_override).expanduser()
    else:
        base = Path("/private/tmp") if platform.system() == "Darwin" else Path(tempfile.gettempdir())

    old_umask = os.umask(0o077)
    try:
        base.mkdir(mode=0o700, parents=True, exist_ok=True)
        root = Path(tempfile.mkdtemp(prefix="codex-pairing-code-", dir=str(base)))
    finally:
        os.umask(old_umask)

    st = root.stat()
    if st.st_uid != os.getuid():
        raise PairingError(f"runtime directory is not owned by current user: {root}")
    if stat.S_IMODE(st.st_mode) & 0o077:
        root.chmod(0o700)

    return RuntimePaths(
        root=root,
        socket_path=root / "app.sock",
        log_path=root / "app-server.log",
        session_name=session_name,
    )


def _tmux_has_session(session_name: str) -> bool:
    result = subprocess.run(
        ["tmux", "has-session", "-t", session_name],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def _socket_connects(socket_path: Path, timeout: float = 0.25) -> bool:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(str(socket_path))
            return True
    except OSError:
        return False


def ensure_helper_app_server(codex_binary: Path, paths: RuntimePaths, timeout: float) -> None:
    if not shutil.which("tmux"):
        raise PairingError("tmux is required to keep the helper-owned app-server alive")

    if _tmux_has_session(paths.session_name):
        raise PairingError(
            "helper tmux session already exists; clean it up before retrying: "
            f"tmux kill-session -t {paths.session_name}"
        )

    if paths.socket_path.exists():
        paths.socket_path.unlink()

    listen_arg = f"unix://{paths.socket_path}"
    command = " ".join(
        [
            shlex.quote(str(codex_binary)),
            "app-server",
            "--listen",
            shlex.quote(listen_arg),
            f"2>{shlex.quote(str(paths.log_path))}",
        ]
    )
    result = subprocess.run(
        ["tmux", "new-session", "-d", "-s", paths.session_name, command],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise PairingError(redact_pairing_payload(result.stderr.strip() or "tmux failed"))

    _wait_for_socket(paths.socket_path, timeout)


def _wait_for_socket(socket_path: Path, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if socket_path.exists() and _socket_connects(socket_path):
            return
        time.sleep(0.1)
    raise PairingError(f"app-server socket did not become ready: {socket_path}")


def _websocket_accept_value(key: str) -> str:
    digest = hashlib.sha1((key + WEBSOCKET_GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def _encode_ws_frame(payload: bytes, opcode: int = 0x1, mask: bool = True) -> bytes:
    first = 0x80 | (opcode & 0x0F)
    length = len(payload)
    header = bytearray([first])
    mask_bit = 0x80 if mask else 0
    if length < 126:
        header.append(mask_bit | length)
    elif length <= 0xFFFF:
        header.append(mask_bit | 126)
        header.extend(struct.pack("!H", length))
    else:
        header.append(mask_bit | 127)
        header.extend(struct.pack("!Q", length))

    if not mask:
        return bytes(header) + payload

    masking_key = secrets.token_bytes(4)
    masked = bytes(byte ^ masking_key[index % 4] for index, byte in enumerate(payload))
    return bytes(header) + masking_key + masked


def _recv_exact(sock: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        try:
            chunk = sock.recv(size - len(chunks))
        except OSError as error:
            raise PairingError(f"WebSocket receive failed: {error}") from error
        if not chunk:
            raise PairingError("connection closed while reading WebSocket frame")
        chunks.extend(chunk)
    return bytes(chunks)


def _read_ws_frame(sock: socket.socket) -> tuple[int, bytes]:
    first_two = _recv_exact(sock, 2)
    first, second = first_two
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", _recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", _recv_exact(sock, 8))[0]

    masking_key = _recv_exact(sock, 4) if masked else b""
    payload = _recv_exact(sock, length) if length else b""
    if masked:
        payload = bytes(byte ^ masking_key[index % 4] for index, byte in enumerate(payload))
    return opcode, payload


class WsUnixClient:
    def __init__(self, socket_path: Path, timeout: float) -> None:
        self.socket_path = socket_path
        self.timeout = timeout
        self.sock: socket.socket | None = None

    def __enter__(self) -> "WsUnixClient":
        self.connect()
        return self

    def __exit__(self, _exc_type: Any, _exc: Any, _tb: Any) -> None:
        self.close()

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        try:
            sock.connect(str(self.socket_path))
            key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
            request = (
                "GET /rpc HTTP/1.1\r\n"
                "Host: localhost\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n"
                "\r\n"
            )
            sock.sendall(request.encode("ascii"))
            response = self._read_http_response(sock)
            self._verify_handshake(response, key)
            self.sock = sock
        except PairingError:
            sock.close()
            raise
        except OSError as error:
            sock.close()
            raise PairingError(f"WebSocket connection failed: {error}") from error
        except Exception:
            sock.close()
            raise

    def _read_http_response(self, sock: socket.socket) -> str:
        data = bytearray()
        while b"\r\n\r\n" not in data:
            chunk = sock.recv(4096)
            if not chunk:
                raise PairingError("connection closed during WebSocket handshake")
            data.extend(chunk)
            if len(data) > 65536:
                raise PairingError("WebSocket handshake response too large")
        return data.decode("iso-8859-1")

    def _verify_handshake(self, response: str, key: str) -> None:
        lines = response.split("\r\n")
        if not lines or " 101 " not in lines[0]:
            raise PairingError(f"WebSocket upgrade failed: {lines[0] if lines else 'no status'}")
        headers: dict[str, str] = {}
        for line in lines[1:]:
            if ":" in line:
                name, value = line.split(":", 1)
                headers[name.strip().lower()] = value.strip()
        expected = _websocket_accept_value(key)
        if headers.get("sec-websocket-accept") != expected:
            raise PairingError("WebSocket Sec-WebSocket-Accept verification failed")

    def send_text(self, text: str) -> None:
        if self.sock is None:
            raise PairingError("WebSocket is not connected")
        try:
            self.sock.sendall(_encode_ws_frame(text.encode("utf-8"), opcode=0x1, mask=True))
        except OSError as error:
            raise PairingError(f"WebSocket send failed: {error}") from error

    def receive_text(self) -> str:
        if self.sock is None:
            raise PairingError("WebSocket is not connected")
        while True:
            opcode, payload = _read_ws_frame(self.sock)
            if opcode == 0x1:
                try:
                    return payload.decode("utf-8")
                except UnicodeDecodeError as error:
                    raise PairingError("WebSocket text frame is not valid UTF-8") from error
            if opcode == 0x8:
                raise PairingError("WebSocket closed by app-server")
            if opcode == 0x9:
                self.sock.sendall(_encode_ws_frame(payload, opcode=0xA, mask=True))
                continue
            if opcode == 0xA:
                continue
            raise PairingError(f"unsupported WebSocket opcode: {opcode}")

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.sendall(_encode_ws_frame(b"", opcode=0x8, mask=True))
            except OSError:
                pass
            self.sock.close()
            self.sock = None


class JsonRpcClient:
    def __init__(self, ws: WsUnixClient) -> None:
        self.ws = ws
        self.next_id = 1

    def request(self, method: str, params: dict[str, Any] | None = None) -> Any:
        request_id = self.next_id
        self.next_id += 1
        message: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self.ws.send_text(json.dumps(message, separators=(",", ":")))
        while True:
            raw = self.ws.receive_text()
            try:
                response = json.loads(raw)
            except json.JSONDecodeError as error:
                raise PairingError("JSON-RPC response is not valid JSON") from error
            if not isinstance(response, dict):
                raise PairingError("JSON-RPC response is not an object")
            if response.get("id") != request_id:
                continue
            if "error" in response:
                raise PairingError(redact_pairing_payload(json.dumps(response["error"])))
            return response.get("result")

    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        message: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.ws.send_text(json.dumps(message, separators=(",", ":")))


def issue_pairing_code(socket_path: Path, timeout: float, cleanup_command: str) -> PairingResult:
    with WsUnixClient(socket_path, timeout) as ws:
        rpc = JsonRpcClient(ws)
        rpc.request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": CLIENT_NAME, "version": CLIENT_VERSION},
            },
        )
        rpc.notify("initialized", {})
        rpc.request("remoteControl/enable", {"ephemeral": True})
        result = rpc.request("remoteControl/pairing/start", {"manualCode": True})

    if not isinstance(result, dict):
        raise PairingError("pairing/start returned a non-object result")
    manual_code = result.get("manualPairingCode")
    expires_at = result.get("expiresAt")
    if not isinstance(manual_code, str) or not manual_code:
        raise PairingError("pairing/start result did not include manualPairingCode")
    if expires_at is None:
        raise PairingError("pairing/start result did not include expiresAt")
    return PairingResult(manual_code, expires_at, cleanup_command)


def format_expiry_kst(expires_at: Any) -> str:
    kst = dt.timezone(dt.timedelta(hours=9), "KST")
    if isinstance(expires_at, str):
        if expires_at.isdigit():
            timestamp = int(expires_at)
        else:
            try:
                parsed = dt.datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
            except ValueError as error:
                raise PairingError("expiresAt string is not a valid timestamp") from error
            return parsed.astimezone(kst).strftime("%Y-%m-%d %H:%M:%S %Z")
    elif isinstance(expires_at, (int, float)):
        timestamp = float(expires_at)
    else:
        raise PairingError("unsupported expiresAt type")

    if timestamp > 10_000_000_000:
        timestamp = timestamp / 1000
    try:
        return dt.datetime.fromtimestamp(timestamp, tz=kst).strftime("%Y-%m-%d %H:%M:%S %Z")
    except (OSError, OverflowError, ValueError) as error:
        raise PairingError("expiresAt value is out of supported range") from error


def redact_pairing_payload(value: str) -> str:
    redacted = SECRET_KEY_RE.sub(r"\1[REDACTED]\2", value)
    return CODE_RE.sub("[PAIRING-CODE]", redacted)


def build_mock_result() -> PairingResult:
    return PairingResult(
        manual_pairing_code="MOCK-0000",
        expires_at=MOCK_EXPIRES_AT,
        cleanup_command="true # mock mode has no live session",
    )


def print_result(result: PairingResult, as_json: bool) -> None:
    expires_at_kst = format_expiry_kst(result.expires_at)
    if as_json:
        print(
            json.dumps(
                {
                    "manualPairingCode": result.manual_pairing_code,
                    "expiresAt": result.expires_at,
                    "expiresAtKst": expires_at_kst,
                    "cleanup": result.cleanup_command,
                },
                separators=(",", ":"),
            )
        )
        return

    print(f"Code: {result.manual_pairing_code}")
    print(f"Expires: {expires_at_kst}")
    print(f"Cleanup: {result.cleanup_command}")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    cleanup_command: str | None = None
    try:
        ensure_consent(args)
        ensure_live_platform_allowed(args.mock)
        if args.mock:
            print_result(build_mock_result(), args.json)
            return 0

        codex_binary = select_codex_binary()
        ensure_pairing_start_returns_manual_code(codex_binary)
        paths = make_private_runtime_paths()
        cleanup_command = (
            f"tmux kill-session -t {shlex.quote(paths.session_name)}; "
            f"rm -rf {shlex.quote(str(paths.root))}"
        )
        ensure_helper_app_server(codex_binary, paths, args.timeout)
        result = issue_pairing_code(paths.socket_path, args.timeout, cleanup_command)
        print_result(result, args.json)
        return 0
    except PairingError as error:
        print(f"error: {redact_pairing_payload(str(error))}", file=sys.stderr)
        if cleanup_command is not None:
            print(f"Cleanup: {cleanup_command}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
