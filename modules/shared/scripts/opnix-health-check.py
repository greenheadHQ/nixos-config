#!/usr/bin/env python3
"""Check the deployed SA's actual secret access; never infer expiry from failures."""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def clean_environment():
    return {k: v for k, v in os.environ.items()
            if not k.startswith("OP_SESSION") and k not in {
                "OP_SERVICE_ACCOUNT_TOKEN", "OP_CONNECT_HOST", "OP_CONNECT_TOKEN",
                "OP_ACCOUNT", "OPNIX_ENV_CONFIG", "OPNIX_ENV_CONFIG_JSON",
            }}


def run_bounded(command, env, timeout):
    # stdout can contain a secret; keep it only in memory. Raw errors can also
    # contain credentials and must never enter launchd/systemd logs or alerts.
    with subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          start_new_session=True) as child:
        try:
            output, _ = child.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate()
            raise
        return child.returncode, output


def probe(config):
    env = clean_environment()
    try:
        # Even opnix must fail closed before running if its token is unavailable.
        token = Path(config["tokenFile"]).read_text().strip()
        if not token:
            return "credential_unavailable"
    except OSError:
        return "credential_unavailable"
    if config["backend"] == "op":
        env["OP_SERVICE_ACCOUNT_TOKEN"] = token
        command = [config["program"], "read", "--no-newline", config["reference"]]
    elif config["backend"] == "opnix":
        # A static-only/optional env configuration can succeed without auth.
        refs = {"vars": [{"name": "TOKEN", "reference": config["reference"]}]}
        command = [config["program"], "env", "-token-file", config["tokenFile"],
                   "-config-json", json.dumps(refs), "-format", "json"]
    else:
        raise ValueError("unsupported backend")
    try:
        code, value = run_bounded(command, env, config["timeoutSeconds"])
    except subprocess.TimeoutExpired:
        return "timeout"
    except OSError:
        return "client_unavailable"
    if code:
        # Both clients can report network/auth errors using the same exit code.
        return "read_failed"
    if config["backend"] == "opnix":
        try:
            value = json.loads(value)["TOKEN"]
        except (ValueError, KeyError, TypeError):
            return "invalid_result"
        if not isinstance(value, str):
            return "invalid_result"
    return "ok" if value.strip() else "empty_result"


def notify(config, title, message, priority):
    try:
        code, _ = run_bounded([config["notifier"], title, message, str(priority)],
                              clean_environment(), 15)
        return code == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def save_state(path, state):
    fd, name = tempfile.mkstemp(prefix=".status-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(state, stream)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def check(config):
    root = Path(config["stateDir"])
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    state_file = root / "status.json"
    with (root / "check.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("SA health: another check is running")
            return 0
        state = {"last_success": 0, "last_result": "unknown",
                 "alert_open": False, "last_alert_at": 0}
        try:
            state.update(json.loads(state_file.read_text()))
        except FileNotFoundError:
            pass
        result = probe(config)
        if result != "ok":
            time.sleep(config["retryDelaySeconds"])
            result = probe(config)
        now = int(time.time())
        state["last_result"] = result
        state["last_checked"] = now
        delivered = True
        label = config["hostLabel"]
        if result == "ok":
            state["last_success"] = now
            if state["alert_open"]:
                delivered = notify(config, f"[{label}] 1Password 비밀 조회 복구",
                                   "기존 SA로 필요한 비밀 조회가 다시 성공했습니다.", 0)
                if delivered:
                    state["alert_open"] = False
                    state["last_alert_at"] = now
        elif not state["alert_open"] or now - state["last_alert_at"] >= config["reminderSeconds"]:
            reasons = {
                "timeout": "조회 시간 제한을 초과했습니다.",
                "credential_unavailable": "SA 자격 파일을 읽을 수 없거나 파일이 비어 있습니다.",
                "client_unavailable": "조회 도구를 실행할 수 없습니다.",
                "read_failed": "네트워크·접근 권한·자격 상태를 확인해 주세요.",
                "invalid_result": "조회 결과의 형식이 올바르지 않습니다.",
                "empty_result": "조회한 비밀 값이 비어 있습니다.",
            }
            last = (time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(state["last_success"]))
                    if state["last_success"] else "성공 기록 없음")
            delivered = notify(config, f"[{label}] 1Password 비밀 조회 실패",
                               f"재시도 후에도 조회하지 못했습니다. {reasons[result]} 마지막 성공: {last}", 1)
            if delivered:
                state["alert_open"] = True
                state["last_alert_at"] = now
        save_state(state_file, state)
        print(f"SA health ({label}): {result}; notification={'ok' if delivered else 'failed'}")
        return 0 if result == "ok" and delivered else 1


def main():
    os.umask(0o077)
    try:
        return check(json.loads(Path(sys.argv[1]).read_text()))
    except (OSError, ValueError, TypeError, KeyError) as error:
        # Never print exception text: it can contain config or credential data.
        print(f"SA health: local check error ({type(error).__name__})", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
