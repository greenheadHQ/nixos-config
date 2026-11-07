#!/usr/bin/env python3

from __future__ import annotations

import base64
import contextlib
import errno
import importlib.util
import io
import json
import os
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "scripts"
    / "issue_pairing_code.py"
)
SPEC = importlib.util.spec_from_file_location("issue_pairing_code", SCRIPT)
assert SPEC and SPEC.loader
issue_pairing_code = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = issue_pairing_code
SPEC.loader.exec_module(issue_pairing_code)


class PairingCodeHelperTests(unittest.TestCase):
    def test_non_darwin_live_fails_before_binary_lookup(self) -> None:
        with mock.patch.object(issue_pairing_code.platform, "system", return_value="Linux"):
            with mock.patch.object(issue_pairing_code, "select_codex_binary") as select_binary:
                rc = _run_main_silent(["--user-requested-code", "--json"])
        self.assertEqual(rc, 1)
        select_binary.assert_not_called()

    def test_missing_consent_fails_before_live_work(self) -> None:
        with mock.patch.object(issue_pairing_code.platform, "system", return_value="Darwin"):
            with mock.patch.object(issue_pairing_code, "select_codex_binary") as select_binary:
                rc = _run_main_silent(["--json"])
        self.assertEqual(rc, 1)
        select_binary.assert_not_called()

    def test_mock_mode_skips_platform_and_binary_lookup(self) -> None:
        with mock.patch.object(issue_pairing_code.platform, "system", return_value="Linux"):
            with mock.patch.object(issue_pairing_code, "select_codex_binary") as select_binary:
                rc = _run_main_silent(["--mock", "--json"])
        self.assertEqual(rc, 0)
        select_binary.assert_not_called()

    def test_invalid_internal_fd_fails_without_starting_a_child(self) -> None:
        with mock.patch.object(issue_pairing_code.subprocess, "Popen") as start:
            self.assertEqual(_run_main_silent(["--supervise-fd", "-1"]), 1)
        start.assert_not_called()

    def test_websocket_accept_value(self) -> None:
        key = base64.b64encode(b"the sample nonce").decode("ascii")
        self.assertEqual(
            issue_pairing_code._websocket_accept_value(key),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        )

    def test_client_frame_is_masked(self) -> None:
        frame = issue_pairing_code._encode_ws_frame(b"hello", mask=True)
        self.assertTrue(frame[1] & 0x80)

    def test_handshake_request_does_not_offer_compression(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            socket_path = Path(tmp) / "app.sock"
            captured = {}
            ready = threading.Event()

            def server() -> None:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as srv:
                    srv.bind(str(socket_path))
                    srv.listen(1)
                    ready.set()
                    conn, _ = srv.accept()
                    with conn:
                        request = b""
                        while b"\r\n\r\n" not in request:
                            request += conn.recv(4096)
                        captured["request"] = request.decode("ascii")
                        key = _header_value(captured["request"], "Sec-WebSocket-Key")
                        accept = issue_pairing_code._websocket_accept_value(key)
                        conn.sendall(
                            (
                                "HTTP/1.1 101 Switching Protocols\r\n"
                                "Upgrade: websocket\r\n"
                                "Connection: Upgrade\r\n"
                                f"Sec-WebSocket-Accept: {accept}\r\n"
                                "\r\n"
                            ).encode("ascii")
                        )
                        issue_pairing_code._read_ws_frame(conn)

            thread = threading.Thread(target=server)
            thread.start()
            self.assertTrue(ready.wait(2), "server did not start in time")
            with issue_pairing_code.WsUnixClient(socket_path, 2):
                pass
            thread.join(2)
            self.assertFalse(thread.is_alive(), "server thread did not exit")
        self.assertNotIn("Sec-WebSocket-Extensions", captured["request"])

    def test_invalid_websocket_accept_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            socket_path = Path(tmp) / "app.sock"
            ready = threading.Event()

            def server() -> None:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as srv:
                    srv.bind(str(socket_path))
                    srv.listen(1)
                    ready.set()
                    conn, _ = srv.accept()
                    with conn:
                        request = b""
                        while b"\r\n\r\n" not in request:
                            request += conn.recv(4096)
                        conn.sendall(
                            (
                                "HTTP/1.1 101 Switching Protocols\r\n"
                                "Upgrade: websocket\r\n"
                                "Connection: Upgrade\r\n"
                                "Sec-WebSocket-Accept: invalid\r\n"
                                "\r\n"
                            ).encode("ascii")
                        )

            thread = threading.Thread(target=server)
            thread.start()
            self.assertTrue(ready.wait(2), "server did not start in time")
            with self.assertRaises(issue_pairing_code.PairingError):
                with issue_pairing_code.WsUnixClient(socket_path, 2):
                    pass
            thread.join(2)
            self.assertFalse(thread.is_alive(), "server thread did not exit")

    def test_handshake_enforces_overall_deadline(self) -> None:
        # 서버가 per-recv timeout보다 짧은 간격으로 바이트를 흘리는 drip-feed:
        # recv마다 윈도우가 리셋되면 handshake가 --timeout을 무한히 초과한다.
        with tempfile.TemporaryDirectory() as tmp:
            socket_path = Path(tmp) / "app.sock"
            ready = threading.Event()
            stop = threading.Event()

            def server() -> None:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as srv:
                    srv.bind(str(socket_path))
                    srv.listen(1)
                    ready.set()
                    conn, _ = srv.accept()
                    with conn:
                        request = b""
                        while b"\r\n\r\n" not in request:
                            request += conn.recv(4096)
                        while not stop.is_set():
                            try:
                                conn.sendall(b"H")
                            except OSError:
                                break
                            stop.wait(0.1)

            thread = threading.Thread(target=server)
            thread.start()
            self.assertTrue(ready.wait(2), "server did not start in time")
            started = time.monotonic()
            try:
                with self.assertRaises(issue_pairing_code.PairingError):
                    with issue_pairing_code.WsUnixClient(socket_path, 0.5):
                        pass
                elapsed = time.monotonic() - started
            finally:
                stop.set()
            thread.join(2)
            self.assertFalse(thread.is_alive(), "server thread did not exit")
        self.assertLess(elapsed, 5, "handshake was not bounded by a shared deadline")

    def test_redaction_removes_codes_and_secret_fields(self) -> None:
        raw = (
            '{"manualPairingCode":"MH67-9LKZ","pairingCode":"secret",'
            '"environmentId":"env-123","pairingToken":"tok-secret",'
            '"authToken":"auth-secret","accessToken":"access-secret",'
            '"CODEX_API_KEY":"sk-abcdefghijklmnopqrstuvwxyz","api_key":"api-secret",'
            '"x-api-key":"x-secret",'
            '"Authorization":"Bearer very-secret-token","other":"ABCD-1234"} '
            "token=plain-token key=plain-key secret:plain-secret"
        )
        redacted = issue_pairing_code.redact_pairing_payload(raw)
        self.assertNotIn("MH67-9LKZ", redacted)
        self.assertNotIn('"pairingCode":"secret"', redacted)
        self.assertNotIn("tok-secret", redacted)
        self.assertNotIn("auth-secret", redacted)
        self.assertNotIn("access-secret", redacted)
        self.assertNotIn("api-secret", redacted)
        self.assertNotIn("x-secret", redacted)
        self.assertNotIn("env-123", redacted)
        self.assertNotIn("sk-abcdefghijklmnopqrstuvwxyz", redacted)
        self.assertNotIn("very-secret-token", redacted)
        self.assertNotIn("plain-token", redacted)
        self.assertNotIn("plain-key", redacted)
        self.assertNotIn("plain-secret", redacted)
        self.assertNotIn("ABCD-1234", redacted)

    def test_runtime_dir_is_private(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            runtime_parent = Path(tmp) / "runtime-parent"
            with mock.patch.dict(os.environ, {"CODEX_PAIRING_RUNTIME_DIR": str(runtime_parent)}):
                paths = issue_pairing_code.make_private_runtime_paths()
            self.assertEqual(paths.root.parent, runtime_parent.resolve())
            self.assertRegex(paths.instance_id, r"^[0-9a-f]{32}$")
            self.assertTrue(paths.root.name.startswith("codex-pairing-code-"))
            self.assertEqual(paths.root.stat().st_mode & 0o077, 0)
            self.assertEqual((paths.root / "owner.json").stat().st_mode & 0o777, 0o600)

    def test_app_server_command_does_not_enable_analytics(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            paths = issue_pairing_code.RuntimePaths(
                root=Path(tmp),
                socket_path=Path(tmp) / "app.sock",
                control_path=Path(tmp) / "control.sock",
                instance_id="0" * 32,
            )
            with mock.patch.object(issue_pairing_code, "start_helper_process") as start:
                server = issue_pairing_code.ensure_helper_app_server(Path("/fixture/codex"), paths, 1)
                self.assertIs(server, start.return_value)
            command = start.call_args.args[0]
        self.assertEqual(command, ["/fixture/codex", "app-server", "--listen", f"unix://{paths.socket_path}"])
        self.assertNotIn("--analytics-default-enabled", command)

    def test_live_failure_after_runtime_creation_prints_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            paths = issue_pairing_code.RuntimePaths(
                root=Path(tmp),
                socket_path=Path(tmp) / "app.sock",
                control_path=Path(tmp) / "control.sock",
                instance_id="0" * 32,
            )
            with mock.patch.object(issue_pairing_code.platform, "system", return_value="Darwin"):
                with mock.patch.object(
                    issue_pairing_code, "select_codex_binary", return_value=Path("/bin/codex")
                ):
                    with mock.patch.object(issue_pairing_code, "ensure_pairing_start_returns_manual_code"):
                        with mock.patch.object(
                            issue_pairing_code, "make_private_runtime_paths", return_value=paths
                        ):
                            with mock.patch.object(issue_pairing_code, "ensure_helper_app_server") as start:
                                with mock.patch.object(
                                    issue_pairing_code,
                                    "issue_pairing_code",
                                    side_effect=issue_pairing_code.PairingError("rpc failed"),
                                ):
                                    rc, stdout, stderr = _run_main_capture(
                                        ["--user-requested-code"]
                                    )
        self.assertEqual(rc, 1)
        self.assertEqual(stdout, "")
        self.assertIn("error: rpc failed", stderr)
        self.assertIn("Cleanup: ", stderr)
        self.assertIn("--cleanup", stderr)
        start.return_value.abort.assert_called_once()
        start.return_value.retain.assert_not_called()

    def test_mock_result_is_deterministic(self) -> None:
        first = issue_pairing_code.build_mock_result()
        second = issue_pairing_code.build_mock_result()
        self.assertEqual(first, second)
        self.assertEqual(first.expires_at, issue_pairing_code.MOCK_EXPIRES_AT)

    def test_json_rpc_rejects_malformed_json(self) -> None:
        rpc = issue_pairing_code.JsonRpcClient(_FakeWs(["not-json"]), 1)
        with self.assertRaises(issue_pairing_code.PairingError):
            rpc.request("remoteControl/pairing/start", {"manualCode": True})

    def test_json_rpc_rejects_non_object_response(self) -> None:
        rpc = issue_pairing_code.JsonRpcClient(_FakeWs(["[]"]), 1)
        with self.assertRaises(issue_pairing_code.PairingError):
            rpc.request("remoteControl/pairing/start", {"manualCode": True})

    def test_json_rpc_error_is_redacted(self) -> None:
        response = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "error": {
                    "message": "failed",
                    "manualPairingCode": "MH67-9LKZ",
                    "pairingToken": "tok-secret",
                    "Authorization": "Bearer very-secret-token",
                },
            }
        )
        rpc = issue_pairing_code.JsonRpcClient(_FakeWs([response]), 1)
        with self.assertRaises(issue_pairing_code.PairingError) as caught:
            rpc.request("remoteControl/pairing/start", {"manualCode": True})
        message = str(caught.exception)
        self.assertNotIn("MH67-9LKZ", message)
        self.assertNotIn("tok-secret", message)
        self.assertNotIn("very-secret-token", message)
        self.assertIn("[REDACTED]", message)

    def test_json_rpc_ignores_mismatched_id_before_success(self) -> None:
        rpc = issue_pairing_code.JsonRpcClient(
            _FakeWs(
                [
                    json.dumps({"jsonrpc": "2.0", "id": 999, "result": {"ignored": True}}),
                    json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"ok": True}}),
                ]
            ),
            1,
        )
        self.assertEqual(rpc.request("initialize"), {"ok": True})

    def test_json_rpc_overall_deadline_rejects_endless_mismatched_ids(self) -> None:
        rpc = issue_pairing_code.JsonRpcClient(
            _FakeWs([json.dumps({"jsonrpc": "2.0", "id": 999, "result": {}})]),
            1,
        )
        with mock.patch.object(
            issue_pairing_code.time, "monotonic", side_effect=[0.0, 0.5, 1.1]
        ):
            with self.assertRaisesRegex(issue_pairing_code.PairingError, "timed out after 1s"):
                rpc.request("initialize")

    def test_format_expiry_rejects_malformed_string(self) -> None:
        with self.assertRaises(issue_pairing_code.PairingError):
            issue_pairing_code.format_expiry_kst("not-a-date")

    def test_format_expiry_kst_supported_inputs(self) -> None:
        cases = [
            (1893456000, "2030-01-01 09:00:00 KST"),
            (1893456000000, "2030-01-01 09:00:00 KST"),
            ("1893456000", "2030-01-01 09:00:00 KST"),
            ("2030-01-01T00:00:00Z", "2030-01-01 09:00:00 KST"),
        ]
        for value, expected in cases:
            with self.subTest(value=value):
                self.assertEqual(issue_pairing_code.format_expiry_kst(value), expected)

    def test_format_expiry_rejects_unsupported_and_out_of_range_values(self) -> None:
        with self.assertRaises(issue_pairing_code.PairingError):
            issue_pairing_code.format_expiry_kst([])
        with self.assertRaises(issue_pairing_code.PairingError):
            issue_pairing_code.format_expiry_kst(float("inf"))

    def test_mock_json_includes_expected_expiry_kst(self) -> None:
        rc, stdout, _stderr = _run_main_capture(["--mock", "--json"])
        self.assertEqual(rc, 0)
        payload = json.loads(stdout)
        self.assertEqual(payload["expiresAtKst"], "2030-01-01 09:00:00 KST")

    def test_rpc_sequence_extracts_manual_code_and_expiry(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            socket_path = Path(tmp) / "app.sock"
            seen_methods: list[str] = []
            seen_params: dict[str, object] = {}
            ready = threading.Event()

            def server() -> None:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as srv:
                    srv.bind(str(socket_path))
                    srv.listen(1)
                    ready.set()
                    conn, _ = srv.accept()
                    with conn:
                        request = b""
                        while b"\r\n\r\n" not in request:
                            request += conn.recv(4096)
                        key = _header_value(request.decode("ascii"), "Sec-WebSocket-Key")
                        accept = issue_pairing_code._websocket_accept_value(key)
                        conn.sendall(
                            (
                                "HTTP/1.1 101 Switching Protocols\r\n"
                                "Upgrade: websocket\r\n"
                                "Connection: Upgrade\r\n"
                                f"Sec-WebSocket-Accept: {accept}\r\n"
                                "\r\n"
                            ).encode("ascii")
                        )
                        while True:
                            opcode, payload = issue_pairing_code._read_ws_frame(conn)
                            if opcode == 0x8:
                                break
                            message = json.loads(payload.decode("utf-8"))
                            seen_methods.append(message["method"])
                            seen_params[message["method"]] = message.get("params")
                            if "id" not in message:
                                continue
                            if message["method"] == "remoteControl/pairing/start":
                                result = {
                                    "manualPairingCode": "MOCK-0000",
                                    "pairingCode": "raw-secret",
                                    "environmentId": "env-secret",
                                    "expiresAt": 1893456000,
                                }
                            else:
                                result = {}
                            response = json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result})
                            conn.sendall(
                                issue_pairing_code._encode_ws_frame(
                                    response.encode("utf-8"), mask=False
                                )
                            )

            thread = threading.Thread(target=server)
            thread.start()
            self.assertTrue(ready.wait(2), "server did not start in time")
            result = issue_pairing_code.issue_pairing_code(
                socket_path, 2, "fixture-cleanup"
            )
            thread.join(2)
            self.assertFalse(thread.is_alive(), "server thread did not exit")

        self.assertEqual(result.manual_pairing_code, "MOCK-0000")
        self.assertEqual(result.expires_at, 1893456000)
        self.assertEqual(
            seen_methods,
            [
                "initialize",
                "initialized",
                "remoteControl/enable",
                "remoteControl/pairing/start",
            ],
        )
        initialize_params = seen_params["initialize"]
        assert isinstance(initialize_params, dict)
        self.assertIs(initialize_params["capabilities"]["experimentalApi"], True)
        enable_params = seen_params["remoteControl/enable"]
        assert isinstance(enable_params, dict)
        self.assertIs(enable_params["ephemeral"], True)

    def test_binary_selection_honors_env_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "codex"
            binary.write_text("#!/bin/sh\n", encoding="utf-8")
            binary.chmod(0o700)
            with mock.patch.dict(os.environ, {"CODEX_PAIRING_CODEX_BIN": str(binary)}):
                self.assertEqual(issue_pairing_code.select_codex_binary(), binary.resolve())

    def test_relative_binary_override_is_fixed_before_supervisor_changes_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "synthetic-codex"
            binary.write_text("#!/bin/sh\n", encoding="utf-8")
            binary.chmod(0o700)
            relative = os.path.relpath(binary, Path.cwd())
            with mock.patch.dict(os.environ, {"CODEX_PAIRING_CODEX_BIN": relative}):
                self.assertEqual(issue_pairing_code.select_codex_binary(), binary.resolve())

    def test_protocol_check_accepts_manual_code_schema(self) -> None:
        def generate_schema(args: list[str], **_kwargs: object) -> mock.Mock:
            out_dir = Path(args[args.index("--out") + 1])
            _write_valid_protocol_schema(out_dir)
            return mock.Mock(returncode=0, stdout="", stderr="")

        with mock.patch.object(
            issue_pairing_code.subprocess, "run", side_effect=generate_schema
        ):
            issue_pairing_code.ensure_pairing_start_returns_manual_code(Path("/bin/codex"), 1)

    def test_protocol_check_requests_experimental_surface(self) -> None:
        # pairing API는 experimental이라 --experimental 없는 generate-ts 출력에서는
        # 필터링된다. 플래그가 빠지면 지원 버전에서도 항상 fail closed된다.
        captured_args: list[str] = []

        def generate_schema(args: list[str], **_kwargs: object) -> mock.Mock:
            captured_args.extend(args)
            out_dir = Path(args[args.index("--out") + 1])
            _write_valid_protocol_schema(out_dir)
            return mock.Mock(returncode=0, stdout="", stderr="")

        with mock.patch.object(
            issue_pairing_code.subprocess, "run", side_effect=generate_schema
        ):
            issue_pairing_code.ensure_pairing_start_returns_manual_code(Path("/bin/codex"), 1)
        self.assertIn("--experimental", captured_args)

    def test_protocol_check_rejects_missing_manual_code_schema(self) -> None:
        def generate_schema(args: list[str], **_kwargs: object) -> mock.Mock:
            out_dir = Path(args[args.index("--out") + 1])
            _write_valid_protocol_schema(
                out_dir,
                response="export type RemoteControlPairingStartResponse = { expiresAt: number };\n",
            )
            return mock.Mock(returncode=0, stdout="", stderr="")

        with mock.patch.object(
            issue_pairing_code.subprocess, "run", side_effect=generate_schema
        ):
            with self.assertRaisesRegex(issue_pairing_code.PairingError, "manualPairingCode"):
                issue_pairing_code.ensure_pairing_start_returns_manual_code(Path("/bin/codex"), 1)

    def test_protocol_check_rejects_missing_pairing_start_method(self) -> None:
        def generate_schema(args: list[str], **_kwargs: object) -> mock.Mock:
            out_dir = Path(args[args.index("--out") + 1])
            _write_valid_protocol_schema(
                out_dir,
                client_request='export type ClientRequest = { "method": "initialize" } | '
                '{ "method": "remoteControl/enable" };\n',
            )
            return mock.Mock(returncode=0, stdout="", stderr="")

        with mock.patch.object(
            issue_pairing_code.subprocess, "run", side_effect=generate_schema
        ):
            with self.assertRaisesRegex(issue_pairing_code.PairingError, "remoteControl/pairing/start"):
                issue_pairing_code.ensure_pairing_start_returns_manual_code(Path("/bin/codex"), 1)

    def test_protocol_check_timeout_is_pairing_error(self) -> None:
        with mock.patch.object(
            issue_pairing_code.subprocess,
            "run",
            side_effect=issue_pairing_code.subprocess.TimeoutExpired("codex", 1),
        ):
            with self.assertRaisesRegex(issue_pairing_code.PairingError, "timed out"):
                issue_pairing_code.ensure_pairing_start_returns_manual_code(Path("/bin/codex"), 1)

    def test_protocol_check_failure_prevents_runtime_creation(self) -> None:
        with mock.patch.object(issue_pairing_code.platform, "system", return_value="Darwin"):
            with mock.patch.object(
                issue_pairing_code, "select_codex_binary", return_value=Path("/bin/codex")
            ):
                with mock.patch.object(
                    issue_pairing_code,
                    "ensure_pairing_start_returns_manual_code",
                    side_effect=issue_pairing_code.PairingError("protocol drift"),
                ):
                    with mock.patch.object(issue_pairing_code, "make_private_runtime_paths") as paths:
                        rc, stdout, stderr = _run_main_capture(["--user-requested-code"])
        self.assertEqual(rc, 1)
        self.assertEqual(stdout, "")
        self.assertIn("error: protocol drift", stderr)
        self.assertNotIn("Cleanup:", stderr)
        paths.assert_not_called()


