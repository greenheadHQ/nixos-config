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
import math
import os
import platform
import re
import select
import secrets
import shlex
import shutil
import signal
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
RUNTIME_KIND = "codex-pairing-runtime-v1"
CONTROL_LIMIT = 4096
CLIENT_NAME = "issuing-codex-pairing-code"
CLIENT_VERSION = "1.0.0"
MOCK_EXPIRES_AT = 1893456000
INITIALIZE_METHOD = "initialize"
INITIALIZED_NOTIFICATION_METHOD = "initialized"
REMOTE_CONTROL_ENABLE_METHOD = "remoteControl/enable"
PAIRING_START_METHOD = "remoteControl/pairing/start"
CODE_RE = re.compile(r"\b[A-Z0-9]{4}-[A-Z0-9]{4}\b")
SECRET_KEY_RE = re.compile(
    r'("(?:(?:manual)?pairingCode|environmentId|'
    r'[A-Za-z0-9_-]*(?:token|secret)[A-Za-z0-9_-]*|'
    r'[A-Za-z0-9_-]*api[_-]?key[A-Za-z0-9_-]*|'
    r'key|authorization|CODEX_API_KEY)"\s*:\s*")[^"]+(")',
    re.IGNORECASE,
)
BEARER_TOKEN_RE = re.compile(r"\bBearer\s+[-._~+/A-Za-z0-9]+=*", re.IGNORECASE)
OPENAI_KEY_RE = re.compile(r"\bsk-[A-Za-z0-9_-]{12,}\b")
SECRET_ASSIGNMENT_RE = re.compile(
    r"\b([A-Za-z0-9_-]*(?:token|secret|api[_-]?key|key)[A-Za-z0-9_-]*"
    r"\s*[:=]\s*)([^\s,;]+)",
    re.IGNORECASE,
)


class PairingError(RuntimeError):
    """User-facing helper failure with secret-safe messaging."""


@dataclasses.dataclass(frozen=True)
class RuntimePaths:
    root: Path
    socket_path: Path
    control_path: Path
    instance_id: str


