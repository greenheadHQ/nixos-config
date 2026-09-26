"""Process-level tests for singlefile-bridge.py shutdown signal handling.

main()'s signal handler used to call server.shutdown() directly from the same
thread that runs serve_forever(), which deadlocks: shutdown() waits for
serve_forever's loop to notice a shutdown request and exit, but that loop
never gets to run again because the signal handler that would let it proceed
is itself blocked waiting. These tests exercise the real subprocess so a
regression shows up as a hang, not just a code-reading exercise.

SHUTDOWN_TIMEOUT_SEC is a generous ceiling for a clean shutdown; the deadlock
this guards against does not resolve until the 90s default service stop
timeout forces a SIGKILL, so any value well under that cleanly tells the two
cases apart.
"""
import signal
import socket
import subprocess

import pytest

SHUTDOWN_TIMEOUT_SEC = 5.0


def _wait_or_fail(proc: subprocess.Popen, reason: str) -> int:
    try:
        return proc.wait(timeout=SHUTDOWN_TIMEOUT_SEC)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
        pytest.fail(reason)


def test_sigterm_triggers_clean_shutdown_without_forced_kill(bridge_server):
    bridge_server.proc.send_signal(signal.SIGTERM)
    rc = _wait_or_fail(
        bridge_server.proc,
        f"bridge did not exit within {SHUTDOWN_TIMEOUT_SEC}s of SIGTERM (deadlock)",
    )
    assert rc == 0


def test_sigint_triggers_clean_shutdown_without_forced_kill(bridge_server):
    bridge_server.proc.send_signal(signal.SIGINT)
    rc = _wait_or_fail(
        bridge_server.proc,
        f"bridge did not exit within {SHUTDOWN_TIMEOUT_SEC}s of SIGINT (deadlock)",
    )
    assert rc == 0


def test_listening_socket_is_released_after_shutdown(bridge_server):
    port = bridge_server.port
    bridge_server.proc.send_signal(signal.SIGTERM)
    _wait_or_fail(bridge_server.proc, "bridge did not exit before checking socket release")

    # server_close() must have run: a fresh socket can bind the same port.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", port))


def test_duplicate_signals_do_not_hang_or_raise(bridge_server):
    bridge_server.proc.send_signal(signal.SIGTERM)
    bridge_server.proc.send_signal(signal.SIGTERM)
    bridge_server.proc.send_signal(signal.SIGINT)
    rc = _wait_or_fail(bridge_server.proc, "bridge hung after duplicate shutdown signals")
    assert rc == 0

    out = bridge_server.proc.stdout.read() if bridge_server.proc.stdout else ""
    assert "Traceback" not in out


def test_shutdown_meets_deadline_while_a_request_is_in_flight(bridge_server):
    # Open a connection and send only a partial request line, so the server's
    # per-connection thread is left blocked waiting on the rest of the
    # request when the shutdown signal arrives.
    lingering = socket.create_connection(("127.0.0.1", bridge_server.port), timeout=5)
    try:
        lingering.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\n")

        bridge_server.proc.send_signal(signal.SIGTERM)
        rc = _wait_or_fail(
            bridge_server.proc,
            "bridge hung while a request was in flight during shutdown",
        )
        assert rc == 0
    finally:
        lingering.close()


def test_health_endpoint_still_responds_before_shutdown(bridge_server):
    with socket.create_connection(("127.0.0.1", bridge_server.port), timeout=5) as conn:
        conn.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        data = b""
        conn.settimeout(5)
        try:
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
        except socket.timeout:
            pass

    assert b" 200 " in data
    assert b'"status": "ok"' in data
