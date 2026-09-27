"""pytest loader for karakeep-singlefile-bridge tests."""
import importlib.util
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest


HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE_PATH = os.path.join(os.path.dirname(HERE), "files", "singlefile-bridge.py")


@pytest.fixture(scope="session")
def bridge_module():
    spec = importlib.util.spec_from_file_location("karakeep_singlefile_bridge", SOURCE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module spec from {SOURCE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@dataclass
class BridgeProcess:
    """A live singlefile-bridge subprocess bound to a loopback port."""

    proc: subprocess.Popen
    port: int


def _free_tcp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def _wait_for_health(port: int, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5) as conn:
                conn.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                if b" 200 " in conn.recv(4096):
                    return True
        except OSError:
            pass
        time.sleep(0.05)
    return False


@pytest.fixture
def spawn_bridge(tmp_path):
    """Factory fixture: spawn_bridge(env_overrides=None) -> BridgeProcess.

    Starts singlefile-bridge.py as a real subprocess on a free loopback port
    and waits for /healthz. Every process this factory spawns is torn down
    at fixture teardown by pid (never by name/pattern), even if a test
    forgets to clean up or fails early.

    PUSHOVER_* and KARAKEEP_* are always pinned to blank/unroutable values
    (direct assignment, not setdefault) so a shell with real production env
    vars can't leak in and reach real external services. Pass
    env_overrides — applied last, after these fixed defaults — to point
    KARAKEEP_BASE_URL at a local stub, tighten
    SINGLEFILE_BRIDGE_SHUTDOWN_DRAIN_SEC for a faster test, etc.

    TMPDIR is pinned to this test's own tmp_path so run_curl's temp files
    (karakeep-bridge-body-*, karakeep-bridge-header-*) and do_POST's
    karakeep-singlefile-*.html land there instead of the real $TMPDIR —
    including for a test that kills the bridge mid-request and orphans
    curl, which would otherwise leave files behind in the shared tmp dir on
    every run.
    """
    spawned: list[subprocess.Popen] = []

    def _spawn(env_overrides: dict | None = None) -> BridgeProcess:
        port = _free_tcp_port()
        env = dict(os.environ)
        env["SINGLEFILE_BRIDGE_LISTEN"] = "127.0.0.1"
        env["SINGLEFILE_BRIDGE_PORT"] = str(port)
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        # wait_or_fail sends SIGABRT before falling back to SIGKILL on a
        # hang; this makes that SIGABRT dump each thread's stack to stdout
        # before the process dies.
        env["PYTHONFAULTHANDLER"] = "1"
        env["TMPDIR"] = str(tmp_path)
        env["PUSHOVER_TOKEN"] = ""
        env["PUSHOVER_USER"] = ""
        env["KARAKEEP_BASE_URL"] = "http://127.0.0.1:1"
        env["KARAKEEP_DB_PATH"] = "/nonexistent/karakeep-bridge-test-fixture/db.db"
        env["KARAKEEP_QUEUE_DB_PATH"] = "/nonexistent/karakeep-bridge-test-fixture/queue.db"
        if env_overrides:
            env.update(env_overrides)
        proc = subprocess.Popen(
            [sys.executable, SOURCE_PATH],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        spawned.append(proc)
        if not _wait_for_health(port, 10.0):
            proc.kill()
            proc.wait(timeout=5)
            out = proc.stdout.read() if proc.stdout else ""
            raise RuntimeError(f"bridge did not become healthy on port {port}: {out}")
        return BridgeProcess(proc=proc, port=port)

    try:
        yield _spawn
    finally:
        for proc in spawned:
            if proc.poll() is None:
                proc.kill()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass


@pytest.fixture
def bridge_server(spawn_bridge):
    """A single bridge subprocess with default (safe, unroutable) env.

    Signal-handling tests send signals to `.proc` themselves; teardown is
    handled by the underlying spawn_bridge factory.
    """
    return spawn_bridge()


@pytest.fixture
def wait_or_fail():
    """Factory: wait_or_fail(proc, timeout, reason) -> exit code.

    Shared by every shutdown test that waits on a bridge subprocess. On
    timeout, sends SIGABRT first — PYTHONFAULTHANDLER=1 (set by
    spawn_bridge) makes that dump each thread's stack to stdout — and gives
    it a couple of seconds before falling back to SIGKILL, so a genuine
    hang leaves a diagnosable trace instead of just disappearing. Always
    fails the test with `reason` and the process's captured output
    attached.
    """

    def _wait(proc: subprocess.Popen, timeout: float, reason: str) -> int:
        try:
            return proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.send_signal(signal.SIGABRT)
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
            out = proc.stdout.read() if proc.stdout else ""
            pytest.fail(f"{reason}\n--- process output ---\n{out}")

    return _wait


class _FakeKarakeepHandler(BaseHTTPRequestHandler):
    """Stub for Karakeep's API: sleeps `delay_seconds`, then returns 201.

    That status (not 200) makes the bridge skip its alreadyExists-notify
    branch and fall straight through to relaying the response body/status,
    which is all this fixture needs to exercise the happy path.
    """

    delay_seconds = 0.0

    def log_message(self, *args: object) -> None:  # keep test output quiet
        pass

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)
        time.sleep(self.delay_seconds)
        body = b'{"ok": true}'
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@pytest.fixture
def fake_karakeep_upstream():
    """A minimal loopback HTTP stub standing in for Karakeep's API.

    Set `.RequestHandlerClass.delay_seconds` before triggering a bridge POST
    to control how long the bridge's request handling (and thus its
    in-flight tracker) stays busy waiting on this stub.

    serve_forever() runs on a background thread here and shutdown() is
    called from the fixture's own (different) thread at teardown — the
    correct non-deadlocking pairing, unlike the bug singlefile-bridge.py
    used to have.
    """
    handler_cls = type("FakeKarakeepHandler", (_FakeKarakeepHandler,), {"delay_seconds": 0.0})
    server = HTTPServer(("127.0.0.1", 0), handler_cls)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()