def _header_value(request: str, name: str) -> str:
    needle = name.lower() + ":"
    for line in request.split("\r\n"):
        if line.lower().startswith(needle):
            return line.split(":", 1)[1].strip()
    raise AssertionError(f"missing header: {name}")


def _run_main_silent(argv: list[str]) -> int:
    return _run_main_capture(argv)[0]


def _run_main_capture(argv: list[str]) -> tuple[int, str, str]:
    stdout = io.StringIO()
    stderr = io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        rc = issue_pairing_code.main(argv)
    return rc, stdout.getvalue(), stderr.getvalue()


FAKE_APP_SERVER = r'''
import os, signal, socket, sys, time
mode = sys.argv[2]
if mode == "fail":
    raise SystemExit(23)
if mode == "never-ready":
    time.sleep(60)
if mode == "ignore-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
    listener.bind(sys.argv[1])
    listener.listen(4)
    while True:
        connection, _ = listener.accept()
        with connection:
            data = connection.recv(32)
            if data == b"exit":
                break
            if data == b"pid":
                connection.sendall(str(os.getpid()).encode())
                continue
            if data:
                connection.sendall(b"fixture-ready")
'''


FAKE_ISSUER = r'''
import importlib.util, json, os, sys, time
from pathlib import Path
from unittest import mock
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("pairing_issuer_fixture", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = m
spec.loader.exec_module(m)
base, mode = Path(sys.argv[2]), sys.argv[4]
os.environ["CODEX_PAIRING_RUNTIME_DIR"] = str(base)
original_make_paths = m.make_private_runtime_paths
original_popen = m.subprocess.Popen
def make_paths():
    paths = original_make_paths()
    (base / "runtime.json").write_text(json.dumps({"root": str(paths.root)}))
    return paths
def start(_binary, paths, _timeout):
    return m.start_helper_process(
        [sys.executable, "-c", sys.argv[3], str(paths.socket_path), "normal"], paths, 2)
def spawn_then_exit(*args, **kwargs):
    process = original_popen(*args, **kwargs)
    (base / "supervisor.pid").write_text(str(process.pid))
    os._exit(23)
def before_output(_result, _as_json):
    (base / "before-output").touch()
    time.sleep(30)
with mock.patch.object(m, "ensure_live_platform_allowed"), \
     mock.patch.object(m, "select_codex_binary", return_value="synthetic-only"), \
     mock.patch.object(m, "ensure_pairing_start_returns_manual_code"), \
     mock.patch.object(m, "make_private_runtime_paths", side_effect=make_paths), \
     mock.patch.object(m, "ensure_helper_app_server", side_effect=start), \
     mock.patch.object(m, "issue_pairing_code", side_effect=lambda _socket, _timeout, cleanup:
         m.PairingResult("SYNTHETIC", m.MOCK_EXPIRES_AT, cleanup)):
    if mode == "exit-after-spawn":
        with mock.patch.object(m.subprocess, "Popen", side_effect=spawn_then_exit):
            raise SystemExit(m.main(["--user-requested-code", "--json", "--timeout", "2"]))
    if mode == "before-output":
        with mock.patch.object(m, "print_result", side_effect=before_output):
            raise SystemExit(m.main(["--user-requested-code", "--json", "--timeout", "2"]))
    raise SystemExit(m.main(["--user-requested-code", "--json", "--timeout", "2"]))
'''


