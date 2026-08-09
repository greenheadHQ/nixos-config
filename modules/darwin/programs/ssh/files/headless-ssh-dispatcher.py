#!/usr/bin/env python3
"""Launcher-scoped MiniPC SSH dispatcher with an authentication-only deadline."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


INTERNAL_ERROR = 125
AUTH_TIMEOUT = 124
AUTH_TIMEOUT_KILLED = 128 + signal.SIGKILL
AUTH_TIMEOUT_RECOVERY = (
    "HEADLESS_SSH_AUTH_TIMEOUT: MiniPC authentication did not complete before the deadline; "
    "the launcher uses the dedicated minipc-headless key and never waits for a 1Password GUI. "
    "Check Tailscale reachability, the agenix key materialization, and the MiniPC authorized_keys entry."
)


class ContractError(RuntimeError):
    def __init__(self, code: str, detail: str | None = None):
        self.code = code
        self.detail = detail
        super().__init__(code if detail is None else f"{code}: {detail}")


@dataclass(frozen=True)
class Contract:
    real_ssh: Path
    timeout_bin: Path
    manifest: dict[str, object]
    headless_key: Path
    runtime_dir: Path
    target_host: str
    target_user: str
    target_port: int
    managed_destinations: frozenset[str]
    raw_destinations: frozenset[str]
    auth_deadline: float
    control_deadline: float
    cleanup_grace: float

    @classmethod
    def from_args(cls, args: argparse.Namespace) -> "Contract":
        try:
            manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise ContractError("HEADLESS_SSH_MANIFEST_INVALID") from exc
        if manifest.get("schemaVersion") != 1 or not isinstance(
            manifest.get("shortOptionArity"), dict
        ):
            raise ContractError("HEADLESS_SSH_MANIFEST_INVALID")
        deadlines = (args.auth_deadline, args.control_deadline, args.cleanup_grace)
        if not all(math.isfinite(value) and value > 0 for value in deadlines):
            raise ContractError("HEADLESS_SSH_DEADLINE_INVALID")
        contract = cls(
            real_ssh=Path(args.real_ssh),
            timeout_bin=Path(args.timeout_bin),
            manifest=manifest,
            headless_key=Path(args.headless_key),
            runtime_dir=Path(args.runtime_dir),
            target_host=args.target_host,
            target_user=args.target_user,
            target_port=args.target_port,
            managed_destinations=frozenset(args.managed_destination),
            raw_destinations=frozenset(args.raw_destination),
            auth_deadline=float(args.auth_deadline),
            control_deadline=float(args.control_deadline),
            cleanup_grace=float(args.cleanup_grace),
        )
        contract.validate_dependencies()
        return contract

    def validate_dependencies(self) -> None:
        for path, code in (
            (self.real_ssh, "HEADLESS_SSH_REAL_BINARY_INVALID"),
            (self.timeout_bin, "HEADLESS_SSH_TIMEOUT_BINARY_INVALID"),
        ):
            try:
                info = path.stat()
            except OSError as exc:
                raise ContractError(code) from exc
            if not path.is_absolute() or not stat.S_ISREG(info.st_mode) or not os.access(path, os.X_OK):
                raise ContractError(code)
        if self.real_ssh.resolve() == Path(sys.argv[0]).resolve():
            raise ContractError("HEADLESS_SSH_RECURSIVE_BINARY")


@dataclass(frozen=True)
class Invocation:
    argv: tuple[str, ...]
    destination: str | None
    normalized_destination: str | None
    options: tuple[tuple[str, str | None], ...]
    meta: bool


def normalize_destination(value: str) -> str:
    if value.startswith("ssh://"):
        authority = value[6:].split("/", 1)[0].rsplit("@", 1)[-1]
        if authority.startswith("[") and "]" in authority:
            return authority[1 : authority.index("]")]
        return authority.split(":", 1)[0]
    return value.rsplit("@", 1)[-1]


def parse_invocation(argv: list[str], manifest: dict[str, object]) -> Invocation:
    arity = manifest["shortOptionArity"]
    assert isinstance(arity, dict)
    options: list[tuple[str, str | None]] = []
    destination: str | None = None
    meta = False
    index = 0
    while index < len(argv):
        token = argv[index]
        if token == "--":
            index += 1
            if index < len(argv):
                destination = argv[index]
            break
        if token == "-" or not token.startswith("-"):
            destination = token
            break
        if token.startswith("--"):
            raise ContractError("HEADLESS_SSH_OPTION_UNSUPPORTED", token)
        cluster = token[1:]
        cursor = 0
        while cursor < len(cluster):
            flag = cluster[cursor]
            if flag not in arity:
                raise ContractError("HEADLESS_SSH_OPTION_UNSUPPORTED", f"-{flag}")
            takes_value = arity[flag] == 1
            value: str | None = None
            if takes_value:
                if cursor + 1 < len(cluster):
                    value = cluster[cursor + 1 :]
                    cursor = len(cluster)
                else:
                    index += 1
                    if index >= len(argv):
                        raise ContractError("HEADLESS_SSH_OPTION_VALUE_MISSING", f"-{flag}")
                    value = argv[index]
                    cursor = len(cluster)
            else:
                cursor += 1
            options.append((flag, value))
            if flag in {"V", "G", "O", "Q"}:
                meta = True
        index += 1
    return Invocation(
        argv=tuple(argv),
        destination=destination,
        normalized_destination=normalize_destination(destination) if destination else None,
        options=tuple(options),
        meta=meta,
    )


def exec_real(contract: Contract, argv: tuple[str, ...]) -> "None":
    os.execv(contract.real_ssh, [str(contract.real_ssh), *argv])
    raise AssertionError("unreachable")


def timeout_command(contract: Contract, seconds: float, command: list[str]) -> list[str]:
    return [
        str(contract.timeout_bin),
        "--foreground",
        "--signal=TERM",
        f"--kill-after={contract.cleanup_grace:g}s",
        f"{seconds:g}s",
        *command,
    ]


def run_control(
    contract: Contract,
    seconds: float,
    command: list[str],
    *,
    capture_stdout: bool = False,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        timeout_command(contract, seconds, command),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE if capture_stdout else subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )


def parse_effective_config(output: str) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    for line in output.splitlines():
        key, separator, value = line.partition(" ")
        if not separator or not key or not value:
            raise ContractError("HEADLESS_SSH_EFFECTIVE_CONFIG_INVALID")
        result.setdefault(key.lower(), []).append(value)
    return result


def first(config: dict[str, list[str]], key: str, default: str | None = None) -> str | None:
    values = config.get(key, [])
    return values[0] if values else default


def effective_config(contract: Contract, invocation: Invocation) -> dict[str, list[str]]:
    result = run_control(
        contract,
        contract.control_deadline,
        [str(contract.real_ssh), "-G", *invocation.argv],
        capture_stdout=True,
    )
    if result.returncode == AUTH_TIMEOUT:
        raise ContractError("HEADLESS_SSH_CONFIG_TIMEOUT")
    if result.returncode != 0:
        raise ContractError("HEADLESS_SSH_CONFIG_FAILED", str(result.returncode))
    return parse_effective_config(result.stdout)


def ensure_managed_options(invocation: Invocation) -> None:
    forbidden_flags = {"M", "S", "i", "I", "J"}
    for flag, value in invocation.options:
        if flag in forbidden_flags:
            raise ContractError("HEADLESS_SSH_MANAGED_OPTION_UNSUPPORTED", f"-{flag}")
        if flag == "o" and value:
            key = value.split("=", 1)[0].split(None, 1)[0].lower()
            if key in {
                "controlmaster",
                "controlpath",
                "controlpersist",
                "identityagent",
                "identityfile",
                "proxycommand",
                "proxyjump",
            }:
                raise ContractError("HEADLESS_SSH_MANAGED_OPTION_UNSUPPORTED", key)


AUTH_TRANSPORT_OPTION_KEYS = frozenset(
    {
        "addressfamily",
        "bindaddress",
        "bindinterface",
        "casignaturealgorithms",
        "checkhostip",
        "ciphers",
        "compression",
        "fingerprinthash",
        "globalknownhostsfile",
        "hashknownhosts",
        "hostkeyalgorithms",
        "hostkeyalias",
        "ipqos",
        "kexalgorithms",
        "knownhostscommand",
        "loglevel",
        "logverbose",
        "macs",
        "pubkeyacceptedalgorithms",
        "rekeylimit",
        "revokedhostkeys",
        "requiredrsasize",
        "serveralivecountmax",
        "serveraliveinterval",
        "stricthostkeychecking",
        "tag",
        "tcpkeepalive",
        "updatehostkeys",
        "userknownhostsfile",
        "verifyhostkeydns",
    }
)


def auth_transport_options(config: dict[str, list[str]]) -> list[str]:
    # Replay only the evaluated, auth-transport-safe subset. Loading a custom
    # -F again would also reload IdentityFile and LocalCommand directives.
    result: list[str] = ["-F", "none"]
    for key in sorted(AUTH_TRANSPORT_OPTION_KEYS):
        for value in config.get(key, []):
            result.extend(("-o", f"{key}={value}"))
    return result


def validate_key(path: Path) -> None:
    try:
        info = path.stat()
    except OSError as exc:
        raise ContractError("HEADLESS_SSH_KEY_UNAVAILABLE") from exc
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o400
        or not os.access(path, os.R_OK)
    ):
        raise ContractError("HEADLESS_SSH_KEY_INVALID")


def ensure_runtime_dir(path: Path) -> None:
    try:
        path.mkdir(parents=True, mode=0o700, exist_ok=True)
        os.chmod(path, 0o700)
        info = path.lstat()
    except OSError as exc:
        raise ContractError("HEADLESS_SSH_RUNTIME_DIR_INVALID") from exc
    if (
        not stat.S_ISDIR(info.st_mode)
        or stat.S_ISLNK(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        raise ContractError("HEADLESS_SSH_RUNTIME_DIR_INVALID")


def target_argv(contract: Contract) -> list[str]:
    return ["-p", str(contract.target_port), f"{contract.target_user}@{contract.target_host}"]


def control_check(contract: Contract, control_path: str) -> bool:
    result = run_control(
        contract,
        contract.control_deadline,
        [
            str(contract.real_ssh),
            "-F",
            "none",
            "-S",
            control_path,
            "-O",
            "check",
            *target_argv(contract),
        ],
    )
    return result.returncode == 0


def control_exit(contract: Contract, control_path: str) -> None:
    run_control(
        contract,
        contract.control_deadline,
        [
            str(contract.real_ssh),
            "-F",
            "none",
            "-S",
            control_path,
            "-O",
            "exit",
            *target_argv(contract),
        ],
    )


def data_command(contract: Contract, control_path: str, invocation: Invocation) -> list[str]:
    # These command-line values are deliberately first: OpenSSH uses the first
    # obtained value, so a vanished mux socket fails through /usr/bin/false
    # instead of starting a second unbounded authentication attempt.
    return [
        str(contract.real_ssh),
        "-S",
        control_path,
        "-o",
        "ControlMaster=no",
        "-o",
        f"ControlPath={control_path}",
        "-o",
        "ProxyCommand=/usr/bin/false",
        "-o",
        "IdentityAgent=none",
        "-o",
        "BatchMode=yes",
        *invocation.argv,
    ]


def run_data(command: list[str]) -> int:
    child: subprocess.Popen[bytes] | None = None
    forwarded: list[int] = []
    pending_before_spawn: list[int] = []
    previous: dict[int, object] = {}

    def forward(signum: int, _frame: object) -> None:
        forwarded.append(signum)
        if child is None:
            pending_before_spawn.append(signum)
        elif child.poll() is None:
            try:
                child.send_signal(signum)
            except ProcessLookupError:
                pass

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM):
        previous[signum] = signal.getsignal(signum)
        signal.signal(signum, forward)
    try:
        child = subprocess.Popen(command)
        for signum in pending_before_spawn:
            if child.poll() is not None:
                break
            try:
                child.send_signal(signum)
            except ProcessLookupError:
                break
        returncode = child.wait()
    finally:
        for signum, disposition in previous.items():
            signal.signal(signum, disposition)
    if forwarded and returncode == 0:
        return 128 + forwarded[-1]
    return returncode


def dispatch(contract: Contract, ssh_argv: list[str]) -> int:
    invocation = parse_invocation(ssh_argv, contract.manifest)
    if invocation.meta or invocation.destination is None:
        exec_real(contract, invocation.argv)
    assert invocation.normalized_destination is not None
    if invocation.normalized_destination in contract.raw_destinations:
        exec_real(contract, invocation.argv)
    # 일반 다른 host는 config를 두 번 평가하지 않고 raw exact-once로 보낸다.
    # 다만 caller가 별도 config(-F)나 explicit HostName을 제시하면 lexical alias만으로
    # MiniPC 여부를 알 수 없으므로 bounded effective classification을 수행한다.
    ambiguous_destination = any(
        flag == "F"
        or (
            flag == "o"
            and value is not None
            and value.split("=", 1)[0].split(None, 1)[0].lower() == "hostname"
        )
        for flag, value in invocation.options
    )
    if (
        invocation.normalized_destination not in contract.managed_destinations
        and invocation.normalized_destination != contract.target_host
        and not ambiguous_destination
    ):
        exec_real(contract, invocation.argv)

    config = effective_config(contract, invocation)
    host = first(config, "hostname")
    user = first(config, "user")
    port = first(config, "port", "22")
    if host != contract.target_host:
        exec_real(contract, invocation.argv)
    if user != contract.target_user or port != str(contract.target_port):
        raise ContractError("HEADLESS_SSH_TARGET_TUPLE_UNSUPPORTED")
    ensure_managed_options(invocation)
    if first(config, "proxycommand", "none") != "none" or first(
        config, "proxyjump", "none"
    ) != "none":
        raise ContractError("HEADLESS_SSH_MANAGED_OPTION_UNSUPPORTED", "proxy")

    configured_control = first(config, "controlpath", "none")
    if configured_control and configured_control != "none" and control_check(
        contract, configured_control
    ):
        return run_data(data_command(contract, configured_control, invocation))

    validate_key(contract.headless_key)
    ensure_runtime_dir(contract.runtime_dir)
    call_dir = Path(tempfile.mkdtemp(prefix="call-", dir=contract.runtime_dir))
    os.chmod(call_dir, 0o700)
    control_path = str(call_dir / "m")
    background_data = first(config, "forkafterauthentication", "no") == "yes"
    auth = [
        str(contract.real_ssh),
        *auth_transport_options(config),
        "-fN",
        "-M",
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentityAgent=none",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "PasswordAuthentication=no",
        "-o",
        "KbdInteractiveAuthentication=no",
        "-o",
        "PubkeyAuthentication=yes",
        "-o",
        f"ControlPath={control_path}",
        "-o",
        "ControlPersist=5",
        "-o",
        f"HostName={contract.target_host}",
        "-o",
        f"User={contract.target_user}",
        "-o",
        f"Port={contract.target_port}",
        "-o",
        "ProxyCommand=none",
        "-o",
        "ProxyJump=none",
        "-o",
        "RemoteCommand=none",
        "-o",
        "RequestTTY=no",
        "-o",
        "SessionType=none",
        "-o",
        "ClearAllForwardings=yes",
        "-o",
        "GSSAPIAuthentication=no",
        "-o",
        "HostbasedAuthentication=no",
        "-o",
        "PreferredAuthentications=publickey",
        "-o",
        "PermitLocalCommand=no",
        "-o",
        "LocalCommand=none",
        "-o",
        f"ConnectTimeout={max(1, math.ceil(contract.auth_deadline))}",
        "-o",
        "ConnectionAttempts=1",
        "-i",
        str(contract.headless_key),
        f"{contract.target_user}@{contract.target_host}",
    ]
    try:
        auth_result = subprocess.run(
            timeout_command(contract, contract.auth_deadline, auth),
            stdin=subprocess.DEVNULL,
            check=False,
        )
        if auth_result.returncode in {AUTH_TIMEOUT, AUTH_TIMEOUT_KILLED}:
            print(AUTH_TIMEOUT_RECOVERY, file=sys.stderr)
            return AUTH_TIMEOUT
        if auth_result.returncode != 0:
            return auth_result.returncode
        if not control_check(contract, control_path):
            raise ContractError("HEADLESS_SSH_AUTH_MASTER_UNAVAILABLE")
        return run_data(data_command(contract, control_path, invocation))
    finally:
        if not background_data and (
            Path(control_path).exists() or Path(control_path).is_symlink()
        ):
            control_exit(contract, control_path)
        shutil.rmtree(call_dir, ignore_errors=True)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(add_help=False)
    result.add_argument("--real-ssh", required=True)
    result.add_argument("--timeout-bin", required=True)
    result.add_argument("--manifest", required=True)
    result.add_argument("--headless-key", required=True)
    result.add_argument("--runtime-dir", required=True)
    result.add_argument("--target-host", required=True)
    result.add_argument("--target-user", required=True)
    result.add_argument("--target-port", type=int, required=True)
    result.add_argument("--managed-destination", action="append", default=[])
    result.add_argument("--raw-destination", action="append", default=[])
    result.add_argument("--auth-deadline", type=float, required=True)
    result.add_argument("--control-deadline", type=float, required=True)
    result.add_argument("--cleanup-grace", type=float, required=True)
    result.add_argument("ssh_argv", nargs=argparse.REMAINDER)
    return result


def main() -> int:
    try:
        args = parser().parse_args()
        ssh_argv = list(args.ssh_argv)
        if ssh_argv[:1] == ["--"]:
            ssh_argv = ssh_argv[1:]
        contract = Contract.from_args(args)
        returncode = dispatch(contract, ssh_argv)
        if returncode < 0:
            signum = -returncode
            if signum != signal.SIGKILL:
                signal.signal(signum, signal.SIG_DFL)
            os.kill(os.getpid(), signum)
        return returncode
    except ContractError as error:
        print(error, file=sys.stderr)
        return INTERNAL_ERROR
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
