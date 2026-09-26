"""pytest loader for karakeep-singlefile-bridge tests."""
import importlib.util
import os
import socket
import subprocess
import sys
import time
from dataclasses import dataclass

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
def bridge_server():
    """Start singlefile-bridge.py as a real subprocess on a free loopback port.

    Yields a BridgeProcess once /healthz responds. Signal-handling tests send
    signals to `proc` themselves; this fixture only guarantees cleanup by pid
    if a test leaves the process running (never by name/pattern).
    """
    port = _free_tcp_port()
    env = dict(os.environ)
    env["SINGLEFILE_BRIDGE_LISTEN"] = "127.0.0.1"
    env["SINGLEFILE_BRIDGE_PORT"] = str(port)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    proc = subprocess.Popen(
        [sys.executable, SOURCE_PATH],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        if not _wait_for_health(port, 10.0):
            proc.kill()
            proc.wait(timeout=5)
            out = proc.stdout.read() if proc.stdout else ""
            raise RuntimeError(f"bridge did not become healthy on port {port}: {out}")
        yield BridgeProcess(proc=proc, port=port)
    finally:
        if proc.poll() is None:
            proc.kill()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