class HelperLifecycleTests(unittest.TestCase):
    """합성 Unix socket 자식만 사용한다. Codex 바이너리·자격·RPC에 접근하지 않는다."""

    def setUp(self) -> None:
        # macOS Unix socket 경로 길이 제한에 들어가는 합성 전용 디렉터리.
        self.temp = tempfile.TemporaryDirectory(prefix="pair-test-", dir="/tmp")
        self.base = Path(self.temp.name).resolve()
        self.servers = []

    def tearDown(self) -> None:
        for server in self.servers:
            server.lease.close()
            if server.process.poll() is None:
                try:
                    issue_pairing_code.cleanup_runtime(server.paths.root, 2)
                except issue_pairing_code.PairingError:
                    pass
                server.process.wait(timeout=5)
        self.temp.cleanup()

    def runtime(self):
        with mock.patch.dict(os.environ, {"CODEX_PAIRING_RUNTIME_DIR": str(self.base)}):
            return issue_pairing_code.make_private_runtime_paths()

    def start(self, mode="normal", retain=True):
        paths = self.runtime()
        server = issue_pairing_code.start_helper_process(
            [sys.executable, "-c", FAKE_APP_SERVER, str(paths.socket_path), mode], paths, 2
        )
        self.servers.append(server)
        if retain:
            server.retain()
        return server

    def ping(self, paths):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(2)
            connection.connect(str(paths.socket_path))
            connection.sendall(b"ping")
            self.assertEqual(connection.recv(32), b"fixture-ready")

    def wait_removed(self, root):
        deadline = time.monotonic() + 5
        while root.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(root.exists(), "owned runtime was not reclaimed")

    def wait_child_gone(self, pid):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.02)
        self.fail("synthetic child did not exit")

    @contextlib.contextmanager
    def observe_child(self, paths):
        # runtime이 잘못 삭제돼도 이미 연결된 같은 합성 자식에게 exit를 보낼 수 있다.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as query:
            query.settimeout(2)
            query.connect(str(paths.socket_path))
            query.sendall(b"pid")
            pid = int(query.recv(32))
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as held:
            held.settimeout(2)
            held.connect(str(paths.socket_path))
            try:
                yield pid, held
            finally:
                try:
                    held.sendall(b"exit")
                except OSError:
                    pass
                self.wait_child_gone(pid)

    def issuer_command(self, mode, python=None):
        return [
            str(python or sys.executable), "-c", FAKE_ISSUER,
            str(SCRIPT), str(self.base), FAKE_APP_SERVER, mode,
        ]

    def test_no_external_runtime_needed_and_explicit_cleanup(self):
        with mock.patch.dict(os.environ, {"PATH": ""}):
            server = self.start()
        self.ping(server.paths)
        issue_pairing_code.cleanup_runtime(server.paths.root, 2)
        server.process.wait(timeout=5)
        self.assertFalse(server.paths.root.exists())

    def test_detached_server_survives_issuer_exit(self):
        launcher = '''
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("pairing_fixture", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = m
spec.loader.exec_module(m)
os.environ["CODEX_PAIRING_RUNTIME_DIR"] = sys.argv[2]
paths = m.make_private_runtime_paths()
server = m.start_helper_process(
    [sys.executable, "-c", sys.argv[3], str(paths.socket_path), "normal"], paths, 2)
server.retain()
print(paths.root)
'''
        result = subprocess.run(
            [sys.executable, "-c", launcher, str(SCRIPT), str(self.base), FAKE_APP_SERVER],
            text=True, capture_output=True, timeout=5, check=True,
        )
        root = Path(result.stdout.strip())
        runtime = issue_pairing_code._open_runtime(root)
        try:
            self.ping(runtime.paths)
            cleanup = subprocess.run(
                [sys.executable, str(SCRIPT), "--cleanup", str(root)],
                text=True, capture_output=True, timeout=5,
            )
            self.assertEqual(cleanup.returncode, 0, cleanup.stderr)
            self.assertFalse(root.exists())
        finally:
            runtime.close()
            if root.exists():
                issue_pairing_code.cleanup_runtime(root, 2)

    def test_buffered_closed_stdout_reclaims_retained_server(self):
        launcher = r'''
import importlib.util, io, json, os, sys
from pathlib import Path
from unittest import mock
spec = importlib.util.spec_from_file_location("pairing_fixture", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = m
spec.loader.exec_module(m)
base = Path(sys.argv[2])
os.environ["CODEX_PAIRING_RUNTIME_DIR"] = str(base)
# PYTHONUNBUFFERED 같은 호출 환경과 무관하게 print는 성공하고 flush에서만 실패한다.
sys.stdout = io.TextIOWrapper(
    io.BufferedWriter(io.FileIO(1, "w", closefd=False)),
    encoding="utf-8", line_buffering=False, write_through=False)
child_code = "import os, sys; from pathlib import Path; Path(sys.argv[3]).write_text(str(os.getpid()))\n" + sys.argv[3]
def start(_binary, paths, _timeout):
    server = m.start_helper_process(
        [sys.executable, "-c", child_code, str(paths.socket_path), "normal", str(base / "child.pid")],
        paths, 2)
    (base / "runtime.json").write_text(json.dumps({"root": str(paths.root)}))
    return server
with mock.patch.object(m, "ensure_live_platform_allowed"), \
     mock.patch.object(m, "select_codex_binary", return_value="synthetic-only"), \
     mock.patch.object(m, "ensure_pairing_start_returns_manual_code"), \
     mock.patch.object(m, "ensure_helper_app_server", side_effect=start), \
     mock.patch.object(m, "issue_pairing_code", side_effect=lambda _socket, _timeout, cleanup:
         m.PairingResult("SYNTHETIC", m.MOCK_EXPIRES_AT, cleanup)):
    raise SystemExit(m.main(["--user-requested-code", "--json", "--timeout", "2"]))
'''
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        root = None
        try:
            with os.fdopen(write_fd, "wb", buffering=0) as closed_pipe:
                result = subprocess.run(
                    [sys.executable, "-c", launcher, str(SCRIPT), str(self.base), FAKE_APP_SERVER],
                    stdout=closed_pipe, stderr=subprocess.PIPE, text=True, timeout=8,
                )
            self.assertNotEqual(result.returncode, 0, "closed stdout must report output failure")
            root = Path(json.loads((self.base / "runtime.json").read_text())["root"])
            child_pid = int((self.base / "child.pid").read_text())
            self.wait_removed(root)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
        finally:
            # 수정 전 실패 재현에서도 이 테스트가 만든 정확한 인스턴스만 회수한다.
            if root is None and (self.base / "runtime.json").exists():
                root = Path(json.loads((self.base / "runtime.json").read_text())["root"])
            if root is not None and root.exists():
                issue_pairing_code.cleanup_runtime(root, 2)

    def test_issuer_sigterm_before_output_reclaims_retained_server(self):
        issuer = subprocess.Popen(
            self.issuer_command("before-output"), text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        root = None
        try:
            deadline = time.monotonic() + 5
            while not (self.base / "before-output").exists() and time.monotonic() < deadline:
                self.assertIsNone(issuer.poll(), "synthetic issuer exited before output boundary")
                time.sleep(0.02)
            self.assertTrue((self.base / "before-output").exists())
            root = Path(json.loads((self.base / "runtime.json").read_text())["root"])
            runtime = issue_pairing_code._open_runtime(root)
            try:
                paths = runtime.paths
            finally:
                runtime.close()
            with self.observe_child(paths) as (pid, held):
                issuer.terminate()
                stdout, stderr = issuer.communicate(timeout=6)
                self.assertNotEqual(issuer.returncode, 0)
                self.assertEqual(stdout, "")
                self.assertIn("interrupted", stderr)
                self.wait_removed(root)
                self.assertEqual(held.recv(32), b"")
                self.wait_child_gone(pid)
        finally:
            if issuer.poll() is None:
                issuer.terminate()
                issuer.wait(timeout=6)
            if root is None and (self.base / "runtime.json").exists():
                root = Path(json.loads((self.base / "runtime.json").read_text())["root"])
            if root is not None and root.exists():
                issue_pairing_code.cleanup_runtime(root, 2)

    def test_cleanup_survives_issuing_virtualenv_removal(self):
        venv = self.base / "temporary venv '$()"
        subprocess.run(
            [sys.executable, "-m", "venv", "--without-pip", str(venv)],
            check=True, capture_output=True, timeout=20,
        )
        result = subprocess.run(
            self.issuer_command("normal", venv / "bin/python"),
            check=True, capture_output=True, text=True, timeout=8,
        )
        cleanup = json.loads(result.stdout)["cleanup"]
        root = Path(json.loads((self.base / "runtime.json").read_text())["root"])
        runtime = issue_pairing_code._open_runtime(root)
        try:
            paths = runtime.paths
        finally:
            runtime.close()
        try:
            with self.observe_child(paths) as (pid, held):
                shutil.rmtree(venv)
                fallback = self.base / "fallback"
                fallback.mkdir()
                (fallback / "python3").symlink_to(sys.executable)
                environment = os.environ.copy()
                environment["PATH"] = str(fallback)
                stopped = subprocess.run(
                    shlex.split(cleanup), env=environment,
                    capture_output=True, text=True, timeout=8,
                )
                self.assertEqual(stopped.returncode, 0, stopped.stderr)
                self.assertFalse(root.exists())
                self.assertEqual(held.recv(32), b"")
                self.wait_child_gone(pid)
        finally:
            if root.exists():
                issue_pairing_code.cleanup_runtime(root, 2)

    def test_cleanup_copy_survives_original_source_removal(self):
        source = self.base / "source.py"
        source.write_bytes(SCRIPT.read_bytes())
        spec = importlib.util.spec_from_file_location("temporary_pairing_fixture", source)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        try:
            spec.loader.exec_module(module)
            with mock.patch.dict(os.environ, {"CODEX_PAIRING_RUNTIME_DIR": str(self.base)}):
                paths = module.make_private_runtime_paths()
            server = module.start_helper_process(
                [sys.executable, "-c", FAKE_APP_SERVER, str(paths.socket_path), "normal"], paths, 2
            )
            self.servers.append(server)
            server.retain()
            cleanup = module.cleanup_command_for(paths)
            source.unlink()
            result = subprocess.run(shlex.split(cleanup), capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            server.process.wait(timeout=5)
            self.assertFalse(paths.root.exists())
        finally:
            del sys.modules[spec.name]

    def test_pre_handoff_issuer_eof_reclaims_child(self):
        server = self.start(retain=False)
        self.ping(server.paths)
        server.lease.close()
        server.process.wait(timeout=5)
        self.assertFalse(server.paths.root.exists())

    def test_issuer_exit_before_ready_reclaims_child(self):
        launcher = '''
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("pairing_fixture", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = m
spec.loader.exec_module(m)
os.environ["CODEX_PAIRING_RUNTIME_DIR"] = sys.argv[2]
paths = m.make_private_runtime_paths()
print(paths.root, flush=True)
m.start_helper_process(
    [sys.executable, "-c", sys.argv[3], str(paths.socket_path), "never-ready"], paths, 10)
'''
        with subprocess.Popen(
            [sys.executable, "-c", launcher, str(SCRIPT), str(self.base), FAKE_APP_SERVER],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        ) as issuer:
            root = Path(issuer.stdout.readline().strip())
            deadline = time.monotonic() + 3
            while not (root / "control.sock").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue((root / "control.sock").exists())
            issuer.terminate()
            issuer.wait(timeout=3)
        self.wait_removed(root)

    def test_issuer_exit_immediately_after_supervisor_spawn_reclaims_runtime(self):
        result = subprocess.run(
            self.issuer_command("exit-after-spawn"),
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 23)
        root = Path(json.loads((self.base / "runtime.json").read_text())["root"])
        supervisor_pid = int((self.base / "supervisor.pid").read_text())
        try:
            self.wait_removed(root)
        finally:
            if (root / "control.sock").exists():
                issue_pairing_code.cleanup_runtime(root, 2)
            self.wait_child_gone(supervisor_pid)
            if root.exists():
                runtime = issue_pairing_code._open_runtime(root)
                try:
                    self.assertTrue(issue_pairing_code._remove_runtime(runtime, {}))
                finally:
                    runtime.close()

    def test_two_instances_and_unrelated_child_are_isolated(self):
        first, second = self.start(), self.start()
        with subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"]) as unrelated:
            try:
                issue_pairing_code.cleanup_runtime(first.paths.root, 2)
                first.process.wait(timeout=5)
                self.ping(second.paths)
                self.assertIsNone(unrelated.poll())
            finally:
                unrelated.terminate()
                unrelated.wait(timeout=3)

    def test_failed_start_and_readiness_timeout_reclaim_runtime(self):
        for mode in ("fail", "never-ready"):
            with self.subTest(mode=mode):
                paths = self.runtime()
                with self.assertRaises(issue_pairing_code.PairingError):
                    issue_pairing_code.start_helper_process(
                        [sys.executable, "-c", FAKE_APP_SERVER, str(paths.socket_path), mode], paths, 0.3
                    )
                self.assertFalse(paths.root.exists())

    def test_supervisor_exit_before_request_processing_reclaims_runtime(self):
        paths = self.runtime()
        (paths.root / "helper.py").write_text("raise SystemExit(23)\n")
        with self.assertRaises(issue_pairing_code.PairingError):
            issue_pairing_code.start_helper_process(
                [sys.executable, "-c", FAKE_APP_SERVER, str(paths.socket_path), "normal"], paths, 0.3
            )
        self.assertFalse(paths.root.exists())

    def test_runtime_copy_failure_reclaims_only_new_runtime(self):
        sentinel = self.base / "keep.txt"
        sentinel.write_text("synthetic parent content")
        with mock.patch.object(Path, "read_bytes", side_effect=OSError("synthetic read failure")):
            with self.assertRaises(issue_pairing_code.PairingError):
                self.runtime()
        self.assertEqual(list(self.base.iterdir()), [sentinel])

    def test_runtime_directory_open_failure_reclaims_empty_root(self):
        original_open = os.open

        def fail_directory(path, flags, *args, **kwargs):
            if flags & os.O_DIRECTORY:
                raise OSError(errno.EMFILE, "synthetic directory open failure")
            return original_open(path, flags, *args, **kwargs)

        with mock.patch.object(issue_pairing_code.os, "open", side_effect=fail_directory):
            with self.assertRaises(issue_pairing_code.PairingError):
                self.runtime()
        self.assertEqual(list(self.base.iterdir()), [])

    def test_runtime_creation_failure_reports_preserved_root(self):
        original_open = os.open
        preserved = []

        def add_file_then_fail(path, flags, *args, **kwargs):
            if flags & os.O_DIRECTORY:
                root = Path(path)
                (root / "keep.txt").write_text("synthetic concurrent content")
                preserved.append(root)
                raise OSError(errno.EMFILE, "synthetic directory open failure")
            return original_open(path, flags, *args, **kwargs)

        with mock.patch.object(issue_pairing_code.os, "open", side_effect=add_file_then_fail):
            with self.assertRaises(issue_pairing_code.PairingError) as caught:
                self.runtime()
        self.assertEqual((preserved[0] / "keep.txt").read_text(), "synthetic concurrent content")
        self.assertIn(str(preserved[0]), str(caught.exception))

    def test_socketpair_failure_reclaims_runtime_and_closes_directory(self):
        paths = self.runtime()
        opened = []
        original_open = issue_pairing_code._open_runtime

        def capture_runtime(root):
            runtime = original_open(root)
            opened.append(runtime)
            return runtime

        try:
            with mock.patch.object(issue_pairing_code, "_open_runtime", side_effect=capture_runtime), \
                 mock.patch.object(issue_pairing_code.socket, "socketpair", side_effect=OSError(errno.EMFILE, "synthetic socket exhaustion")), \
                 mock.patch.object(issue_pairing_code.subprocess, "Popen") as spawn:
                with self.assertRaises(issue_pairing_code.PairingError):
                    issue_pairing_code.start_helper_process(["synthetic-only"], paths, 0.2)
            spawn.assert_not_called()
            self.assertFalse(paths.root.exists())
            with self.assertRaises(OSError):
                os.fstat(opened[0].fd)
        finally:
            for runtime in opened:
                try:
                    runtime.close()
                except OSError:
                    pass

    def test_oversized_initial_request_fails_before_supervisor_spawn(self):
        paths = self.runtime()
        with mock.patch.object(issue_pairing_code.subprocess, "Popen") as spawn:
            with self.assertRaises(issue_pairing_code.PairingError):
                issue_pairing_code.start_helper_process(
                    ["synthetic-only", "x" * issue_pairing_code.CONTROL_LIMIT], paths, 0.2
                )
        spawn.assert_not_called()
        self.assertFalse(paths.root.exists())

    def test_cleanup_response_loss_does_not_claim_nothing_stopped(self):
        paths = self.runtime()
        ready = threading.Event()
        received = threading.Event()

        def lost_response():
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(paths.control_path))
                listener.listen(1)
                ready.set()
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(2)
                    request = issue_pairing_code._receive_control(connection)
                    if request == {"action": "stop", "instance": paths.instance_id}:
                        received.set()

        thread = threading.Thread(target=lost_response)
        thread.start()
        self.assertTrue(ready.wait(2))
        try:
            with self.assertRaises(issue_pairing_code.PairingError) as caught:
                issue_pairing_code.cleanup_runtime(paths.root, 1)
            self.assertTrue(received.wait(2))
            self.assertNotIn("no PID", str(caught.exception))
            self.assertIn("could not be confirmed", str(caught.exception))
        finally:
            thread.join(3)

    def test_natural_child_exit_reclaims_retained_supervisor(self):
        server = self.start()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.connect(str(server.paths.socket_path))
            connection.sendall(b"exit")
        server.process.wait(timeout=5)
        self.assertFalse(server.paths.root.exists())

    def test_cleanup_waits_for_child_ignoring_term(self):
        server = self.start(mode="ignore-term")
        with self.observe_child(server.paths) as (pid, held):
            issue_pairing_code.cleanup_runtime(server.paths.root, 3)
            server.process.wait(timeout=5)
            self.assertFalse(server.paths.root.exists())
            self.assertEqual(held.recv(32), b"")
            self.wait_child_gone(pid)

    def test_supervisor_sigterm_reclaims_its_child_and_runtime(self):
        server = self.start()
        with self.observe_child(server.paths) as (pid, held):
            server.process.send_signal(signal.SIGTERM)
            server.process.wait(timeout=5)
            self.assertFalse(server.paths.root.exists())
            self.assertEqual(held.recv(32), b"")
            self.wait_child_gone(pid)

    def test_invalid_or_idle_control_requests_do_not_block_cleanup(self):
        server = self.start()
        for raw in (b"not-json\n", b'[]\n', b'{"action":"stop","instance":"wrong"}\n', b"x" * 4098, b"[" * 1100 + b"]" * 1100 + b"\n"):
            with self.subTest(raw_length=len(raw)):
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                    connection.settimeout(2)
                    connection.connect(str(server.paths.control_path))
                    connection.sendall(raw)
                    self.assertEqual(issue_pairing_code._receive_control(connection), {"state": "refused"})
                self.ping(server.paths)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as idle:
            idle.connect(str(server.paths.control_path))
            issue_pairing_code.cleanup_runtime(server.paths.root, 2)
        server.process.wait(timeout=5)

    def test_deep_owner_json_is_refused_without_stopping_instance(self):
        server = self.start()
        marker = server.paths.root / "owner.json"
        original = marker.read_text()
        marker.write_text("[" * 1100 + "]" * 1100)
        try:
            with self.assertRaises(issue_pairing_code.PairingError):
                issue_pairing_code.cleanup_runtime(server.paths.root, 1)
            self.ping(server.paths)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(2)
                connection.connect(str(server.paths.control_path))
                issue_pairing_code._send_control(connection, {
                    "action": "stop", "instance": server.paths.instance_id,
                })
                self.assertEqual(issue_pairing_code._receive_control(connection), {"state": "refused"})
            self.ping(server.paths)
        finally:
            if marker.exists():
                marker.write_text(original)

    def test_slow_control_request_has_total_deadline(self):
        server = self.start()
        stop = threading.Event()
        started = threading.Event()

        def trickle():
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.connect(str(server.paths.control_path))
                for _ in range(60):
                    try:
                        connection.sendall(b"x")
                    except OSError:
                        break
                    started.set()
                    if stop.wait(0.05):
                        break

        thread = threading.Thread(target=trickle)
        thread.start()
        try:
            self.assertTrue(started.wait(2))
            start = time.monotonic()
            issue_pairing_code.cleanup_runtime(server.paths.root, 2)
            self.assertLess(time.monotonic() - start, 1.5)
        finally:
            stop.set()
            thread.join(3)
        server.process.wait(timeout=5)

    def test_wrong_path_symlink_and_swapped_instance_marker_are_refused(self):
        first, second = self.start(), self.start()
        link = self.base / "codex-pairing-code-link"
        link.symlink_to(first.paths.root, target_is_directory=True)
        for path in (self.base, link, first.paths.root / "..", self.base / "missing"):
            with self.subTest(path_kind=path.name):
                with self.assertRaises(issue_pairing_code.PairingError):
                    issue_pairing_code.cleanup_runtime(path, 1)
        marker = first.paths.root / "owner.json"
        original = marker.read_text()
        try:
            marker.write_text(json.dumps({"kind": issue_pairing_code.RUNTIME_KIND, "instance": second.paths.instance_id}))
            with self.assertRaises(issue_pairing_code.PairingError):
                issue_pairing_code.cleanup_runtime(first.paths.root, 1)
            self.ping(first.paths)
            self.ping(second.paths)
        finally:
            marker.write_text(original)

    def test_changed_permissions_and_marker_inode_are_refused(self):
        server = self.start()
        root = server.paths.root
        root.chmod(0o755)
        try:
            with self.assertRaises(issue_pairing_code.PairingError):
                issue_pairing_code.cleanup_runtime(root, 1)
        finally:
            root.chmod(0o700)
        marker, saved = root / "owner.json", root / "saved-owner.json"
        marker.rename(saved)
        marker.write_bytes(saved.read_bytes())
        marker.chmod(0o600)
        try:
            with self.assertRaises(issue_pairing_code.PairingError):
                issue_pairing_code.cleanup_runtime(root, 1)
            self.ping(server.paths)
        finally:
            marker.unlink()
            saved.rename(marker)

    def test_fifo_marker_is_rejected_without_waiting_for_a_writer(self):
        server = self.start()
        marker = server.paths.root / "owner.json"
        saved = server.paths.root / "saved-owner.json"
        marker.rename(saved)
        os.mkfifo(marker, 0o600)
        try:
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--cleanup", str(server.paths.root)],
                capture_output=True, text=True, timeout=2,
            )
            self.assertEqual(result.returncode, 1)
            self.ping(server.paths)
        finally:
            marker.unlink()
            saved.rename(marker)

    def test_replaced_runtime_path_is_not_deleted(self):
        server = self.start()
        original = server.paths.root
        moved = original.with_name(original.name + "-moved")
        original.rename(moved)
        original.mkdir(mode=0o700)
        survivor = original / "keep.txt"
        survivor.write_text("synthetic replacement")
        try:
            with self.assertRaises(issue_pairing_code.PairingError):
                issue_pairing_code.cleanup_runtime(moved, 1)
            self.assertEqual(survivor.read_text(), "synthetic replacement")
            self.assertIsNone(server.process.poll())
        finally:
            survivor.unlink()
            original.rmdir()
            moved.rename(original)

    def test_additional_runtime_files_are_preserved_after_stop(self):
        server = self.start()
        survivor = server.paths.root / "keep.txt"
        survivor.write_text("synthetic extra file")
        with self.assertRaisesRegex(issue_pairing_code.PairingError, "files were preserved"):
            issue_pairing_code.cleanup_runtime(server.paths.root, 2)
        server.process.wait(timeout=5)
        self.assertEqual(survivor.read_text(), "synthetic extra file")
        self.assertTrue((server.paths.root / "owner.json").is_file())

    def test_existing_runtime_contents_are_not_reused(self):
        paths = self.runtime()
        sentinel = paths.root / "keep.txt"
        sentinel.write_text("existing synthetic content")
        with self.assertRaises(issue_pairing_code.PairingError):
            issue_pairing_code.start_helper_process(
                [sys.executable, "-c", FAKE_APP_SERVER, str(paths.socket_path), "normal"], paths, 1
            )
        self.assertEqual(sentinel.read_text(), "existing synthetic content")


