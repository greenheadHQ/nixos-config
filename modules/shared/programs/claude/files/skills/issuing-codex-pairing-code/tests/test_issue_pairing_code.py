#!/usr/bin/env python3

from __future__ import annotations

import base64
import contextlib
import importlib.util
import io
import json
import os
import socket
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
            ready.wait(2)
            with issue_pairing_code.WsUnixClient(socket_path, 2):
                pass
            thread.join(2)
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
            ready.wait(2)
            with self.assertRaises(issue_pairing_code.PairingError):
                with issue_pairing_code.WsUnixClient(socket_path, 2):
                    pass
            thread.join(2)

    def test_redaction_removes_codes_and_secret_fields(self) -> None:
        raw = (
            '{"manualPairingCode":"MH67-9LKZ","pairingCode":"secret",'
            '"environmentId":"env-123","other":"ABCD-1234"}'
        )
        redacted = issue_pairing_code.redact_pairing_payload(raw)
        self.assertNotIn("MH67-9LKZ", redacted)
        self.assertNotIn("secret", redacted)
        self.assertNotIn("env-123", redacted)
        self.assertNotIn("ABCD-1234", redacted)

    def test_runtime_dir_is_private_and_marked(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            runtime_parent = Path(tmp) / "runtime-parent"
            with mock.patch.dict(os.environ, {"CODEX_PAIRING_RUNTIME_DIR": str(runtime_parent)}):
                paths = issue_pairing_code.make_private_runtime_paths()
            self.assertEqual(paths.root.parent, runtime_parent)
            self.assertTrue(paths.session_name.startswith("codex-pair-bg-"))
            self.assertTrue(paths.root.name.startswith("codex-pairing-code-"))
            self.assertEqual(
                paths.marker_path.read_text(encoding="utf-8"),
                issue_pairing_code.HELPER_MARKER,
            )
            self.assertEqual(paths.root.stat().st_mode & 0o077, 0)

    def test_existing_tmux_session_fails_closed_before_socket_wait(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            paths = issue_pairing_code.RuntimePaths(
                root=Path(tmp),
                socket_path=Path(tmp) / "app.sock",
                log_path=Path(tmp) / "app-server.log",
                marker_path=Path(tmp) / ".owner",
                session_name="codex-pair-bg-existing",
            )
            with mock.patch.object(issue_pairing_code.shutil, "which", return_value="/usr/bin/tmux"):
                with mock.patch.object(issue_pairing_code, "_tmux_has_session", return_value=True):
                    with mock.patch.object(issue_pairing_code, "_wait_for_socket") as wait:
                        with self.assertRaises(issue_pairing_code.PairingError):
                            issue_pairing_code.ensure_helper_app_server(Path("/bin/codex"), paths, 1)
        wait.assert_not_called()

    def test_mock_result_is_deterministic(self) -> None:
        first = issue_pairing_code.build_mock_result()
        second = issue_pairing_code.build_mock_result()
        self.assertEqual(first, second)
        self.assertEqual(first.expires_at, issue_pairing_code.MOCK_EXPIRES_AT)

    def test_json_rpc_rejects_malformed_json(self) -> None:
        rpc = issue_pairing_code.JsonRpcClient(_FakeWs(["not-json"]))
        with self.assertRaises(issue_pairing_code.PairingError):
            rpc.request("remoteControl/pairing/start", {"manualCode": True})

    def test_json_rpc_rejects_non_object_response(self) -> None:
        rpc = issue_pairing_code.JsonRpcClient(_FakeWs(["[]"]))
        with self.assertRaises(issue_pairing_code.PairingError):
            rpc.request("remoteControl/pairing/start", {"manualCode": True})

    def test_format_expiry_rejects_malformed_string(self) -> None:
        with self.assertRaises(issue_pairing_code.PairingError):
            issue_pairing_code.format_expiry_kst("not-a-date")

    def test_rpc_sequence_extracts_manual_code_and_expiry(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            socket_path = Path(tmp) / "app.sock"
            seen_methods: list[str] = []
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
            ready.wait(2)
            result = issue_pairing_code.issue_pairing_code(
                socket_path, 2, "tmux kill-session -t codex-pair-bg"
            )
            thread.join(2)

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

    def test_binary_selection_honors_env_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "codex"
            binary.write_text("#!/bin/sh\n", encoding="utf-8")
            binary.chmod(0o700)
            with mock.patch.dict(os.environ, {"CODEX_PAIRING_CODEX_BIN": str(binary)}):
                self.assertEqual(issue_pairing_code.select_codex_binary(), binary)


def _header_value(request: str, name: str) -> str:
    needle = name.lower() + ":"
    for line in request.split("\r\n"):
        if line.lower().startswith(needle):
            return line.split(":", 1)[1].strip()
    raise AssertionError(f"missing header: {name}")


def _run_main_silent(argv: list[str]) -> int:
    stdout = io.StringIO()
    stderr = io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        return issue_pairing_code.main(argv)


class _FakeWs:
    def __init__(self, responses: list[str]) -> None:
        self.responses = responses

    def send_text(self, _text: str) -> None:
        pass

    def receive_text(self) -> str:
        if not self.responses:
            raise issue_pairing_code.PairingError("no fake response left")
        return self.responses.pop(0)


if __name__ == "__main__":
    unittest.main()
