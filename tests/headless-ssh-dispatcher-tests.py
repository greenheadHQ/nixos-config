#!/usr/bin/env python3
"""Hermetic behavioral tests for the launcher-scoped SSH dispatcher."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
CORE = REPO / "modules/darwin/programs/ssh/files/headless-ssh-dispatcher.py"
FAKE = REPO / "tests/fixtures/headless-ssh/fake-ssh.py"
MANIFEST = REPO / "tests/fixtures/headless-ssh/compatible-manifest.json"
PRODUCTION_MANIFEST = (
    REPO / "modules/darwin/programs/ssh/files/darwin-openssh-10.3p1.json"
)
DISPATCHER_NIX = REPO / "modules/darwin/programs/ssh/headless-dispatcher.nix"
SYSTEM_SSH = Path("/usr/bin/ssh")
# usage에서 사라졌어도 매니페스트에 남는 것을 허용하는 레거시 항목 (protocol version 선택).
# 이 집합 밖의 "매니페스트에만 있음"은 실제 옵션 삭제이므로 드리프트로 실패시킨다.
LEGACY_MANIFEST_ONLY = frozenset({"1", "2"})

_USAGE_FLAG_CLUSTER = re.compile(r"-([A-Za-z0-9]+)\Z")
_USAGE_FLAG_WITH_VALUE = re.compile(r"-([A-Za-z0-9])\s+\S", re.DOTALL)


def load_dispatcher_module():
    spec = importlib.util.spec_from_file_location("headless_ssh_dispatcher", CORE)
    if spec is None or spec.loader is None:
        raise RuntimeError("dispatcher module could not be loaded")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class DispatcherFixture(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="headless-ssh-test-")
        self.root = Path(self._tmp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.fake = self.root / "fake-ssh"
        shutil.copyfile(FAKE, self.fake)
        os.chmod(self.fake, 0o755)
        self.timeout_bin = shutil.which("timeout")
        if self.timeout_bin is None:
            self.fail("GNU timeout is required by the hermetic dispatcher fixture")
        self.key = self.root / "minipc-headless"
        self.key.write_text("fixture-not-a-private-key", encoding="utf-8")
        os.chmod(self.key, 0o400)
        self.runtime = self.root / "runtime"
        self.scenario = self.root / "scenario.json"
        self.write_scenario()

    def tearDown(self) -> None:
        for record_path in self.state.glob("master-*.json"):
            try:
                pid = int(json.loads(record_path.read_text(encoding="utf-8"))["pid"])
                os.kill(pid, signal.SIGTERM)
            except (OSError, ValueError, KeyError, json.JSONDecodeError):
                pass
        self._tmp.cleanup()

    def write_scenario(self, **values: object) -> None:
        scenario = {
            "hostname": "100.64.0.2",
            "user": "greenhead",
            "port": 22,
            "controlpath": "none",
            "auth": "ready",
        }
        scenario.update(values)
        self.scenario.write_text(json.dumps(scenario), encoding="utf-8")

    def env(self) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(
            FAKE_SSH_STATE=str(self.state),
            FAKE_SSH_SCENARIO=str(self.scenario),
        )
        return environment

    def command(
        self,
        *ssh_argv: str,
        auth_deadline: float = 1.0,
        real_ssh: Path | None = None,
        timeout_bin: str | None = None,
    ) -> list[str]:
        return [
            sys.executable,
            str(CORE),
            "--real-ssh",
            str(real_ssh or self.fake),
            "--timeout-bin",
            timeout_bin or str(self.timeout_bin),
            "--manifest",
            str(MANIFEST),
            "--headless-key",
            str(self.key),
            "--runtime-dir",
            str(self.runtime),
            "--target-host",
            "100.64.0.2",
            "--target-user",
            "greenhead",
            "--target-port",
            "22",
            "--managed-destination",
            "minipc",
            "--managed-destination",
            "minipc-headless",
            "--managed-destination",
            "100.64.0.2",
            "--raw-destination",
            "minipc-emergency",
            "--auth-deadline",
            str(auth_deadline),
            "--control-deadline",
            "0.8",
            "--cleanup-grace",
            "0.15",
            "--",
            *ssh_argv,
        ]

    def run_dispatch(self, *ssh_argv: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
        command_keys = {"auth_deadline", "real_ssh", "timeout_bin"}
        command_kwargs = {key: kwargs.pop(key) for key in list(kwargs) if key in command_keys}
        return subprocess.run(
            self.command(*ssh_argv, **command_kwargs),
            env=self.env(),
            text=True,
            capture_output=True,
            timeout=float(kwargs.pop("timeout", 6)),
            check=False,
            **kwargs,
        )

    def calls(self) -> list[dict[str, object]]:
        log = self.state / "calls.jsonl"
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]

    def events(self) -> list[str]:
        return [str(call["event"]) for call in self.calls()]

    def clear_calls(self) -> None:
        (self.state / "calls.jsonl").unlink(missing_ok=True)

    def wait_for_event(self, event: str, timeout: float = 3) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if event in self.events():
                return
            time.sleep(0.01)
        self.fail(f"event not observed: {event}")

    def start_external_master(self, control_path: Path) -> None:
        result = subprocess.run(
            [
                str(self.fake),
                "-F",
                "none",
                "-fN",
                "-M",
                "-o",
                f"ControlPath={control_path}",
                "greenhead@100.64.0.2",
            ],
            env=self.env(),
            text=True,
            capture_output=True,
            check=False,
            timeout=3,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(control_path.exists())


class CoreContractTests(DispatcherFixture):
    def test_success_preserves_stdout_stderr_and_exit_zero(self) -> None:
        self.write_scenario(stdout="out", stderr="err")
        result = self.run_dispatch("minipc", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "out")
        self.assertEqual(result.stderr, "err")
        self.assertIn("auth", self.events())
        self.assertIn("data", self.events())

    def test_immediate_auth_255_and_stderr_are_preserved(self) -> None:
        self.write_scenario(auth="exit255", auth_stderr="public fixture failure")
        result = self.run_dispatch("minipc", "true")
        self.assertEqual(result.returncode, 255, result.stderr)
        self.assertIn("public fixture failure", result.stderr)
        self.assertNotIn("HEADLESS_SSH_AUTH_TIMEOUT", result.stderr)

    def test_auth_stall_is_bounded_and_diagnosed(self) -> None:
        self.write_scenario(auth="stall")
        started = time.monotonic()
        result = self.run_dispatch("minipc", "true", auth_deadline=0.25)
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertLess(elapsed, 2.25)
        self.assertIn("HEADLESS_SSH_AUTH_TIMEOUT", result.stderr)
        self.assertIn("never waits for a 1Password GUI", result.stderr)

    def test_auth_stall_that_ignores_term_is_still_124_and_diagnosed(self) -> None:
        self.write_scenario(auth="stall-ignore-term")
        started = time.monotonic()
        result = self.run_dispatch("minipc", "true", auth_deadline=0.25)
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertLess(elapsed, 2.25)
        self.assertIn("HEADLESS_SSH_AUTH_TIMEOUT", result.stderr)

    def test_post_auth_long_command_outlives_auth_deadline(self) -> None:
        self.write_scenario(remote_delay=1.5, stdout="long-ok")
        started = time.monotonic()
        result = self.run_dispatch("minipc", "long", auth_deadline=1.0)
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "long-ok")
        self.assertGreaterEqual(elapsed, 1.4)

    def test_remote_124_is_not_mislabeled_as_auth_timeout(self) -> None:
        self.write_scenario(remote_exit=124, stderr="remote-124")
        result = self.run_dispatch("minipc", "remote")
        self.assertEqual(result.returncode, 124)
        self.assertEqual(result.stderr, "remote-124")

    def test_signal_received_during_spawn_is_forwarded_to_the_new_child(self) -> None:
        dispatcher = load_dispatcher_module()
        delivered: list[int] = []

        class SignalDuringSpawn:
            def __init__(self, _command: list[str]):
                self.returncode: int | None = None
                os.kill(os.getpid(), signal.SIGTERM)

            def poll(self) -> int | None:
                return self.returncode

            def send_signal(self, signum: int) -> None:
                delivered.append(signum)
                self.returncode = -signum

            def wait(self) -> int:
                return self.returncode if self.returncode is not None else 0

        with mock.patch.object(dispatcher.subprocess, "Popen", SignalDuringSpawn):
            result = dispatcher.run_data(["unused"])

        self.assertEqual(delivered, [signal.SIGTERM])
        self.assertEqual(result, -signal.SIGTERM)

    def test_sigkill_exit_is_reproduced_without_changing_its_disposition(self) -> None:
        dispatcher = load_dispatcher_module()
        parsed = mock.Mock(ssh_argv=[])
        contract = mock.Mock()

        with (
            mock.patch.object(dispatcher, "parser") as parser_mock,
            mock.patch.object(dispatcher.Contract, "from_args", return_value=contract),
            mock.patch.object(dispatcher, "dispatch", return_value=-signal.SIGKILL),
            mock.patch.object(dispatcher.signal, "signal") as disposition,
            mock.patch.object(dispatcher.os, "kill") as self_kill,
        ):
            parser_mock.return_value.parse_args.return_value = parsed
            result = dispatcher.main()

        disposition.assert_not_called()
        self_kill.assert_called_once_with(os.getpid(), signal.SIGKILL)
        self.assertEqual(result, -signal.SIGKILL)


class ScopeTests(DispatcherFixture):
    def test_protocol_version_options_are_manifested_and_raw_exact_once(self) -> None:
        for manifest_path in (MANIFEST, PRODUCTION_MANIFEST):
            with self.subTest(manifest=manifest_path):
                arity = json.loads(manifest_path.read_text(encoding="utf-8"))["shortOptionArity"]
                self.assertEqual(arity["1"], 0)
                self.assertEqual(arity["2"], 0)

        for option in ("-1", "-2"):
            with self.subTest(option=option):
                self.clear_calls()
                argv = (option, "github.com", "true")
                result = self.run_dispatch(*argv)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.events(), ["data"])
                self.assertEqual(self.calls()[0]["argv"], list(argv))

    def test_emergency_and_other_host_are_raw_exact_once(self) -> None:
        for destination in ("minipc-emergency", "github.com"):
            with self.subTest(destination=destination):
                self.clear_calls()
                result = self.run_dispatch(destination, "true")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.events(), ["data"])

    def test_meta_modes_are_raw_and_do_not_authenticate(self) -> None:
        for argv in (("-V",), ("-Q", "cipher"), ("-G", "minipc"), ("-O", "check", "minipc")):
            with self.subTest(argv=argv):
                self.clear_calls()
                self.run_dispatch(*argv)
                self.assertNotIn("auth", self.events())

    def test_user_target_custom_config_W_and_tty_are_preserved(self) -> None:
        custom = self.root / "custom.conf"
        custom.write_text("Host minipc\n  HostName 100.64.0.2\n", encoding="utf-8")
        invocations = (
            ("greenhead@minipc", "true"),
            ("-F", str(custom), "minipc", "true"),
            ("-W", "127.0.0.1:22", "minipc"),
            ("-tt", "minipc", "true"),
        )
        for argv in invocations:
            with self.subTest(argv=argv):
                self.clear_calls()
                result = self.run_dispatch(*argv)
                self.assertEqual(result.returncode, 0, result.stderr)
                data = next(call for call in self.calls() if call["event"] == "data")
                for token in argv:
                    self.assertIn(token, data["argv"])

    def test_custom_config_and_host_verification_options_reach_auth_master(self) -> None:
        custom = self.root / "custom.conf"
        custom.write_text("Host minipc\n  HostName 100.64.0.2\n", encoding="utf-8")
        known_hosts = self.root / "known-hosts"
        operator_key = self.root / "operator-key"
        self.write_scenario(
            userknownhostsfile=str(known_hosts),
            stricthostkeychecking="yes",
            identityfile=["~/.ssh/id_ed25519", str(operator_key)],
        )
        result = self.run_dispatch(
            "-F",
            str(custom),
            "-o",
            f"UserKnownHostsFile={known_hosts}",
            "-o",
            "StrictHostKeyChecking=yes",
            "minipc",
            "true",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        auth = next(call for call in self.calls() if call["event"] == "auth")
        self.assertNotIn(str(custom), auth["argv"])
        self.assertNotIn(str(operator_key), auth["argv"])
        self.assertIn(str(self.key), auth["argv"])
        self.assertIn(f"userknownhostsfile={known_hosts}", auth["argv"])
        self.assertIn("stricthostkeychecking=yes", auth["argv"])

    def test_auth_master_does_not_enable_confirmation_mode(self) -> None:
        result = self.run_dispatch("minipc", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        auth = next(call for call in self.calls() if call["event"] == "auth")
        self.assertEqual(auth["argv"].count("-M"), 1)
        self.assertNotIn("ControlMaster=yes", auth["argv"])

    def test_custom_config_alias_to_minipc_is_managed_and_bounded(self) -> None:
        custom = self.root / "custom-alias.conf"
        custom.write_text(
            "Host lab-box\n  HostName 100.64.0.2\n  User greenhead\n",
            encoding="utf-8",
        )
        result = self.run_dispatch("-F", str(custom), "lab-box", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events()[:2], ["config", "auth"])
        data = next(call for call in self.calls() if call["event"] == "data")
        self.assertIn("lab-box", data["argv"])

    def test_explicit_hostname_retarget_to_minipc_is_managed(self) -> None:
        result = self.run_dispatch(
            "-o", "HostName=100.64.0.2", "lab-box", "true"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("auth", self.events())

    def test_effective_retarget_to_other_host_returns_to_raw_path(self) -> None:
        self.write_scenario(hostname="example.test", user="alice")
        result = self.run_dispatch("minipc", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), ["config", "data"])

    def test_managed_identity_override_fails_before_authentication(self) -> None:
        result = self.run_dispatch("-i", "/tmp/other-key", "minipc", "true")
        self.assertEqual(result.returncode, 125, result.stderr)
        self.assertIn("HEADLESS_SSH_MANAGED_OPTION_UNSUPPORTED", result.stderr)
        self.assertNotIn("auth", self.events())

    def test_managed_control_ownership_override_fails_before_authentication(self) -> None:
        for option in (
            "ControlMaster=yes",
            f"ControlPath={self.root / 'operator-master'}",
            "ControlPersist=30",
        ):
            with self.subTest(option=option):
                self.clear_calls()
                result = self.run_dispatch("-o", option, "minipc", "true")
                self.assertEqual(result.returncode, 125, result.stderr)
                self.assertIn("HEADLESS_SSH_MANAGED_OPTION_UNSUPPORTED", result.stderr)
                self.assertNotIn("auth", self.events())


class LifecycleTests(DispatcherFixture):
    def test_active_control_master_reuses_transport_without_new_auth(self) -> None:
        control_path = self.root / "external-master"
        self.start_external_master(control_path)
        self.clear_calls()
        self.write_scenario(controlpath=str(control_path), stdout="reuse")
        result = self.run_dispatch("minipc", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "reuse")
        self.assertNotIn("auth", self.events())
        self.assertIn("control-check", self.events())

    def test_stale_control_master_uses_bounded_dedicated_auth(self) -> None:
        self.write_scenario(controlpath=str(self.root / "stale"), stdout="fresh")
        result = self.run_dispatch("minipc", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "fresh")
        self.assertIn("auth", self.events())

    def test_background_data_does_not_cancel_its_live_session_master(self) -> None:
        self.write_scenario(forkafterauthentication="yes", master_lifetime=0.4)
        result = self.run_dispatch("-f", "minipc", "background")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("control-exit", self.events())
        self.assertEqual(list(self.runtime.glob("call-*")), [])
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and list(self.state.glob("master-*.json")):
            time.sleep(0.02)
        self.assertEqual(list(self.state.glob("master-*.json")), [])

    def test_concurrent_calls_use_unique_ephemeral_masters(self) -> None:
        self.write_scenario(remote_delay=0.15, stdout="ok")
        processes = [
            subprocess.Popen(
                self.command("minipc", f"call-{index}"),
                env=self.env(),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            for index in range(2)
        ]
        results = [process.communicate(timeout=6) for process in processes]
        self.assertEqual([process.returncode for process in processes], [0, 0], results)
        data_paths = {
            str(call["argv"][call["argv"].index("-S") + 1])
            for call in self.calls()
            if call["event"] == "data" and "-S" in call["argv"]
        }
        self.assertEqual(len(data_paths), 2)
        self.assertEqual(list(self.runtime.glob("call-*")), [])

    def test_term_is_forwarded_and_reproduced_after_cleanup(self) -> None:
        self.write_scenario(remote_delay=10)
        process = subprocess.Popen(
            self.command("minipc", "long"),
            env=self.env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.wait_for_event("data")
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, -signal.SIGTERM)
        self.assertEqual(list(self.runtime.glob("call-*")), [])


class DependencyTests(DispatcherFixture):
    def test_missing_real_ssh_or_timeout_fails_closed_before_network(self) -> None:
        missing = self.root / "missing"
        for kwargs in ({"real_ssh": missing}, {"timeout_bin": str(missing)}):
            with self.subTest(kwargs=kwargs):
                self.clear_calls()
                result = self.run_dispatch("minipc", "true", **kwargs)
                self.assertEqual(result.returncode, 125, result.stderr)
                self.assertEqual(self.events(), [])

    def test_wrong_key_mode_fails_before_authentication(self) -> None:
        os.chmod(self.key, 0o600)
        result = self.run_dispatch("minipc", "true")
        self.assertEqual(result.returncode, 125, result.stderr)
        self.assertIn("HEADLESS_SSH_KEY_INVALID", result.stderr)
        self.assertNotIn("auth", self.events())


class SshUsageFormatError(RuntimeError):
    """`/usr/bin/ssh` usage가 이 테스트가 파싱할 수 있는 형태를 벗어났다."""


def _top_level_usage_groups(usage: str) -> list[str]:
    """usage 문자열에서 최상위 대괄호 묶음의 내용만 순서대로 돌려준다."""
    groups: list[str] = []
    depth = 0
    start = 0
    for index, char in enumerate(usage):
        if char == "[":
            if depth == 0:
                start = index + 1
            depth += 1
        elif char == "]":
            if depth == 0:
                raise SshUsageFormatError(f"ssh usage에 짝 없는 ']'가 있다 (offset {index})")
            depth -= 1
            if depth == 0:
                groups.append(usage[start:index])
    if depth != 0:
        raise SshUsageFormatError("ssh usage에 닫히지 않은 '['가 있다")
    return groups


def _record_usage_arity(arity: dict[str, int], option: str, value: int, group: str) -> None:
    previous = arity.get(option)
    if previous is not None and previous != value:
        raise SshUsageFormatError(
            f"ssh usage가 -{option}에 상충하는 arity를 준다: {previous} vs {value} ([{group}])"
        )
    arity[option] = value


def parse_ssh_usage_arity(usage: str) -> dict[str, int]:
    """`ssh` usage(stderr)에서 short option arity를 뽑는다.

    형식이 바뀌면 조용히 통과하지 않고 SshUsageFormatError로 죽는다.
    """
    if "usage: ssh" not in usage:
        raise SshUsageFormatError("ssh usage에 'usage: ssh' 머리말이 없다")
    groups = _top_level_usage_groups(usage)
    if not groups:
        raise SshUsageFormatError("ssh usage에 대괄호 option 묶음이 하나도 없다")

    arity: dict[str, int] = {}
    saw_cluster = False
    saw_valued = False
    for group in groups:
        stripped = group.strip()
        if not stripped.startswith("-"):
            # 위치 인자 꼬리 (`destination [command [argument ...]]`)
            continue
        cluster = _USAGE_FLAG_CLUSTER.fullmatch(stripped)
        if cluster is not None:
            saw_cluster = True
            for option in cluster.group(1):
                _record_usage_arity(arity, option, 0, stripped)
            continue
        valued = _USAGE_FLAG_WITH_VALUE.match(stripped)
        if valued is not None:
            saw_valued = True
            _record_usage_arity(arity, valued.group(1), 1, stripped)
            continue
        raise SshUsageFormatError(f"ssh usage의 option 묶음을 해석할 수 없다: [{group}]")

    # 두 arity 계열 중 하나라도 통째로 사라지면 형식이 바뀐 것으로 본다. 한쪽만 검사하면
    # 반대쪽 소멸이 "관측 0개 → 불일치 0개"로 조용히 통과한다.
    if not saw_cluster:
        raise SshUsageFormatError("ssh usage에 0-arity short option 묶음이 더는 없다")
    if not saw_valued:
        raise SshUsageFormatError("ssh usage에 1-arity short option 묶음이 더는 없다")
    return arity


class ManifestDriftTests(unittest.TestCase):
    """배포 매니페스트와 실제 `/usr/bin/ssh` usage의 드리프트를 잡는다.

    hermetic fixture는 매니페스트를 사실로 가정하므로, 매니페스트 자체가 macOS 갱신으로
    낡아지는 축은 여기서만 관측된다. darwin 호스트에서만 실행하고 그 외에서는 skip한다.
    """

    def require_system_ssh(self) -> None:
        if sys.platform != "darwin":
            self.skipTest("매니페스트 드리프트는 macOS /usr/bin/ssh에 대해서만 관측된다")
        if not SYSTEM_SSH.exists():
            self.skipTest(f"{SYSTEM_SSH}가 없다")

    def system_ssh_usage(self) -> str:
        result = subprocess.run(
            [str(SYSTEM_SSH)],
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        return result.stderr

    def system_ssh_version(self) -> str:
        result = subprocess.run(
            [str(SYSTEM_SSH), "-V"],
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        return (result.stderr or result.stdout).strip()

    def test_usage_parser_extracts_both_arities(self) -> None:
        sample = (
            "usage: ssh [-46AaCf] [-B bind_interface]\n"
            "           [-D [bind_address:]port] [-w local_tun[:remote_tun]]\n"
            "           destination [command [argument ...]]\n"
            "       ssh [-Q query_option]\n"
        )
        self.assertEqual(
            parse_ssh_usage_arity(sample),
            {
                "4": 0, "6": 0, "A": 0, "a": 0, "C": 0, "f": 0,
                "B": 1, "D": 1, "w": 1, "Q": 1,
            },
        )

    def test_usage_parser_dies_loudly_on_format_change(self) -> None:
        unparsable = {
            "머리말 없음": "ssh [-46A] destination\n",
            "묶음 없음": "usage: ssh destination command\n",
            "0-arity 묶음 없음": "usage: ssh [-o option] destination\n",
            "1-arity 묶음 없음": "usage: ssh [-46AaCf] destination\n",
            "해석 불가 묶음": "usage: ssh [-46A] [--long-option=value] destination\n",
            "닫히지 않은 괄호": "usage: ssh [-46A] [-B bind_interface destination\n",
            "상충 arity": "usage: ssh [-46A] [-A value] destination\n",
        }
        for label, usage in unparsable.items():
            with self.subTest(label=label):
                with self.assertRaises(SshUsageFormatError):
                    parse_ssh_usage_arity(usage)

    def test_checked_manifest_is_the_deployed_one(self) -> None:
        """이 테스트가 대조하는 파일이 nix가 실제로 배포하는 매니페스트인지 못 박는다.

        경로가 두 곳(여기와 headless-dispatcher.nix)에 있어, 매니페스트를 개명하면
        테스트가 배포되지 않는 파일을 검증하며 조용히 통과할 수 있다.
        """
        nix_source = DISPATCHER_NIX.read_text(encoding="utf-8")
        # assertIn은 실패 시 nix 파일 전문을 덤프하므로 진위만 단언한다.
        self.assertTrue(
            f"./files/{PRODUCTION_MANIFEST.name}" in nix_source,
            f"{DISPATCHER_NIX.relative_to(REPO)}가 배포하는 매니페스트와 "
            f"PRODUCTION_MANIFEST({PRODUCTION_MANIFEST.name})가 어긋난다",
        )

    def test_manifest_arity_matches_system_ssh_usage(self) -> None:
        self.require_system_ssh()
        usage = self.system_ssh_usage()
        observed = parse_ssh_usage_arity(usage)
        manifest = json.loads(PRODUCTION_MANIFEST.read_text(encoding="utf-8"))
        declared = manifest["shortOptionArity"]

        missing = sorted(option for option in observed if option not in declared)
        mismatched = sorted(
            f"-{option}: usage={observed[option]} manifest={declared[option]}"
            for option in observed
            if option in declared and declared[option] != observed[option]
        )
        manifest_only = [option for option in declared if option not in observed]
        legacy_only = sorted(
            f"-{option}({declared[option]})"
            for option in manifest_only
            if option in LEGACY_MANIFEST_ONLY
        )
        dropped = sorted(
            f"-{option}({declared[option]})"
            for option in manifest_only
            if option not in LEGACY_MANIFEST_ONLY
        )
        if legacy_only:
            # 허용된 레거시 항목만 실패가 아니다 (protocol version 등).
            print(f"manifest-only short options: {', '.join(legacy_only)}")

        if not missing and not mismatched and not dropped:
            return

        self.fail(
            "HEADLESS_SSH_MANIFEST_DRIFT: 배포 매니페스트가 실제 /usr/bin/ssh usage와 어긋난다.\n"
            f"  manifest: {PRODUCTION_MANIFEST.relative_to(REPO)}\n"
            f"  manifest verifiedOn: {manifest.get('verifiedOn', '(없음)')}\n"
            f"  system ssh: {self.system_ssh_version()}\n"
            f"  usage에 있으나 매니페스트에 없음: {', '.join('-' + o for o in missing) or '없음'}\n"
            f"  arity 불일치: {'; '.join(mismatched) or '없음'}\n"
            f"  매니페스트에만 남음(레거시 허용 밖): {', '.join(dropped) or '없음'}\n"
            "갱신 절차:\n"
            "  1. 매니페스트 shortOptionArity를 위 usage 기준으로 갱신한다 (삭제된 옵션은 "
            "제거하거나, 계속 받아야 하면 이 테스트의 LEGACY_MANIFEST_ONLY에 근거와 함께 넣는다).\n"
            "  2. 같은 매니페스트의 verifiedOn을 현재 `sw_vers -buildVersion`과 "
            "`/usr/bin/ssh -V` 값으로 갱신한다.\n"
            "  3. plans/029-headless-ssh-dx-policy.md의 매니페스트 갱신 트리거 문단을 확인한다.\n"
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
