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
import dis
import os
import signal
import socket

import pytest

SHUTDOWN_TIMEOUT_SEC = 5.0

# Fires this many SIGTERMs in a tight loop in test_signal_burst_starts_
# shutdown_at_most_once. CPython signal handlers are reentrant, and a burst
# this size reliably lands a second delivery inside _shutdown() while the
# first call is still running.
SIGNAL_BURST_COUNT = 800


def test_sigterm_triggers_clean_shutdown_without_forced_kill(bridge_server, wait_or_fail):
    bridge_server.proc.send_signal(signal.SIGTERM)
    rc = wait_or_fail(
        bridge_server.proc,
        SHUTDOWN_TIMEOUT_SEC,
        f"bridge did not exit within {SHUTDOWN_TIMEOUT_SEC}s of SIGTERM (deadlock)",
    )
    assert rc == 0


def test_sigint_triggers_clean_shutdown_without_forced_kill(bridge_server, wait_or_fail):
    bridge_server.proc.send_signal(signal.SIGINT)
    rc = wait_or_fail(
        bridge_server.proc,
        SHUTDOWN_TIMEOUT_SEC,
        f"bridge did not exit within {SHUTDOWN_TIMEOUT_SEC}s of SIGINT (deadlock)",
    )
    assert rc == 0


def test_listening_socket_is_released_after_shutdown(bridge_server, wait_or_fail):
    port = bridge_server.port
    bridge_server.proc.send_signal(signal.SIGTERM)
    rc = wait_or_fail(
        bridge_server.proc, SHUTDOWN_TIMEOUT_SEC, "bridge did not exit before checking socket release"
    )
    assert rc == 0

    # A bare bind() is not proof server_close() ran: the process exiting
    # closes every fd regardless, and macOS refuses to bind over a port that
    # still has a very recent connection in TIME_WAIT (left behind by this
    # fixture's own /healthz probes) unless the new socket opts in via
    # SO_REUSEADDR — exactly like the bridge's own listening socket does
    # (HTTPServer.allow_reuse_address). Without SO_REUSEADDR this bind flakes
    # on "Address already in use" even when shutdown was perfectly clean.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(("127.0.0.1", port))

    # The actual evidence that server_close() ran: the finally block in
    # main() only reaches this log line after server_close() returns.
    out = bridge_server.proc.stdout.read() if bridge_server.proc.stdout else ""
    assert "karakeep-singlefile-bridge stopped" in out


def test_duplicate_signals_do_not_hang_or_raise(bridge_server, wait_or_fail):
    bridge_server.proc.send_signal(signal.SIGTERM)
    bridge_server.proc.send_signal(signal.SIGTERM)
    bridge_server.proc.send_signal(signal.SIGINT)
    rc = wait_or_fail(bridge_server.proc, SHUTDOWN_TIMEOUT_SEC, "bridge hung after duplicate shutdown signals")
    assert rc == 0

    out = bridge_server.proc.stdout.read() if bridge_server.proc.stdout else ""
    assert "Traceback" not in out
    # Only the first signal should start a shutdown; the shutdown_started
    # guard must turn the extra SIGTERM and the SIGINT into no-ops, not
    # extra "received signal" lines (a mutant that drops the guard logs one
    # line per signal instead).
    assert out.count("received signal") == 1


def test_signal_burst_starts_shutdown_at_most_once(bridge_server, wait_or_fail):
    """Reentrancy stress test: a tight SIGTERM burst starts exactly one
    shutdown and never deadlocks.

    CPython signal handlers are reentrant: while _shutdown() is running, a
    second signal can interrupt it and start a nested call on the same
    (main) thread. That rules out any lock-based guard: a threading.Event
    based version of this guard could self-deadlock if the first call was
    suspended mid-acquire of the Event's internal lock when a reentrant
    second call tried to acquire that same lock — the main thread would
    then be waiting on itself. A tight burst reliably lands inside that
    window (see SIGNAL_BURST_COUNT), so this both catches "started shutdown
    more than once" and would catch the deadlock itself if the guard
    regressed to something lock-based.
    """
    pid = bridge_server.proc.pid
    for _ in range(SIGNAL_BURST_COUNT):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            break

    rc = wait_or_fail(
        bridge_server.proc,
        SHUTDOWN_TIMEOUT_SEC,
        f"bridge did not exit within {SHUTDOWN_TIMEOUT_SEC}s of a {SIGNAL_BURST_COUNT}-signal SIGTERM burst "
        "(deadlock)",
    )
    assert rc == 0

    out = bridge_server.proc.stdout.read() if bridge_server.proc.stdout else ""
    assert out.count("received signal") == 1


def test_shutdown_flag_check_and_set_have_no_reentrancy_window(bridge_module):
    """Static proof there is no signal-recheck point between reading and
    writing main()._shutdown's shutdown_started guard.

    CPython only rechecks for a pending signal at specific bytecode
    boundaries — a function call, a backward jump, or a loop iteration —
    not at arbitrary points. As long as nothing like that sits between the
    guard's read and its write, a reentrant call can never observe the flag
    still False after another call already started reading it: it always
    either arrives before the read (sees False, proceeds — the intended
    first call) or after the write (sees True, returns). If a future change
    adds a call or a loop in that gap — or reintroduces a lock-based guard,
    whose acquire() is itself such a call — this test catches it before it
    can reintroduce the reentrancy bug this guard exists to close.
    """
    main_code = bridge_module.main.__code__
    shutdown_code = next(
        (const for const in main_code.co_consts if hasattr(const, "co_name") and const.co_name == "_shutdown"),
        None,
    )
    assert shutdown_code is not None, "could not find the _shutdown nested function in main()"

    instructions = list(dis.get_instructions(shutdown_code))
    read_idx = next(
        (
            i
            for i, instr in enumerate(instructions)
            if instr.opname in ("LOAD_DEREF", "LOAD_FAST") and instr.argval == "shutdown_started"
        ),
        None,
    )
    assert read_idx is not None, "could not find a read of shutdown_started in _shutdown's bytecode"
    write_idx = next(
        (
            i
            for i, instr in enumerate(instructions[read_idx + 1 :], start=read_idx + 1)
            if instr.opname in ("STORE_DEREF", "STORE_FAST") and instr.argval == "shutdown_started"
        ),
        None,
    )
    assert write_idx is not None, "could not find a write of shutdown_started after its first read"

    # CALL*/JUMP_BACKWARD*/FOR_ITER are the bytecode-level recheck points.
    # LOAD_ATTR/STORE_ATTR/COMPARE_OP/BINARY_OP are included too: on
    # shutdown_started (a plain bool) they're just as safe, but a future
    # refactor that swaps it for something with a property, __eq__, or
    # other dunder could turn one of these into an implicit call without
    # the bytecode looking any different at a glance.
    between = instructions[read_idx + 1 : write_idx]
    risky_opnames = {"FOR_ITER", "LOAD_ATTR", "STORE_ATTR", "COMPARE_OP", "BINARY_OP"}
    risky = [
        instr.opname
        for instr in between
        if instr.opname.startswith("CALL") or "JUMP_BACKWARD" in instr.opname or instr.opname in risky_opnames
    ]
    assert risky == [], (
        f"found {risky} between the shutdown_started check and set — CPython can recheck for a "
        "pending signal at these points, reopening the reentrancy window this guard exists to close"
    )


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
