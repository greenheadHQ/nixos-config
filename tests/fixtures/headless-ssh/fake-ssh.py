#!/usr/bin/env python3
"""Small OpenSSH behavior fixture for the authentication-only dispatcher."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import sys
import time


STATE = Path(os.environ["FAKE_SSH_STATE"])
SCENARIO = json.loads(Path(os.environ["FAKE_SSH_SCENARIO"]).read_text(encoding="utf-8"))
LOG = STATE / "calls.jsonl"


def append(event: str, **extra: object) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as handle:
        handle.write(
            json.dumps(
                {"event": event, "argv": sys.argv[1:], "pid": os.getpid(), **extra},
                sort_keys=True,
            )
            + "\n"
        )


def option_value(argv: list[str], option: str) -> str | None:
    for index, token in enumerate(argv):
        if token == option and index + 1 < len(argv):
            return argv[index + 1]
        if token.startswith(option) and token != option:
            return token[len(option) :]
    return None


def o_value(argv: list[str], key: str) -> str | None:
    key = key.lower()
    for index, token in enumerate(argv):
        if token != "-o" or index + 1 >= len(argv):
            continue
        raw = argv[index + 1]
        name, separator, value = raw.partition("=")
        if not separator:
            name, _, value = raw.partition(" ")
        if name.lower() == key:
            return value
    return None


def process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def state_path(control_path: str) -> Path:
    digest = hashlib.sha256(control_path.encode()).hexdigest()[:20]
    return STATE / f"master-{digest}.json"


def config() -> int:
    append("config")
    delay = float(SCENARIO.get("config_delay", 0))
    if delay:
        time.sleep(delay)
    if int(SCENARIO.get("config_exit", 0)):
        return int(SCENARIO["config_exit"])
    values = {
        "host": SCENARIO.get("host", "minipc"),
        "hostname": SCENARIO.get("hostname", "100.64.0.2"),
        "user": SCENARIO.get("user", "greenhead"),
        "port": str(SCENARIO.get("port", 22)),
        "controlmaster": SCENARIO.get("controlmaster", "auto"),
        "controlpath": SCENARIO.get("controlpath", "none"),
        "identityagent": SCENARIO.get("identityagent", "/fixture/1password/agent.sock"),
        "requesttty": SCENARIO.get("requesttty", "auto"),
        "proxycommand": SCENARIO.get("proxycommand", "none"),
        "proxyjump": SCENARIO.get("proxyjump", "none"),
        "stricthostkeychecking": SCENARIO.get("stricthostkeychecking", "ask"),
        "userknownhostsfile": SCENARIO.get(
            "userknownhostsfile", "~/.ssh/known_hosts ~/.ssh/known_hosts2"
        ),
        "identityfile": SCENARIO.get("identityfile", "~/.ssh/id_ed25519"),
        "forkafterauthentication": SCENARIO.get("forkafterauthentication", "no"),
    }
    for key, value in values.items():
        for item in value if isinstance(value, list) else [value]:
            print(f"{key} {item}")
    return 0


def master(argv: list[str]) -> int:
    append("auth")
    behavior = SCENARIO.get("auth", "ready")
    if behavior == "exit255":
        print(SCENARIO.get("auth_stderr", "fixture auth failed"), file=sys.stderr)
        return 255
    if behavior == "stall":
        while True:
            time.sleep(1)
    if behavior == "stall-ignore-term":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True:
            time.sleep(1)
    delay = float(SCENARIO.get("auth_delay", 0.02))
    if delay:
        time.sleep(delay)
    control_path = o_value(argv, "ControlPath")
    if not control_path:
        return 97
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        os.setsid()
        devnull = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(devnull, fd)
        if devnull > 2:
            os.close(devnull)
        socket_path = Path(control_path)
        socket_path.parent.mkdir(parents=True, exist_ok=True)
        socket_path.unlink(missing_ok=True)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(control_path)
        state_path(control_path).write_text(
            json.dumps({"pid": os.getpid(), "socket": control_path}), encoding="utf-8"
        )
        os.write(write_fd, b"1")
        os.close(write_fd)
        stop = False

        def request_stop(_signum: int, _frame: object) -> None:
            nonlocal stop
            stop = True

        signal.signal(signal.SIGTERM, request_stop)
        deadline = time.monotonic() + float(SCENARIO.get("master_lifetime", 30))
        while not stop and time.monotonic() < deadline:
            time.sleep(0.02)
        server.close()
        socket_path.unlink(missing_ok=True)
        state_path(control_path).unlink(missing_ok=True)
        os._exit(0)
    os.close(write_fd)
    ready = os.read(read_fd, 1)
    os.close(read_fd)
    return 0 if ready == b"1" else 98


def control(argv: list[str]) -> int:
    operation = option_value(argv, "-O")
    control_path = option_value(argv, "-S")
    append(f"control-{operation}", controlPath=control_path)
    if not control_path:
        return 255
    record_path = state_path(control_path)
    if not record_path.exists():
        return 255
    record = json.loads(record_path.read_text(encoding="utf-8"))
    pid = int(record["pid"])
    if not process_alive(pid) or not Path(control_path).exists():
        return 255
    if operation == "check":
        return 0
    if operation == "exit":
        os.kill(pid, signal.SIGTERM)
        return 0
    return 255


def data(argv: list[str]) -> int:
    control_path = option_value(argv, "-S")
    if control_path:
        record_path = state_path(control_path)
        if not record_path.exists():
            append("data-no-master")
            return 255
        record = json.loads(record_path.read_text(encoding="utf-8"))
        if not process_alive(int(record["pid"])):
            append("data-stale-master")
            return 255
    append("data")
    delay = float(SCENARIO.get("remote_delay", 0))
    if delay:
        time.sleep(delay)
    if SCENARIO.get("stdout"):
        print(SCENARIO["stdout"], end="")
    if SCENARIO.get("stderr"):
        print(SCENARIO["stderr"], end="", file=sys.stderr)
    return int(SCENARIO.get("remote_exit", 0))


def main() -> int:
    argv = sys.argv[1:]
    if "-V" in argv or "-Q" in argv:
        append("meta")
        return int(SCENARIO.get("meta_exit", 0))
    if "-G" in argv:
        return config()
    if "-O" in argv or any(token.startswith("-O") for token in argv):
        return control(argv)
    if "-M" in argv and ("-N" in argv or any("N" in token[1:] for token in argv if token.startswith("-"))):
        return master(argv)
    return data(argv)


if __name__ == "__main__":
    raise SystemExit(main())