@dataclasses.dataclass
class HelperServer:
    """발급 완료 전에는 호출자 연결을, 완료 후에는 명시적 정리를 따른다."""

    process: subprocess.Popen[bytes]
    lease: socket.socket
    paths: RuntimePaths
    timeout: float

    def retain(self) -> None:
        _send_control(self.lease, {"action": "retain"})
        if _receive_control(self.lease) != {"state": "retained"}:
            raise PairingError("helper ownership handoff failed")
        self.lease.close()

    def abort(self) -> None:
        # 인계 전 EOF는 supervisor가 직접 생성한 자식의 회수를 요청한다.
        self.lease.close()
        try:
            cleanup_runtime(self.paths.root, self.timeout)
        except PairingError:
            pass
        try:
            self.process.wait(timeout=self.timeout + 3)
        except subprocess.TimeoutExpired as error:
            # 저장 PID나 부모 프로세스 트리 추측으로 종료하지 않는다.
            raise PairingError("helper shutdown could not be confirmed") from error


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
        help="Return deterministic fixture output without live Codex or sockets.",
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
    parser.add_argument(
        "--cleanup", type=Path,
        help="Stop only the helper instance owning this private runtime directory.",
    )
    parser.add_argument("--supervise-fd", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be a positive finite number")
    if args.cleanup is not None and (args.mock or args.user_requested_code or args.json):
        parser.error("--cleanup cannot be combined with issuance flags")
    if args.supervise_fd is not None and (
        args.cleanup is not None or args.mock or args.user_requested_code or args.json
    ):
        parser.error("internal supervisor mode cannot be combined with other actions")
    return args


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
            return candidate.resolve()

    raise PairingError(
        "could not find an executable Codex binary; set CODEX_PAIRING_CODEX_BIN"
    )


def run_checked(
    command: list[str],
    *,
    timeout: float,
    stdout: Any = subprocess.PIPE,
    stderr: Any = subprocess.PIPE,
    text: bool = True,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            text=text,
            stdout=stdout,
            stderr=stderr,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        program = Path(command[0]).name if command else "command"
        raise PairingError(f"{program} timed out after {timeout:g}s") from error


def ensure_pairing_start_returns_manual_code(codex_binary: Path, timeout: float) -> None:
    # remoteControl/pairing/* 은 experimental API라 --experimental 없이는
    # generate-ts 출력에서 필터링된다 (stable-only가 기본). 플래그 없이 검사하면
    # 기능이 실존하는 버전에서도 항상 fail closed된다.
    with tempfile.TemporaryDirectory(prefix="codex-pairing-protocol-") as tmp:
        result = run_checked(
            [
                str(codex_binary),
                "app-server",
                "generate-ts",
                "--experimental",
                "--out",
                tmp,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
        if result.returncode != 0:
            message = result.stderr.strip() or result.stdout.strip()
            raise PairingError(
                "could not verify Codex app-server pairing protocol before live issuance: "
                + redact_pairing_payload(message or "generate-ts failed")
            )

        # needle은 pairing 계약의 핵심(메서드 노출 + 요청/응답 필드)으로 한정한다.
        # 그 밖의 타입/필드 검사는 ts-rs 출력 포맷에 결합되어, pairing과 무관한
        # 포맷 변화만으로 false negative(부당한 fail closed)를 만든다.
        generated_root = Path(tmp)
        client_request_schema = _read_protocol_schema(
            generated_root, "ClientRequest.ts", "ClientRequest"
        )
        enable_params_schema = _read_protocol_schema(
            generated_root, "RemoteControlEnableParams.ts", "RemoteControlEnableParams"
        )
        pairing_params_schema = _read_protocol_schema(
            generated_root,
            "RemoteControlPairingStartParams.ts",
            "RemoteControlPairingStartParams",
        )
        response_schema = _read_protocol_schema(
            generated_root,
            "RemoteControlPairingStartResponse.ts",
            "RemoteControlPairingStartResponse",
        )

        for schema, needle, type_name, requirement in (
            (
                client_request_schema,
                f'"method": "{REMOTE_CONTROL_ENABLE_METHOD}"',
                "ClientRequest",
                REMOTE_CONTROL_ENABLE_METHOD,
            ),
            (
                client_request_schema,
                f'"method": "{PAIRING_START_METHOD}"',
                "ClientRequest",
                PAIRING_START_METHOD,
            ),
            (
                enable_params_schema,
                "ephemeral",
                "RemoteControlEnableParams",
                "ephemeral",
            ),
            (
                pairing_params_schema,
                "manualCode",
                "RemoteControlPairingStartParams",
                "manualCode",
            ),
            (
                response_schema,
                "manualPairingCode",
                "RemoteControlPairingStartResponse",
                "manualPairingCode",
            ),
            (
                response_schema,
                "expiresAt",
                "RemoteControlPairingStartResponse",
                "expiresAt",
            ),
        ):
            _ensure_schema_contains(schema, needle, type_name, requirement)


def _read_protocol_schema(root: Path, filename: str, type_name: str) -> str:
    files = list(root.rglob(filename))
    if not files:
        raise PairingError(
            f"Codex app-server protocol does not expose {type_name} "
            "(checked with generate-ts --experimental); "
            "refusing live issuance before starting app-server"
        )
    return "\n".join(
        path.read_text(encoding="utf-8", errors="replace")
        for path in files
    )


def _ensure_schema_contains(
    schema: str, needle: str, type_name: str, requirement: str
) -> None:
    if needle not in schema:
        raise PairingError(
            "Codex app-server protocol does not expose "
            f"{requirement} in {type_name} "
            "(checked with generate-ts --experimental); "
            "refusing live issuance before starting app-server"
        )


def make_private_runtime_paths() -> RuntimePaths:
    runtime_override = os.environ.get("CODEX_PAIRING_RUNTIME_DIR")
    if runtime_override:
        base = Path(runtime_override).expanduser()
    else:
        base = Path("/private/tmp") if platform.system() == "Darwin" else Path(tempfile.gettempdir())

    old_umask = os.umask(0o077)
    root: Path | None = None
    root_fd = -1
    root_identity: tuple[int, int] | None = None
    created: dict[str, tuple[int, int]] = {}
    try:
        base.mkdir(mode=0o700, parents=True, exist_ok=True)
        root = Path(tempfile.mkdtemp(prefix="codex-pairing-code-", dir=str(base.resolve())))
        root_identity = _identity(root.lstat())
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        if _identity(os.fstat(root_fd)) != root_identity:
            raise OSError("private helper runtime changed during creation")
        instance_id = secrets.token_hex(16)
        # 원본 worktree가 나중에 정리되어도 같은 구현으로 명시적 정리가 가능하다.
        for name, content in (
            ("helper.py", Path(__file__).read_bytes()),
            ("owner.json", json.dumps({"kind": RUNTIME_KIND, "instance": instance_id}).encode()),
        ):
            file_fd = os.open(
                name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600, dir_fd=root_fd,
            )
            created[name] = _identity(os.fstat(file_fd))
            with os.fdopen(file_fd, "wb") as output:
                output.write(content)
    except OSError:
        if root_fd != -1:
            for name, identity in created.items():
                try:
                    if _identity(os.stat(name, dir_fd=root_fd, follow_symlinks=False)) == identity:
                        os.unlink(name, dir_fd=root_fd)
                except OSError:
                    pass
        removed = root is None
        try:
            if root is not None and _identity(root.lstat()) == root_identity:
                root.rmdir()
                removed = True
        except FileNotFoundError:
            removed = True
        except OSError:
            pass
        message = "private helper runtime could not be created"
        if not removed:
            message += f"; inspect the preserved runtime manually: {root}"
        raise PairingError(message) from None
    finally:
        if root_fd != -1:
            os.close(root_fd)
        os.umask(old_umask)
    return RuntimePaths(
        root=root,
        socket_path=root / "app.sock",
        control_path=root / "control.sock",
        instance_id=instance_id,
    )


def _identity(info: os.stat_result) -> tuple[int, int]:
    return info.st_dev, info.st_ino


@dataclasses.dataclass
class PrivateRuntime:
    paths: RuntimePaths
    fd: int
    identity: tuple[int, int]
    marker_identity: tuple[int, int]
    helper_identity: tuple[int, int]

    def close(self) -> None:
        os.close(self.fd)


def _read_owner(fd: int) -> tuple[str, tuple[int, int]]:
    marker_fd = os.open(
        "owner.json", os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=fd
    )
    with os.fdopen(marker_fd, "r", encoding="utf-8") as marker:
        info = os.fstat(marker.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_size > CONTROL_LIMIT
        ):
            raise PairingError("invalid helper ownership marker")
        try:
            value = json.load(marker)
        except (ValueError, UnicodeError, RecursionError) as error:
            raise PairingError("invalid helper ownership marker") from error
    if (
        not isinstance(value, dict)
        or set(value) != {"kind", "instance"}
        or value.get("kind") != RUNTIME_KIND
        or not isinstance(value.get("instance"), str)
        or re.fullmatch(r"[0-9a-f]{32}", value["instance"]) is None
    ):
        raise PairingError("invalid helper ownership marker")
    return value["instance"], _identity(info)


def _open_runtime(root: Path) -> PrivateRuntime:
    fd = -1
    try:
        # canonical 경로만 수용해 상위 또는 마지막 요소의 symlink 우회도 거부한다.
        if (
            not root.is_absolute()
            or str(root) != os.path.realpath(root)
            or not root.name.startswith("codex-pairing-code-")
        ):
            raise PairingError("cleanup requires the original private helper runtime")
        fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise PairingError("helper runtime ownership or permissions changed")
        instance_id, marker_identity = _read_owner(fd)
        helper_identity = _helper_identity(fd)
        paths = RuntimePaths(root, root / "app.sock", root / "control.sock", instance_id)
        return PrivateRuntime(paths, fd, _identity(info), marker_identity, helper_identity)
    except (OSError, ValueError, TypeError, PairingError) as error:
        if fd != -1:
            os.close(fd)
        raise PairingError("private helper runtime could not be verified") from error


def _helper_identity(fd: int) -> tuple[int, int]:
    info = os.stat("helper.py", dir_fd=fd, follow_symlinks=False)
    if (
        not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o600
    ):
        raise PairingError("private helper copy could not be verified")
    return _identity(info)


def _verify_runtime(runtime: PrivateRuntime) -> None:
    info = runtime.paths.root.lstat()
    instance_id, marker_identity = _read_owner(runtime.fd)
    if (
        not stat.S_ISDIR(info.st_mode)
        or _identity(info) != runtime.identity
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o700
        or marker_identity != runtime.marker_identity
        or _helper_identity(runtime.fd) != runtime.helper_identity
        or instance_id != runtime.paths.instance_id
    ):
        raise PairingError("helper runtime changed; refusing cleanup")


def _socket_identity(runtime: PrivateRuntime, name: str) -> tuple[int, int]:
    info = os.stat(name, dir_fd=runtime.fd, follow_symlinks=False)
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        raise PairingError("helper socket could not be verified")
    return _identity(info)


def _remove_runtime(
    runtime: PrivateRuntime, owned_sockets: dict[str, tuple[int, int]]
) -> bool:
    """검증 시점의 소유권·inode 일치를 요구하며 추가 파일·변경된 runtime은 보존한다."""
    try:
        _verify_runtime(runtime)
        for name, expected in owned_sockets.items():
            try:
                if _socket_identity(runtime, name) != expected:
                    return False
            except FileNotFoundError:
                pass
        # 알 수 없는 파일이 있으면 표식도 남겨 후속 수동 확인이 가능하게 한다.
        if set(os.listdir(runtime.fd)) - {"owner.json", "helper.py", *owned_sockets}:
            return False
        for name in owned_sockets:
            try:
                os.unlink(name, dir_fd=runtime.fd)
            except FileNotFoundError:
                pass
        _verify_runtime(runtime)
        os.unlink("helper.py", dir_fd=runtime.fd)
        os.unlink("owner.json", dir_fd=runtime.fd)
        os.rmdir(runtime.paths.root)
        return True
    except (OSError, ValueError, TypeError, PairingError):
        return False


def _send_control(connection: socket.socket, message: dict[str, Any]) -> None:
    payload = json.dumps(message, separators=(",", ":")).encode()
    if len(payload) > CONTROL_LIMIT:
        raise PairingError("helper control message exceeds the size limit")
    connection.sendall(payload + b"\n")


def _receive_control(connection: socket.socket) -> dict[str, Any]:
    data = bytearray()
    original_timeout = connection.gettimeout()
    deadline = time.monotonic() + (original_timeout if original_timeout is not None else 2)
    try:
        while len(data) <= CONTROL_LIMIT:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise PairingError("helper control request timed out")
            connection.settimeout(remaining)
            chunk = connection.recv(1)
            if not chunk:
                raise PairingError("helper control connection closed")
            if chunk == b"\n":
                try:
                    message = json.loads(data)
                except (ValueError, UnicodeError, RecursionError) as error:
                    raise PairingError("invalid helper control response") from error
                if not isinstance(message, dict):
                    raise PairingError("invalid helper control response")
                return message
            data.extend(chunk)
        raise PairingError("helper control message exceeds the size limit")
    finally:
        connection.settimeout(original_timeout)


def cleanup_runtime(root: Path, timeout: float = 10.0) -> None:
    runtime = _open_runtime(root)
    try:
        _verify_runtime(runtime)
        _socket_identity(runtime, "control.sock")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(timeout + 3)
            connection.connect(str(runtime.paths.control_path))
            _send_control(connection, {"action": "stop", "instance": runtime.paths.instance_id})
            try:
                result = _receive_control(connection)
            except PairingError as error:
                raise PairingError("helper cleanup completion could not be confirmed") from error
        if result != {"state": "stopped", "removed": True}:
            if result.get("state") == "stopped":
                raise PairingError("helper stopped; changed or additional runtime files were preserved")
            raise PairingError("helper cleanup refused; ownership could not be verified")
    except (OSError, ValueError, TypeError) as error:
        raise PairingError("helper cleanup completion could not be confirmed") from error
    finally:
        runtime.close()


def _stop_child(child: subprocess.Popen[bytes]) -> None:
    # 이 프로세스가 직접 생성해 아직 wait하지 않은 자식만 종료한다.
    # 외부 PID나 프로세스 목록·프로세스 그룹을 정리 대상으로 사용하지 않는다.
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def _run_supervisor(fd: int) -> int:
    runtime: PrivateRuntime | None = None
    child: subprocess.Popen[bytes] | None = None
    listener: socket.socket | None = None
    requester: socket.socket | None = None
    owned_sockets: dict[str, tuple[int, int]] = {}
    lease: socket.socket | None = None
    retained = False
    ready = False
    owns_runtime = False
    result = 1
    stop_requested = False

    def request_stop(_signum: int, _frame: Any) -> None:
        nonlocal stop_requested
        stop_requested = True

    previous_sigterm = signal.signal(signal.SIGTERM, request_stop)
    try:
        if fd < 3 or not stat.S_ISSOCK(os.fstat(fd).st_mode):
            raise PairingError("internal supervisor requires an inherited socket")
        lease = socket.socket(fileno=fd)
        lease.settimeout(2)
        request = _receive_control(lease)
        if set(request) != {"runtime", "instance", "command", "timeout"}:
            raise PairingError("invalid internal supervisor request")
        command = request["command"]
        timeout = request["timeout"]
        if (
            not isinstance(command, list) or not command
            or any(not isinstance(value, str) or "\x00" in value for value in command)
            or isinstance(timeout, bool) or not isinstance(timeout, (int, float))
            or not math.isfinite(timeout) or timeout <= 0
            or not isinstance(request["runtime"], str)
        ):
            raise PairingError("invalid internal supervisor request")
        runtime = _open_runtime(Path(request["runtime"]))
        if request["instance"] != runtime.paths.instance_id:
            raise PairingError("internal supervisor ownership mismatch")
        if set(os.listdir(runtime.fd)) != {"owner.json", "helper.py"}:
            raise PairingError("helper runtime is already in use")
        owns_runtime = True
        if stop_requested:
            raise PairingError("helper supervisor interrupted")
        # 호출자의 worktree를 cwd로 붙잡지 않고, 요청 FD는 자식에 넘기지 않는다.
        os.fchdir(runtime.fd)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(runtime.paths.control_path))
        os.chmod(runtime.paths.control_path, 0o600)
        owned_sockets["control.sock"] = _socket_identity(runtime, "control.sock")
        listener.listen(4)
        child = subprocess.Popen(
            command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, close_fds=True,
        )
        deadline = time.monotonic() + timeout
        while child.poll() is None and not stop_requested:
            if not ready:
                try:
                    owned_sockets["app.sock"] = _socket_identity(runtime, "app.sock")
                except FileNotFoundError:
                    pass
                else:
                    if _socket_connects(runtime.paths.socket_path):
                        _send_control(lease, {"state": "ready"})
                        ready = True
                if not ready and time.monotonic() >= deadline:
                    raise PairingError("app-server did not become ready")
            readable, _, _ = select.select(
                [listener] + ([] if retained else [lease]), [], [], 0.05
            )
            if not retained and lease in readable:
                message = _receive_control(lease)
                if not ready or message != {"action": "retain"}:
                    raise PairingError("invalid helper ownership handoff")
                _send_control(lease, {"state": "retained"})
                retained = True
                lease.close()
            if listener in readable:
                connection, _ = listener.accept()
                connection.settimeout(0.2)
                try:
                    message = _receive_control(connection)
                    _verify_runtime(runtime)
                    if message != {"action": "stop", "instance": runtime.paths.instance_id}:
                        raise PairingError("invalid helper cleanup request")
                except (OSError, ValueError, TypeError, PairingError):
                    try:
                        _send_control(connection, {"state": "refused"})
                    except OSError:
                        pass
                    connection.close()
                else:
                    requester = connection
                    result = 0
                    break
        if child.returncode is not None and ready:
            result = 0
    except (OSError, ValueError, TypeError, PairingError):
        if lease is not None and not retained:
            try:
                _send_control(lease, {"state": "failed"})
            except OSError:
                pass
    finally:
        try:
            if child is not None:
                _stop_child(child)
            if listener is not None:
                listener.close()
            if lease is not None:
                lease.close()
            removed = False
            if runtime is not None:
                # 준비 직후 종료된 자식이 남긴 socket도 타입을 확인한 뒤에만 회수한다.
                if child is not None and "app.sock" not in owned_sockets:
                    try:
                        owned_sockets["app.sock"] = _socket_identity(runtime, "app.sock")
                    except (OSError, PairingError):
                        pass
                if owns_runtime:
                    removed = _remove_runtime(runtime, owned_sockets)
                runtime.close()
            if requester is not None:
                try:
                    _send_control(requester, {"state": "stopped", "removed": removed})
                except OSError:
                    pass
                requester.close()
        finally:
            signal.signal(signal.SIGTERM, previous_sigterm)
    return result


def _socket_connects(socket_path: Path, timeout: float = 0.25) -> bool:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(str(socket_path))
            return True
    except OSError:
        return False


def start_helper_process(
    command: list[str], paths: RuntimePaths, timeout: float
) -> HelperServer:
    runtime = _open_runtime(paths.root)
    process: subprocess.Popen[bytes] | None = None
    owns_runtime = False
    lease: socket.socket | None = None
    inherited: socket.socket | None = None
    try:
        if paths != runtime.paths:
            raise PairingError("helper runtime does not match its ownership marker")
        owns_runtime = True
        lease, inherited = socket.socketpair()
        lease.settimeout(timeout + 2)
        # 완전한 유한 요청을 먼저 큐에 넣어 spawn 직후 호출자가 종료돼도
        # supervisor가 runtime 소유권을 확인하고 자기 자식을 회수할 수 있게 한다.
        _send_control(lease, {
            "runtime": str(paths.root), "instance": paths.instance_id,
            "command": command, "timeout": timeout,
        })
        process = subprocess.Popen(
            [sys.executable, str(paths.root / "helper.py"), "--supervise-fd", str(inherited.fileno())],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            close_fds=True, pass_fds=(inherited.fileno(),), start_new_session=True,
            cwd=paths.root,
        )
        inherited.close()
        if _receive_control(lease) != {"state": "ready"}:
            raise PairingError("helper app-server failed to start")
        return HelperServer(process, lease, paths, timeout)
    except (OSError, ValueError, TypeError, PairingError) as error:
        if lease is not None:
            lease.close()
        if process is not None:
            try:
                process.wait(timeout=timeout + 3)
                # 요청 해석 전 supervisor가 끝났다면 아직 비어 있는 자기 runtime만 회수한다.
                # socket이나 추가 파일이 남은 경우 _remove_runtime이 보존한다.
                if owns_runtime:
                    _remove_runtime(runtime, {})
            except subprocess.TimeoutExpired:
                pass
        elif owns_runtime:
            _remove_runtime(runtime, {})
        raise PairingError("helper app-server failed to start; no code was issued") from error
    finally:
        if inherited is not None:
            inherited.close()
        runtime.close()


def ensure_helper_app_server(
    codex_binary: Path, paths: RuntimePaths, timeout: float
) -> HelperServer:
    return start_helper_process(
        [str(codex_binary), "app-server", "--listen", f"unix://{paths.socket_path}"],
        paths, timeout,
    )


def cleanup_command_for(paths: RuntimePaths) -> str:
    fallback = (
        "import os,sys; "
        "sys.version_info >= (3,9) or sys.exit('Cleanup requires Python 3.9 or newer'); "
        "os.execv(sys.executable, [sys.executable, *sys.argv[1:]])"
    )
    launcher = (
        'preferred=$1; shift; '
        'if [ -x "$preferred" ]; then exec "$preferred" "$@"; fi; '
        f'exec python3 -c {shlex.quote(fallback)} "$@"'
    )
    return shlex.join([
        "/bin/sh", "-c", launcher, "codex-pairing-cleanup",
        sys.executable, str(paths.root / "helper.py"), "--cleanup", str(paths.root),
    ])


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
        deadline = time.monotonic() + self.timeout
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
            response = self._read_http_response(sock, deadline)
            self._verify_handshake(response, key)
            sock.settimeout(self.timeout)
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

    def _read_http_response(self, sock: socket.socket, deadline: float) -> str:
        # per-recv timeout만으로는 서버가 timeout보다 짧은 간격으로 바이트를
        # 흘리면 handshake 전체가 --timeout을 초과할 수 있다. recv마다 남은
        # 시간으로 재설정해 handshake 전체를 하나의 deadline에 묶는다.
        data = bytearray()
        while b"\r\n\r\n" not in data:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise PairingError("WebSocket handshake timed out")
            sock.settimeout(remaining)
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

    def receive_text(self, deadline: float | None = None) -> str:
        if self.sock is None:
            raise PairingError("WebSocket is not connected")
        previous_timeout = self.sock.gettimeout()
        try:
            while True:
                if deadline is not None:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise PairingError("WebSocket receive deadline expired")
                    self.sock.settimeout(remaining)
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
        finally:
            if self.sock is not None:
                self.sock.settimeout(previous_timeout)

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.sendall(_encode_ws_frame(b"", opcode=0x8, mask=True))
            except OSError:
                pass
            self.sock.close()
            self.sock = None


class JsonRpcClient:
    def __init__(self, ws: WsUnixClient, timeout: float) -> None:
        self.ws = ws
        self.timeout = timeout
        self.next_id = 1

    def request(self, method: str, params: dict[str, Any] | None = None) -> Any:
        deadline = time.monotonic() + self.timeout
        request_id = self.next_id
        self.next_id += 1
        message: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self.ws.send_text(json.dumps(message, separators=(",", ":")))
        while True:
            if time.monotonic() >= deadline:
                raise PairingError(f"JSON-RPC request timed out after {self.timeout:g}s")
            try:
                raw = self.ws.receive_text(deadline=deadline)
            except PairingError as error:
                if time.monotonic() >= deadline:
                    raise PairingError(
                        f"JSON-RPC request timed out after {self.timeout:g}s"
                    ) from error
                raise
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
        rpc = JsonRpcClient(ws, timeout)
        rpc.request(
            INITIALIZE_METHOD,
            {
                # remoteControl/pairing/* 은 experimental capability opt-in이 없으면
                # -32600 "requires experimentalApi capability"로 거부된다 (0.142.5 실측).
                "capabilities": {
                    "experimentalApi": True,
                    "requestAttestation": False,
                },
                "clientInfo": {
                    "name": CLIENT_NAME,
                    "title": None,
                    "version": CLIENT_VERSION,
                },
            },
        )
        rpc.notify(INITIALIZED_NOTIFICATION_METHOD, {})
        rpc.request(REMOTE_CONTROL_ENABLE_METHOD, {"ephemeral": True})
        result = rpc.request(PAIRING_START_METHOD, {"manualCode": True})

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
    redacted = BEARER_TOKEN_RE.sub("Bearer [REDACTED]", redacted)
    redacted = OPENAI_KEY_RE.sub("[REDACTED-API-KEY]", redacted)
    redacted = SECRET_ASSIGNMENT_RE.sub(r"\1[REDACTED]", redacted)
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


def _interrupt_issuance(_signum: int, _frame: Any) -> None:
    raise PairingError("pairing-code issuance interrupted")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.supervise_fd is not None:
        return _run_supervisor(args.supervise_fd)
    cleanup_command: str | None = None
    server: HelperServer | None = None
    previous_sigterm: Any = None
    try:
        if args.cleanup is not None:
            cleanup_runtime(args.cleanup, args.timeout)
            print("Helper stopped and private runtime removed.")
            return 0
        ensure_consent(args)
        ensure_live_platform_allowed(args.mock)
        if args.mock:
            print_result(build_mock_result(), args.json)
            return 0

        codex_binary = select_codex_binary()
        ensure_pairing_start_returns_manual_code(codex_binary, args.timeout)
        paths = make_private_runtime_paths()
        cleanup_command = cleanup_command_for(paths)
        server = ensure_helper_app_server(codex_binary, paths, args.timeout)
        # 핸들을 얻은 뒤에는 SIGTERM도 finally의 명시적 회수를 거친다.
        # 정상 출력·flush 완료 뒤의 호출자 종료는 retained 서버에 영향을 주지 않는다.
        previous_sigterm = signal.signal(signal.SIGTERM, _interrupt_issuance)
        result = issue_pairing_code(paths.socket_path, args.timeout, cleanup_command)
        server.retain()
        print_result(result, args.json)
        sys.stdout.flush()
        server = None
        return 0
    except (OSError, PairingError) as error:
        print(f"error: {redact_pairing_payload(str(error))}", file=sys.stderr)
        if cleanup_command is not None:
            print(f"Cleanup: {cleanup_command}", file=sys.stderr)
        return 1
    finally:
        if previous_sigterm is not None:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            if server is not None:
                try:
                    server.abort()
                except PairingError as error:
                    print(f"error: {error}", file=sys.stderr)
        finally:
            if previous_sigterm is not None:
                signal.signal(signal.SIGTERM, previous_sigterm)


if __name__ == "__main__":
    raise SystemExit(main())