class _FakeWs:
    def __init__(self, responses: list[str]) -> None:
        self.responses = responses

    def send_text(self, _text: str) -> None:
        pass

    def receive_text(self, deadline: float | None = None) -> str:
        _ = deadline
        if not self.responses:
            raise issue_pairing_code.PairingError("no fake response left")
        if len(self.responses) == 1:
            return self.responses[0]
        return self.responses.pop(0)


def _write_valid_protocol_schema(
    out_dir: Path,
    *,
    client_request: str | None = None,
    response: str | None = None,
) -> None:
    # 픽스처 형태는 codex 0.142.5 `generate-ts --experimental` 실측 출력 기준.
    v2 = out_dir / "v2"
    v2.mkdir(parents=True)
    (out_dir / "ClientRequest.ts").write_text(
        client_request
        or (
            'export type ClientRequest = { "method": "initialize" } | '
            '{ "method": "remoteControl/enable" } | '
            '{ "method": "remoteControl/pairing/start" };\n'
        ),
        encoding="utf-8",
    )
    (v2 / "RemoteControlEnableParams.ts").write_text(
        "export type RemoteControlEnableParams = { ephemeral?: boolean, };\n",
        encoding="utf-8",
    )
    (v2 / "RemoteControlPairingStartParams.ts").write_text(
        "export type RemoteControlPairingStartParams = { manualCode?: boolean, };\n",
        encoding="utf-8",
    )
    (v2 / "RemoteControlPairingStartResponse.ts").write_text(
        response
        or (
            "export type RemoteControlPairingStartResponse = "
            "{ pairingCode: string, manualPairingCode: string | null, "
            "environmentId: string, expiresAt: bigint, };\n"
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    unittest.main()
